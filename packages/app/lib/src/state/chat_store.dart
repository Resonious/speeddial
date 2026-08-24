import 'dart:async';

import 'store_base.dart';

import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../api/daemon_client.dart';

/// Composite `daemonId/sessionId` key backing the store's maps. Session ids
/// are daemon-scoped (PROTOCOL.md), so the same id may legitimately exist on
/// several daemons; public single-id getters resolve across daemons by
/// scanning for a unique match, preferring the entry whose daemonId is the
/// most recently watched/updated for that id. Any remaining ambiguity is
/// resolved last-write-wins (see the resolution helpers in [ChatStore]).
String _scopedKey(String daemonId, String id) => '$daemonId/$id';

/// Load state of a watched session's persisted history, surfaced so the UI
/// can distinguish "history still arriving" from "this session is empty"
/// (and from "the fetch failed") instead of rendering a blank timeline.
enum HistoryStatus {
  /// The first `history()` fetch (or a [ChatStore.retryHistory]) is running.
  loading,

  /// History is fully loaded; live events apply directly.
  ready,

  /// The last fetch failed (e.g. daemon unreachable). Live events still
  /// apply; the next resync or [ChatStore.retryHistory] retries the fetch.
  failed,
}

/// Per-session event buffer plus its live subscription state.
class _SessionBuffer {
  _SessionBuffer(this.sessionId, this.daemonId)
    : key = _scopedKey(daemonId, sessionId);

  final String sessionId;
  final String daemonId;

  /// Composite key backing the store's maps ([_scopedKey]).
  final String key;
  final List<SessionEvent> events = <SessionEvent>[];
  final List<SessionEvent> pending = <SessionEvent>[];
  StreamSubscription<SessionEvent>? eventSub;
  bool historyLoaded = false;
  bool hasOlderHistory = false;
  bool loadingOlderHistory = false;
  Object? olderHistoryError;
  int? oldestSeq;

  /// Error of the last failed history fetch; null when the last fetch (or
  /// resync) succeeded. Only meaningful once [historyLoaded] is true.
  Object? historyError;

  /// True while a resync history refetch is in flight; live events then park
  /// in [pending] so they can never overtake (and shadow) the refetch.
  bool resyncing = false;
  int maxSeq = 0;

  /// Open chunk-merge run, if the tail of [events] is a chunk delta family
  /// that is still accumulating text (see [_ChunkRun]).
  _ChunkRun? chunkRun;
}

/// Scratch state for a run of consecutive same-kind chunk deltas.
///
/// ARCHITECTURE.md: streaming chunks append to the last event's StringBuffer
/// rather than rebuilding a concatenated string per delta (the old
/// `lastEvent.text + event.text` was O(n) per chunk, O(n²) per turn). While
/// a run is open, the merged event at the tail of the buffer list keeps its
/// original (first chunk) text and the accumulated text lives only here; the
/// event is rematerialized from [buffer] — once, at final size — when the
/// run closes (a different event type arrives) or when the store's
/// `eventsFor` reads the buffer. Buffered events stay immutable.
class _ChunkRun {
  _ChunkRun({
    required this.isMessage,
    required String text,
    this.seq,
    this.timestamp,
  }) : buffer = StringBuffer(text);

  /// True for [AgentMessageChunkEvent] runs, false for
  /// [AgentThoughtChunkEvent] runs; the two families never merge with each
  /// other.
  final bool isMessage;
  final StringBuffer buffer;

  /// Seq/timestamp of the newest delta in the run; the merged event carries
  /// them (matching the pre-StringBuffer merge semantics).
  int? seq;
  DateTime? timestamp;
}

/// Holds the live event buffer for every watched session.
///
/// [watchSession] subscribes to the client's live event stream and, on first
/// watch, loads only the newest persisted-history page. Older pages are fetched
/// explicitly through [loadOlderHistory] as the user scrolls upward; live events
/// with `seq` at or below the known maximum are dropped as duplicates. Consecutive
/// [AgentMessageChunkEvent]/[AgentThoughtChunkEvent] deltas merge into a
/// single buffered event (events are immutable, so a new event is built with
/// the concatenated text when the merge run closes or the buffer is read).
/// Listener notifications are coalesced to at most one per microtask batch;
/// sessions are the finest-grained key, so buffers for unrelated sessions do
/// not disturb each other.
///
/// Buffers and derived state are keyed by composite `daemonId/sessionId`
/// keys so the same session id on two daemons never collides. All public
/// methods keep their single-id signatures; ambiguous ids resolve by
/// preferring the daemon most recently watched/updated for that id, then
/// last-write-wins on scan order (see the `_bufferFor` / `_derivedKeyFor`
/// helpers).
class ChatStore extends StoreBase {
  ChatStore({required DaemonClient Function(String daemonId) clientFor})
    // ignore: prefer_initializing_formals
    : _clientFor = clientFor;

