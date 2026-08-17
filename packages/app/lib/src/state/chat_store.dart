import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../api/daemon_client.dart';

/// Per-session event buffer plus its live subscription state.
class _SessionBuffer {
  _SessionBuffer(this.sessionId, this.daemonId);

  final String sessionId;
  final String daemonId;
  final List<SessionEvent> events = <SessionEvent>[];
  final List<SessionEvent> pending = <SessionEvent>[];
  StreamSubscription<SessionEvent>? eventSub;
  bool historyLoaded = false;

  /// True while a resync history refetch is in flight; live events then park
  /// in [pending] so they can never overtake (and shadow) the refetch.
  bool resyncing = false;
  int maxSeq = 0;
}

/// Holds the live event buffer for every watched session.
///
/// [watchSession] subscribes to the client's live event stream and, on first
/// watch, backfills `history()`; live events with `seq` at or below the known
/// maximum are dropped as duplicates. Consecutive
/// [AgentMessageChunkEvent]/[AgentThoughtChunkEvent] deltas merge into a
/// single buffered event (events are immutable, so a new event is built with
/// the concatenated text). Listener notifications are coalesced to at most one
/// per microtask batch; sessions are the finest-grained key, so buffers for
/// unrelated sessions do not disturb each other.
class ChatStore extends ChangeNotifier {
  ChatStore({required DaemonClient Function(String daemonId) clientFor})
      // ignore: prefer_initializing_formals
      : _clientFor = clientFor;

  final DaemonClient Function(String daemonId) _clientFor;

  final Map<String, _SessionBuffer> _buffers = <String, _SessionBuffer>{};
  final Map<String, Session> _sessionsById = <String, Session>{};
  final Map<String, SessionStatus> _statusById = <String, SessionStatus>{};
  final Map<String, SessionMode> _modeById = <String, SessionMode>{};
  final Map<String, UsageInfo> _usageById = <String, UsageInfo>{};

  /// One `sessionUpdates`/`sessionRemovals` subscription per daemon, alive
  /// while at least one of its sessions is watched.
  final Map<String, StreamSubscription<Session>> _updateSubs =
      <String, StreamSubscription<Session>>{};
  final Map<String, StreamSubscription<String>> _removalSubs =
      <String, StreamSubscription<String>>{};

  /// One `resynced` subscription per daemon, alive with the session watches.
  /// After a reconnect the client re-emits [DaemonClient.resynced] and we
  /// backfill persisted history so events missed offline are never lost.
  final Map<String, StreamSubscription<void>> _resyncSubs =
      <String, StreamSubscription<void>>{};

  bool _notifyScheduled = false;

  /// Unmodifiable coalescing-friendly view of a session's buffered events.
  /// Empty list for sessions that were never watched.
  List<SessionEvent> eventsFor(String sessionId) =>
      List<SessionEvent>.unmodifiable(
        _buffers[sessionId]?.events ?? const <SessionEvent>[],
      );

  /// Latest derived status; default idle for unknown sessions.
  SessionStatus statusOf(String sessionId) =>
      _statusById[sessionId] ?? SessionStatus.idle;

  /// Latest usage reported by a `UsageEvent`, if any.
  UsageInfo? usageOf(String sessionId) => _usageById[sessionId];

  /// Latest known mode (from `session.updated`); default build.
  SessionMode modeOf(String sessionId) =>
      _modeById[sessionId] ?? SessionMode.build;

  /// Starts buffering [sessionId]'s events. Idempotent; on first watch also
  /// backfills history and reconciles it with events that arrived meanwhile.
  void watchSession(String daemonId, String sessionId) {
    if (_buffers.containsKey(sessionId)) return;
    final DaemonClient client = _clientFor(daemonId);
    final _SessionBuffer buffer = _SessionBuffer(sessionId, daemonId);
    _buffers[sessionId] = buffer;
    buffer.eventSub = client.sessionEvents(sessionId).listen(
      (SessionEvent event) => _onLiveEvent(buffer, event),
      onError: (Object _) {
        // The live stream is best-effort; history backfill covers the gap.
      },
    );
    _ensureDaemonSubscriptions(daemonId, client);
    // First watch: catch up on persisted events, then reconcile live ones.
    unawaited(_loadHistory(client, buffer));
  }

  /// Stops buffering [sessionId] and releases its subscriptions.
  void unwatch(String sessionId) {
    final _SessionBuffer? buffer = _buffers.remove(sessionId);
    if (buffer == null) return;
    buffer.eventSub?.cancel();
    _forget(buffer.sessionId);
    _maybeReleaseDaemon(buffer.daemonId);
    _scheduleNotify();
  }

  /// Starts a turn. Events flow into the buffer via [watchSession].
  Future<void> send(String daemonId, String sessionId, String text) =>
      _clientFor(daemonId).sendMessage(sessionId, text);

  Future<void> cancel(String daemonId, String sessionId) =>
      _clientFor(daemonId).cancelSession(sessionId);

  Future<void> respondPermission(
    String daemonId,
    String sessionId,
    String requestId,
    String optionId,
  ) =>
      _clientFor(daemonId)
          .respondPermission(sessionId, requestId, optionId);

  // ---------------------------------------------------------------------
  // Event handling
  // ---------------------------------------------------------------------

  void _ensureDaemonSubscriptions(String daemonId, DaemonClient client) {
    _updateSubs.putIfAbsent(
      daemonId,
      () => client.sessionUpdates.listen(_onSessionUpdate),
    );
    _removalSubs.putIfAbsent(
      daemonId,
      () => client.sessionRemovals.listen(_onSessionRemoved),
    );
    _resyncSubs.putIfAbsent(
      daemonId,
      () => client.resynced.listen((void _) {
        unawaited(_resyncDaemon(daemonId));
      }),
    );
  }

  void _maybeReleaseDaemon(String daemonId) {
    final bool stillWatched = _buffers.values
        .any((_SessionBuffer b) => b.daemonId == daemonId);
    if (stillWatched) return;
    _updateSubs.remove(daemonId)?.cancel();
    _removalSubs.remove(daemonId)?.cancel();
    _resyncSubs.remove(daemonId)?.cancel();
  }

  void _onSessionUpdate(Session session) {
    _sessionsById[session.id] = session;
    _statusById[session.id] = session.status;
    _modeById[session.id] = session.mode;
    _scheduleNotify();
  }

  void _onSessionRemoved(String sessionId) {
    final _SessionBuffer? buffer = _buffers.remove(sessionId);
    if (buffer != null) {
      buffer.eventSub?.cancel();
      _maybeReleaseDaemon(buffer.daemonId);
    }
    _forget(sessionId);
    _scheduleNotify();
  }

  void _forget(String sessionId) {
    _sessionsById.remove(sessionId);
    _statusById.remove(sessionId);
    _modeById.remove(sessionId);
    _usageById.remove(sessionId);
  }

  /// Reconciles watched buffers with persisted history after a reconnect.
  /// Replaying the full tail is safe: [_applyLive] dedupes by [seq] against
  /// [maxSeq], so only events missed while the socket was down are appended.
  ///
  /// While the refetch is in flight, live events are staged in [pending]
  /// (like the initial history load) so a fast live notification can never
  /// advance [maxSeq] past the gap and make the refetch drop it as a
  /// duplicate.
  Future<void> _resyncDaemon(String daemonId) async {
    final DaemonClient client = _clientFor(daemonId);
    final List<_SessionBuffer> buffers = <_SessionBuffer>[
      for (final _SessionBuffer buffer in _buffers.values)
        if (buffer.daemonId == daemonId && buffer.historyLoaded) buffer,
    ];
    if (buffers.isEmpty) return;
    for (final _SessionBuffer buffer in buffers) {
      buffer.resyncing = true;
    }
    try {
      for (final _SessionBuffer buffer in buffers) {
        try {
          final List<SessionEvent> history =
              await client.history(buffer.sessionId);
          for (final SessionEvent event in history) {
            _applyLive(buffer, event);
          }
        } on Object {
          // Live events still flow; the next resync (or reconnect) retries.
        }
      }
    } finally {
      for (final _SessionBuffer buffer in buffers) {
        buffer.resyncing = false;
        for (final SessionEvent event in buffer.pending) {
          _applyLive(buffer, event);
        }
        buffer.pending.clear();
      }
    }
    _scheduleNotify();
  }