  final DaemonClient Function(String daemonId) _clientFor;

  final Map<String, _SessionBuffer> _buffers = <String, _SessionBuffer>{};
  final Map<String, Session> _sessionsById = <String, Session>{};
  final Map<String, SessionStatus> _statusById = <String, SessionStatus>{};
  final Map<String, SessionMode> _modeById = <String, SessionMode>{};
  final Map<String, UsageInfo> _usageById = <String, UsageInfo>{};

  /// Memoized attachment payload futures, keyed by
  /// `daemonId/sessionId/attachmentId` (see [attachmentData]).
  final Map<String, Future<AttachmentData>> _attachmentLoads =
      <String, Future<AttachmentData>>{};

  /// Monotonic per-session buffer mutation counter, keyed like the rest of
  /// the derived state; incremented on every event appended or merged in.
  final Map<String, int> _revisions = <String, int>{};

  /// Most recently watched/updated daemon per session id; disambiguates
  /// cross-daemon id collisions in the public single-id getters below.
  final Map<String, String> _lastDaemonBySession = <String, String>{};

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
  /// Empty list for sessions that were never watched. Reading this
  /// materializes any open chunk-merge run (building the final merged text
  /// once) but does not itself notify or bump the session's revision.
  List<SessionEvent> eventsFor(String sessionId) {
    final _SessionBuffer? buffer = _bufferFor(sessionId);
    if (buffer == null) return const <SessionEvent>[];
    _materializeChunkRun(buffer);
    return List<SessionEvent>.unmodifiable(buffer.events);
  }

  /// Latest derived status; default idle for unknown sessions.
  SessionStatus statusOf(String sessionId) {
    final String? key = _derivedKeyFor(sessionId);
    return key == null
        ? SessionStatus.idle
        : _statusById[key] ?? SessionStatus.idle;
  }

  /// Latest usage reported by a `UsageEvent`, if any.
  UsageInfo? usageOf(String sessionId) {
    final String? key = _derivedKeyFor(sessionId);
    return key == null ? null : _usageById[key];
  }

  /// Latest known mode (from `session.updated`); default build.
  SessionMode modeOf(String sessionId) {
    final String? key = _derivedKeyFor(sessionId);
    return key == null
        ? SessionMode.build
        : _modeById[key] ?? SessionMode.build;
  }

  /// How many times [sessionId]'s buffer was mutated (events appended or
  /// merged) since it started being watched. 0 for sessions nobody watches.
  /// Lets app-layer code detect "new content arrived" without diffing event
  /// lists. Cleared when the session's derived state is forgotten (unwatch /
  /// daemon-side removal).
  int revisionFor(String sessionId) {
    final _SessionBuffer? buffer = _bufferFor(sessionId);
    if (buffer != null) return _revisions[buffer.key] ?? 0;
    final String? key = _derivedKeyFor(sessionId);
    return key == null ? 0 : _revisions[key] ?? 0;
  }

  /// History load state for [sessionId] (see [HistoryStatus]). Sessions that
  /// were never watched report [HistoryStatus.ready]: there is nothing to
  /// load until [watchSession] runs.
  HistoryStatus historyStatusFor(String sessionId) {
    final _SessionBuffer? buffer = _bufferFor(sessionId);
    if (buffer == null) return HistoryStatus.ready;
    if (!buffer.historyLoaded) return HistoryStatus.loading;
    return buffer.historyError == null
        ? HistoryStatus.ready
        : HistoryStatus.failed;
  }

  /// The error the last history fetch for [sessionId] failed with; null when
  /// loaded (or still loading).
  Object? historyErrorFor(String sessionId) {
    final _SessionBuffer? buffer = _bufferFor(sessionId);
    if (buffer == null || !buffer.historyLoaded) return null;
    return buffer.historyError;
  }

  /// True while [sessionId]'s buffer is mid-resync: the daemon just
  /// reconnected and persisted history is being refetched to backfill what
  /// was missed offline. The buffered events are stale for that window but
  /// valid — live events park in the buffer's pending queue during the
  /// refetch, so nothing is lost. False for never-watched sessions.
  bool isCatchingUp(String sessionId) =>
      _bufferFor(sessionId)?.resyncing ?? false;

  /// Whether persisted events older than the currently buffered page remain.
  bool hasOlderHistory(String sessionId) =>
      _bufferFor(sessionId)?.hasOlderHistory ?? false;

  /// Whether an explicit older-page request is currently in flight.
  bool isLoadingOlderHistory(String sessionId) =>
      _bufferFor(sessionId)?.loadingOlderHistory ?? false;

  /// Error from the last older-page request, if any.
  Object? olderHistoryErrorFor(String sessionId) =>
      _bufferFor(sessionId)?.olderHistoryError;

  /// Loads exactly one page older than the currently buffered history.
  /// Concurrent calls and calls after the oldest page are no-ops.
  Future<void> loadOlderHistory(String daemonId, String sessionId) async {
    final _SessionBuffer? buffer = _buffers[_scopedKey(daemonId, sessionId)];
    if (buffer == null ||
        !buffer.historyLoaded ||
        !buffer.hasOlderHistory ||
        buffer.loadingOlderHistory) {
      return;
    }
    final int? beforeSeq = buffer.oldestSeq;
    if (beforeSeq == null) {
      buffer.hasOlderHistory = false;
      _scheduleNotify();
      return;
    }
    buffer.loadingOlderHistory = true;
    buffer.olderHistoryError = null;
    _scheduleNotify();
    try {
      final page = await _clientFor(daemonId)
          .history(sessionId, limit: _historyPageSize, beforeSeq: beforeSeq);
      _prependHistoryPage(buffer, page.events);
      buffer.hasOlderHistory = page.hasMore;
      if (page.events.isNotEmpty) buffer.oldestSeq = page.events.first.seq;
    } catch (error) {
      buffer.olderHistoryError = error;
    } finally {
      buffer.loadingOlderHistory = false;
      _scheduleNotify();
    }
  }

  /// Retries the persisted-history fetch for a session whose load failed.
  /// No-op while a fetch is in flight or when there is nothing to retry.
  void retryHistory(String daemonId, String sessionId) {
    final _SessionBuffer? buffer = _buffers[_scopedKey(daemonId, sessionId)];
    if (buffer == null ||
        !buffer.historyLoaded ||
        buffer.historyError == null) {
      return;
    }
    buffer.historyLoaded = false;
    buffer.historyError = null;
    _scheduleNotify();
    unawaited(_loadHistory(_clientFor(daemonId), buffer));
  }

  /// Starts buffering [sessionId]'s events. Idempotent per daemon; on first
  /// watch also backfills history, reconciles it with events that arrived
  /// meanwhile, and seeds status/mode from a one-shot `listSessions`. The
  /// backfill's progress is observable through [historyStatusFor]; a failed
  /// fetch is retried by [retryHistory] or automatically on resync.
  void watchSession(String daemonId, String sessionId) {
    final String key = _scopedKey(daemonId, sessionId);
    _lastDaemonBySession[sessionId] = daemonId;
    if (_buffers.containsKey(key)) return;
    final DaemonClient client = _clientFor(daemonId);
    final _SessionBuffer buffer = _SessionBuffer(sessionId, daemonId);
    _buffers[key] = buffer;
    buffer.eventSub = client
        .sessionEvents(sessionId)
        .listen(
          (SessionEvent event) => _onLiveEvent(buffer, event),
          onError: (Object _) {
            // The live stream is best-effort; history backfill covers the gap.
          },
        );
    _ensureDaemonSubscriptions(daemonId, client);
    // First watch: catch up on persisted events, then reconcile live ones.
    unawaited(_loadHistory(client, buffer));
    // Cheap, once per watch: make statusOf/modeOf correct before the first
    // live event or session.updated notification arrives.
    unawaited(_seedSession(client, daemonId, sessionId));
  }

  /// Stops buffering [sessionId] (the preferred cross-daemon match) and
  /// releases its subscriptions.
  void unwatch(String sessionId) {
    final _SessionBuffer? buffer = _bufferFor(sessionId);
    if (buffer == null) return;
    _buffers.remove(buffer.key);
    buffer.eventSub?.cancel();
    _forget(buffer.daemonId, buffer.sessionId);
    _maybeReleaseDaemon(buffer.daemonId);
    _scheduleNotify();
  }