  void _onLiveEvent(_SessionBuffer buffer, SessionEvent event) {
    if (!buffer.historyLoaded || buffer.resyncing) {
      // History is still in flight; keep the event and reconcile later.
      buffer.pending.add(event);
      return;
    }
    _applyLive(buffer, event);
  }

  void _applyLive(_SessionBuffer buffer, SessionEvent event) {
    final int? seq = event.seq;
    if (seq != null && seq <= buffer.maxSeq) return; // duplicate
    _append(buffer, event);
    if (seq != null && seq > buffer.maxSeq) buffer.maxSeq = seq;
    _scheduleNotify();
  }

  Future<void> _loadHistory(DaemonClient client, _SessionBuffer buffer) async {
    try {
      final List<SessionEvent> history = await client.history(buffer.sessionId);
      for (final SessionEvent event in history) {
        _append(buffer, event);
        final int? seq = event.seq;
        if (seq != null && seq > buffer.maxSeq) buffer.maxSeq = seq;
      }
    } catch (_) {
      // Live stream remains the source of truth; nothing to propagate.
    } finally {
      buffer.historyLoaded = true;
      for (final SessionEvent event in buffer.pending) {
        _applyLive(buffer, event);
      }
      buffer.pending.clear();
      _scheduleNotify();
    }
  }

  /// Appends [event], merging consecutive chunk deltas of the same kind into
  /// one buffered event, and records any derived state it carries.
  void _append(_SessionBuffer buffer, SessionEvent event) {
    final List<SessionEvent> events = buffer.events;
    if (events.isNotEmpty &&
        (event is AgentMessageChunkEvent || event is AgentThoughtChunkEvent)) {
      final SessionEvent lastEvent = events.last;
      if (event is AgentMessageChunkEvent && lastEvent is AgentMessageChunkEvent) {
        events[events.length - 1] = AgentMessageChunkEvent(
          text: lastEvent.text + event.text,
          seq: event.seq,
          timestamp: event.timestamp,
        );
        return;
      }
      if (event is AgentThoughtChunkEvent && lastEvent is AgentThoughtChunkEvent) {
        events[events.length - 1] = AgentThoughtChunkEvent(
          text: lastEvent.text + event.text,
          seq: event.seq,
          timestamp: event.timestamp,
        );
        return;
      }
    }
    events.add(event);
    _noteEvent(buffer, event);
  }

  void _noteEvent(_SessionBuffer buffer, SessionEvent event) {
    switch (event) {
      case TurnCompleteEvent():
        _statusById[buffer.sessionId] = SessionStatus.idle;
      case SessionErrorEvent():
        _statusById[buffer.sessionId] = SessionStatus.error;
      case PermissionRequestEvent():
        _statusById[buffer.sessionId] = SessionStatus.waitingPermission;
      case PermissionResolvedEvent():
        _statusById[buffer.sessionId] = SessionStatus.running;
      case UsageEvent(:final usage):
        _usageById[buffer.sessionId] = usage;
      default:
        break;
    }
  }

  // ---------------------------------------------------------------------
  // Notifications
  // ---------------------------------------------------------------------

  void _scheduleNotify() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    for (final _SessionBuffer buffer in _buffers.values) {
      buffer.eventSub?.cancel();
    }
    _buffers.clear();
    for (final StreamSubscription<Session> sub in _updateSubs.values) {
      sub.cancel();
    }
    _updateSubs.clear();
    for (final StreamSubscription<String> sub in _removalSubs.values) {
      sub.cancel();
    }
    _removalSubs.clear();
    for (final StreamSubscription<void> sub in _resyncSubs.values) {
      sub.cancel();
    }
    _resyncSubs.clear();
    super.dispose();
  }
}