  /// Starts a turn. Events flow into the buffer via [watchSession].
  Future<void> send(
    String daemonId,
    String sessionId,
    String text, {
    List<OutgoingAttachment> attachments = const [],
  }) =>
      _clientFor(daemonId)
          .sendMessage(sessionId, text, attachments: attachments);

  /// Fetches an attachment's payload, memoized per composite
  /// `daemonId/sessionId/attachmentId` key. Attachments are immutable (their
  /// payload never changes once assigned an id), so the first result stays
  /// valid for the life of the store and no eviction is needed; repeat
  /// reads of the same attachment share one future.
  Future<AttachmentData> attachmentData(
    String daemonId,
    String sessionId,
    String attachmentId,
  ) {
    final String key = '$daemonId/$sessionId/$attachmentId';
    return _attachmentLoads[key] ??= _clientFor(daemonId)
        .readAttachment(sessionId, attachmentId);
  }

  Future<void> cancel(String daemonId, String sessionId) =>
      _clientFor(daemonId).cancelSession(sessionId);

  Future<void> respondPermission(
    String daemonId,
    String sessionId,
    String requestId,
    String optionId,
  ) => _clientFor(daemonId).respondPermission(sessionId, requestId, optionId);

  // ---------------------------------------------------------------------
  // Cross-daemon id resolution
  // ---------------------------------------------------------------------

  /// The watched buffer for [sessionId], preferring the daemon most recently
  /// touched for that id ([_lastDaemonBySession]); falls back to a unique
  /// match scan.
  _SessionBuffer? _bufferFor(String sessionId) {
    final String? daemonId = _lastDaemonBySession[sessionId];
    if (daemonId != null) {
      final _SessionBuffer? preferred =
          _buffers[_scopedKey(daemonId, sessionId)];
      if (preferred != null) return preferred;
    }
    for (final _SessionBuffer buffer in _buffers.values) {
      if (buffer.sessionId == sessionId) return buffer;
    }
    return null;
  }

  /// Composite key of the derived state for [sessionId], or null. Derived
  /// entries can exist for sessions that were updated (but never watched),
  /// so the scan covers the by-id/status maps rather than only buffers.
  ///
  /// Session ids are daemon-scoped (PROTOCOL.md): two daemons may hold the
  /// same id with different content. When a collision exists, the entry for
  /// the daemon most recently watched/updated wins; anything else resolves
  /// last-write-wins (map iteration order), which is acceptable because the
  /// UI always selects an explicit daemon alongside a session id.
  String? _derivedKeyFor(String sessionId) {
    final String? daemonId = _lastDaemonBySession[sessionId];
    if (daemonId != null) {
      final String preferred = _scopedKey(daemonId, sessionId);
      if (_sessionsById.containsKey(preferred) ||
          _statusById.containsKey(preferred)) {
        return preferred;
      }
    }
    for (final String key in _statusById.keys) {
      if (key.endsWith('/$sessionId')) return key;
    }
    for (final String key in _sessionsById.keys) {
      if (key.endsWith('/$sessionId')) return key;
    }
    return null;
  }

  // ---------------------------------------------------------------------
  // Daemon subscriptions
  // ---------------------------------------------------------------------

  void _ensureDaemonSubscriptions(String daemonId, DaemonClient client) {
    _updateSubs.putIfAbsent(
      daemonId,
      () => client.sessionUpdates.listen(
        (Session session) => _onSessionUpdate(daemonId, session),
      ),
    );
    _removalSubs.putIfAbsent(
      daemonId,
      () => client.sessionRemovals.listen(
        (String sessionId) => _onSessionRemoved(daemonId, sessionId),
      ),
    );
    _resyncSubs.putIfAbsent(
      daemonId,
      () => client.resynced.listen((void _) {
        unawaited(_resyncDaemon(daemonId));
      }),
    );
  }

  void _maybeReleaseDaemon(String daemonId) {
    final bool stillWatched = _buffers.values.any(
      (_SessionBuffer b) => b.daemonId == daemonId,
    );
    if (stillWatched) return;
    _updateSubs.remove(daemonId)?.cancel();
    _removalSubs.remove(daemonId)?.cancel();
    _resyncSubs.remove(daemonId)?.cancel();
  }

  void _onSessionUpdate(String daemonId, Session session) {
    final String key = _scopedKey(daemonId, session.id);
    final Session? current = _sessionsById[key];
    if (current != null && current.updatedAt.isAfter(session.updatedAt)) return;
    _lastDaemonBySession[session.id] = daemonId;
    _sessionsById[key] = session;
    _statusById[key] = session.status;
    _modeById[key] = session.mode;
    _scheduleNotify();
  }

  void _onSessionRemoved(String daemonId, String sessionId) {
    final String key = _scopedKey(daemonId, sessionId);
    final _SessionBuffer? buffer = _buffers.remove(key);
    if (buffer != null) {
      buffer.eventSub?.cancel();
      _maybeReleaseDaemon(buffer.daemonId);
    }
    _forget(daemonId, sessionId);
    _scheduleNotify();
  }

  void _forget(String daemonId, String sessionId) {
    final String key = _scopedKey(daemonId, sessionId);
    _sessionsById.remove(key);
    _statusById.remove(key);
    _modeById.remove(key);
    _usageById.remove(key);
    _revisions.remove(key);
  }

  /// Fills status/mode from a one-shot `listSessions` so derived state is
  /// correct (not the idle default) as soon as a session is watched, even
  /// before any event or session.updated notification has arrived.
  Future<void> _seedSession(
    DaemonClient client,
    String daemonId,
    String sessionId,
  ) async {
    try {
      final List<Session> sessions = await client.listSessions(
        includeArchived: true,
      );
      for (final Session session in sessions) {
        if (session.id == sessionId &&
            _buffers.containsKey(_scopedKey(daemonId, sessionId))) {
          _onSessionUpdate(daemonId, session);
          return;
        }
      }
    } on Object {
      // Live sessionUpdates keep the state fresh when they arrive.
    }
  }

  /// Reconciles watched buffers with persisted history after a reconnect.
  /// Pages are fetched newest-first only until they overlap the known tail;
  /// older history remains lazy and is never walked during reconnect.
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
    // The timeline is stale for the duration of the refetch; notify so the
    // catch-up surface shows immediately, not only when the backfill lands.
    _scheduleNotify();
    try {
      for (final _SessionBuffer buffer in buffers) {
        try {
          final List<List<SessionEvent>> pages = <List<SessionEvent>>[];
          int? beforeSeq;
          while (true) {
            final page = await client.history(
              buffer.sessionId,
              limit: _historyPageSize,
              beforeSeq: beforeSeq,
            );
            pages.add(page.events);
            if (page.events.isEmpty ||
                page.events.first.seq == null ||
                page.events.first.seq! <= buffer.maxSeq + 1 ||
                !page.hasMore) {
              break;
            }
            beforeSeq = page.events.first.seq;
          }
          for (final List<SessionEvent> page in pages.reversed) {
            for (final SessionEvent event in page) {
              _applyLive(buffer, event);
            }
          }
          buffer.historyError = null;
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

  /// Page size for history loads. Keeping frames modest protects mobile
  /// clients from oversized JSON responses while still filling a screen in
  /// one round trip.
  static const int _historyPageSize = 500;

  /// Loads the newest persisted-history page for a newly watched session.
  Future<void> _loadHistory(DaemonClient client, _SessionBuffer buffer) async {
    buffer.events.clear();
    buffer.chunkRun = null;
    buffer.maxSeq = 0;
    buffer.oldestSeq = null;
    buffer.hasOlderHistory = false;
    buffer.olderHistoryError = null;
    try {
      final page = await client.history(
        buffer.sessionId,
        limit: _historyPageSize,
      );
      _applyLatestHistoryPage(buffer, page.events);
      buffer.hasOlderHistory = page.hasMore;
      if (page.events.isNotEmpty) buffer.oldestSeq = page.events.first.seq;
      buffer.historyError = null;
    } catch (error) {
      buffer.historyError = error;
    } finally {
      buffer.historyLoaded = true;
      for (final SessionEvent event in buffer.pending) {
        _applyLive(buffer, event);
      }
      buffer.pending.clear();
      _scheduleNotify();
    }
  }

  /// Appends the newest history page (the first one fetched) oldest-first
  /// and immediately publishes the buffer as loaded, so live events stop
  /// parking and the UI can render while older pages stream in.
  void _applyLatestHistoryPage(_SessionBuffer buffer, List<SessionEvent> page) {
    for (final SessionEvent event in page) {
      _append(buffer, event);
      final int? seq = event.seq;
      if (seq != null && seq > buffer.maxSeq) buffer.maxSeq = seq;
    }
    buffer.historyLoaded = true;
    for (final SessionEvent event in buffer.pending) {
      _applyLive(buffer, event);
    }
    buffer.pending.clear();
    _scheduleNotify();
  }

  /// Prepends an older history page at the head of the buffer. The page is
  /// strictly older than everything buffered, so no event derivation runs
  /// (newer events already established status/usage — see [_noteEvent])
  /// and the tail's open chunk-merge run is untouched. Adjacent same-family
  /// chunks across the page boundary stay separate buffer events; the
  /// timeline still renders them as one merged item.
  void _prependHistoryPage(_SessionBuffer buffer, List<SessionEvent> page) {
    if (page.isEmpty) return;
    buffer.events.insertAll(0, page);
    _revisions[buffer.key] = (_revisions[buffer.key] ?? 0) + page.length;
    _scheduleNotify();
  }

  /// Appends [event], merging consecutive chunk deltas of the same kind into
  /// one buffered event, and records any derived state it carries. Every
  /// call is a buffer mutation, so it bumps the session's revision.
  void _append(_SessionBuffer buffer, SessionEvent event) {
    _revisions[buffer.key] = (_revisions[buffer.key] ?? 0) + 1;

    // A switch over the sealed type reaches the chunk getters via pattern
    // bindings (an `is A || is B` test would not promote the scrutinee).
    switch (event) {
      case AgentMessageChunkEvent(
        :final String text,
        :final int? seq,
        :final DateTime? timestamp,
      ):
        _mergeChunk(
          buffer,
          isMessage: true,
          text: text,
          seq: seq,
          timestamp: timestamp,
          event: event,
        );
      case AgentThoughtChunkEvent(
        :final String text,
        :final int? seq,
        :final DateTime? timestamp,
      ):
        _mergeChunk(
          buffer,
          isMessage: false,
          text: text,
          seq: seq,
          timestamp: timestamp,
          event: event,
        );
      default:
        _closeChunkRun(buffer);
        buffer.events.add(event);
        _noteEvent(buffer, event);
    }
  }

  /// Extends the open same-family chunk run with [text], or — when [event]
  /// opens a different family or no run is open — closes any open run and
  /// starts a fresh one. Never merges message chunks with thought chunks.
  void _mergeChunk(
    _SessionBuffer buffer, {
    required bool isMessage,
    required String text,
    required int? seq,
    required DateTime? timestamp,
    required SessionEvent event,
  }) {
    final _ChunkRun? run = buffer.chunkRun;
    if (run != null && run.isMessage == isMessage) {
      // Same-kind run continues: accumulate in the scratch buffer only.
      run.buffer.write(text);
      run.seq = seq;
      run.timestamp = timestamp;
      return;
    }
    // Different event type (or the other chunk family): the run closes, so
    // the two events never merge, then a fresh run opens.
    _closeChunkRun(buffer);
    buffer.chunkRun = _ChunkRun(
      isMessage: isMessage,
      text: text,
      seq: seq,
      timestamp: timestamp,
    );
    buffer.events.add(event);
    _noteEvent(buffer, event);
  }

  /// Replaces the tail event with one built from the run's scratch buffer —
  /// the merged text, built once at its final size. Leaves the run open so
  /// more same-kind chunks can keep accumulating.
  void _materializeChunkRun(_SessionBuffer buffer) {
    final _ChunkRun? run = buffer.chunkRun;
    if (run == null) return;
    final List<SessionEvent> events = buffer.events;
    if (events.isEmpty) {
      buffer.chunkRun = null;
      return;
    }
    events[events.length - 1] = run.isMessage
        ? AgentMessageChunkEvent(
            text: run.buffer.toString(),
            seq: run.seq,
            timestamp: run.timestamp,
          )
        : AgentThoughtChunkEvent(
            text: run.buffer.toString(),
            seq: run.seq,
            timestamp: run.timestamp,
          );
  }

  /// Closes the open chunk-merge run: materializes its event and drops the
  /// scratch state.
  void _closeChunkRun(_SessionBuffer buffer) {
    if (buffer.chunkRun == null) return;
    _materializeChunkRun(buffer);
    buffer.chunkRun = null;
  }

  void _noteEvent(_SessionBuffer buffer, SessionEvent event) {
    switch (event) {
      case TurnCompleteEvent():
        _statusById[buffer.key] = SessionStatus.idle;
      case SessionErrorEvent():
        _statusById[buffer.key] = SessionStatus.error;
      case PermissionRequestEvent():
        _statusById[buffer.key] = SessionStatus.waitingPermission;
      case PermissionResolvedEvent():
        _statusById[buffer.key] = SessionStatus.running;
      case UsageEvent(:final usage):
        _usageById[buffer.key] = usage;
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
