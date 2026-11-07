import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show ValueListenable, ValueNotifier, immutable;

import 'store_base.dart';

import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../api/daemon_client.dart';
import '../api/saved_history_client.dart';
import 'streamed_attachment.dart';

/// Composite `daemonId/sessionId` key backing the store's maps. Session ids
/// are daemon-scoped (PROTOCOL.md), so the same id may legitimately exist on
/// several daemons; public single-id getters resolve across daemons by
/// scanning for a unique match, preferring the entry whose daemonId is the
/// most recently watched/updated for that id. Any remaining ambiguity is
/// resolved last-write-wins (see the resolution helpers in [ChatStore]).
String _scopedKey(String daemonId, String id) => '$daemonId/$id';

typedef _HistoryPage = ({List<SessionEvent> events, bool hasMore});

/// How long a connected client waits for a session's real history before
/// showing its saved summary instead.
const Duration savedHistoryPatience = Duration(milliseconds: 250);

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

/// A message sent from this client that the daemon has not echoed back yet.
///
/// PROTOCOL.md: the daemon persists and broadcasts the turn's `userMessage`
/// event before it acknowledges `sessions.send`, so that echo is what
/// retires the entry. Until then the timeline renders it optimistically.
@immutable
class OutgoingMessage {
  const OutgoingMessage({
    required this.id,
    required this.text,
    this.attachments = const <OutgoingAttachment>[],
    this.upload,
  });

  /// Client-local identity, unique within one [ChatStore].
  final int id;
  final String text;
  final List<OutgoingAttachment> attachments;

  /// Fraction (0–1) of [StreamedAttachment] bytes uploaded, when the message
  /// carries any; it reaches 1 before `sessions.send` goes out.
  final ValueListenable<double>? upload;
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
  late final List<SessionEvent> eventView = UnmodifiableListView(events);
  final Map<String, PermissionRequest> permissions =
      <String, PermissionRequest>{};
  final List<SessionEvent> pending = <SessionEvent>[];
  StreamSubscription<SessionEvent>? eventSub;
  bool historyLoaded = false;
  bool savedOnly = false;
  bool savedComplete = false;
  bool replaceOnResync = false;
  int historyReplacementRevision = 0;
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
  final List<HistoryRewoundEvent> rewinds = [];

  /// Open chunk-merge run, if the tail of [events] is a chunk delta family
  /// that is still accumulating text (see [_ChunkRun]).
  _ChunkRun? chunkRun;

  /// Sends awaiting their `userMessage` echo, oldest first.
  final List<OutgoingMessage> outgoing = <OutgoingMessage>[];
  late final List<OutgoingMessage> outgoingView = UnmodifiableListView(
    outgoing,
  );

  /// Ids in [outgoing] whose send the daemon already acknowledged.
  final Set<int> acknowledged = <int>{};

  /// Seqs of `userMessage` events that retired an [outgoing] entry.
  final Set<int> deliveredSeqs = <int>{};
  late final Set<int> deliveredView = UnmodifiableSetView(deliveredSeqs);
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
    required this.messageId,
    this.seq,
    this.timestamp,
  }) : buffer = StringBuffer(text);

  /// True for [AgentMessageChunkEvent] runs, false for
  /// [AgentThoughtChunkEvent] runs; the two families never merge with each
  /// other.
  final bool isMessage;
  final StringBuffer buffer;
  bool dirty = true;
  final String? messageId;

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
  ChatStore({
    required DaemonClient Function(String daemonId) clientFor,
    this.historyPageSize = 500,
    this.retainedSessionLimit = 0,
  }) : assert(historyPageSize > 0),
       assert(retainedSessionLimit >= 0),
       // ignore: prefer_initializing_formals
       _clientFor = clientFor;

  Object? _lastError;
  Object? get lastError => _lastError;

  final DaemonClient Function(String daemonId) _clientFor;

  /// Number of raw persisted events requested per backwards history page.
  final int historyPageSize;

  /// Number of inactive session buffers retained for instant reopen.
  ///
  /// Zero preserves the full app's release-on-unwatch behavior. Compact
  /// clients can retain a small LRU; a rewatch renders it immediately and
  /// reconciles missed events in the background.
  final int retainedSessionLimit;

  final Map<String, _SessionBuffer> _buffers = <String, _SessionBuffer>{};
  final LinkedHashSet<String> _retainedKeys = LinkedHashSet<String>();
  final Map<String, Session> _sessionsById = <String, Session>{};
  final Map<String, SessionStatus> _statusById = <String, SessionStatus>{};
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
  int _nextOutgoingId = 0;

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

  /// Read-only live view for synchronous UI projection. Unlike [eventsFor],
  /// this does not copy the whole history on every streamed update. Do not
  /// retain it as an immutable snapshot across store mutations.
  List<SessionEvent> eventViewFor(String sessionId) {
    final _SessionBuffer? buffer = _bufferFor(sessionId);
    if (buffer == null) return const <SessionEvent>[];
    _materializeChunkRun(buffer);
    return buffer.eventView;
  }

  PermissionRequest? pendingPermissionFor(String sessionId) {
    final _SessionBuffer? buffer = _bufferFor(sessionId);
    if (buffer == null || buffer.permissions.isEmpty) return null;
    return buffer.permissions.values.last;
  }

  /// Read-only live view of messages sent to [sessionId] from this client
  /// that the daemon has not echoed back yet, oldest first (see [send]).
  List<OutgoingMessage> outgoingFor(String sessionId) =>
      _bufferFor(sessionId)?.outgoingView ?? const <OutgoingMessage>[];

  /// Seqs of [sessionId]'s `userMessage` events that confirmed a message
  /// sent from this client while the session was watched.
  Set<int> deliveredSeqsFor(String sessionId) =>
      _bufferFor(sessionId)?.deliveredView ?? const <int>{};

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

  int historyReplacementRevisionFor(String sessionId) =>
      _bufferFor(sessionId)?.historyReplacementRevision ?? 0;

  bool isSavedHistory(String sessionId) =>
      _bufferFor(sessionId)?.savedOnly ?? false;
  bool isSavedHistoryComplete(String sessionId) =>
      _bufferFor(sessionId)?.savedComplete ?? false;

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
        buffer.loadingOlderHistory ||
        buffer.resyncing) {
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
          .history(sessionId, limit: historyPageSize, beforeSeq: beforeSeq);
      _prependHistoryPage(buffer, page.events);
      if (!page.hasMore &&
          !buffer.savedOnly &&
          _clientFor(daemonId).isConnected) {
        buffer.savedComplete = true;
      }
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
    if (buffer.events.isNotEmpty) {
      unawaited(_resyncBuffer(_clientFor(daemonId), buffer));
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
    final DaemonClient client = _clientFor(daemonId);
    final _SessionBuffer? retained = _buffers[key];
    if (retained != null) {
      if (retained.eventSub != null) return;
      _retainedKeys.remove(key);
      retained.eventSub = client
          .sessionEvents(sessionId)
          .listen(
            (SessionEvent event) => _onLiveEvent(retained, event),
            onError: (Object _) {
              // The resync below covers events missed by the live stream.
            },
          );
      _ensureDaemonSubscriptions(daemonId, client);
      if (retained.historyLoaded) {
        unawaited(_resyncBuffer(client, retained));
      }
      unawaited(_seedSession(client, daemonId, sessionId));
      return;
    }
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
    // Cheap, once per watch: make statusOf correct before the first
    // live event or session.updated notification arrives.
    unawaited(_seedSession(client, daemonId, sessionId));
  }

  /// Stops buffering [sessionId] (the preferred cross-daemon match) and
  /// releases its subscriptions.
  void unwatch(String sessionId) {
    final _SessionBuffer? buffer = _bufferFor(sessionId);
    if (buffer == null) return;
    buffer.eventSub?.cancel();
    buffer.eventSub = null;
    if (retainedSessionLimit == 0) {
      _buffers.remove(buffer.key);
      _forget(buffer.daemonId, buffer.sessionId);
    } else {
      _closeChunkRun(buffer);
      _retainedKeys
        ..remove(buffer.key)
        ..add(buffer.key);
      _evictRetainedBuffers();
    }
    _maybeReleaseDaemon(buffer.daemonId);
    _scheduleNotify();
  }

  void _evictRetainedBuffers() {
    while (_retainedKeys.length > retainedSessionLimit) {
      final String key = _retainedKeys.first;
      _retainedKeys.remove(key);
      final _SessionBuffer? evicted = _buffers.remove(key);
      if (evicted != null) _forget(evicted.daemonId, evicted.sessionId);
    }
  }

  /// Starts a turn. Events flow into the buffer via [watchSession].
  ///
  /// For a watched session the message is listed by [outgoingFor] from the
  /// moment the request leaves until the daemon's `userMessage` echo lands,
  /// so the UI can show it at once; a rejected send drops it again before
  /// the error is rethrown.
  Future<void> send(
    String daemonId,
    String sessionId,
    String text, {
    List<OutgoingAttachment> attachments = const [],
  }) {
    // Inline payloads past the protocol caps go up as chunked uploads (and
    // reach the agent as a file) instead of being rejected by the daemon.
    final List<OutgoingAttachment> outgoing = _streamOversized(attachments);
    final ValueNotifier<double>? upload =
        outgoing.any((OutgoingAttachment a) => a is StreamedAttachment)
        ? ValueNotifier<double>(0)
        : null;
    return _sendOutgoing(daemonId, sessionId, text, attachments, () async {
      final DaemonClient client = _clientFor(daemonId);
      if (upload == null) {
        await client.sendMessage(sessionId, text, attachments: outgoing);
        return;
      }
      final List<String> uploadIds = <String>[];
      try {
        final List<OutgoingAttachment> sent = await _uploadStreamed(
          client,
          outgoing,
          uploadIds,
          upload,
        );
        await client.sendMessage(sessionId, text, attachments: sent);
      } on Object {
        for (final String id in uploadIds) {
          // The send's own error is what gets recorded and rethrown; a failed
          // cancel only leaves a staged upload the daemon expires in an hour.
          unawaited(
            client.cancelUpload(id).then<void>((_) {}, onError: (Object _) {}),
          );
        }
        rethrow;
      }
    }, upload: upload);
  }

  /// Returns [attachments] with every inline payload that would break the
  /// per-attachment or per-message inline cap swapped for an in-memory
  /// [StreamedAttachment], so it travels through `uploads.*` instead.
  static List<OutgoingAttachment> _streamOversized(
    List<OutgoingAttachment> attachments,
  ) {
    int inlineTotal = 0;
    List<OutgoingAttachment>? result;
    for (int i = 0; i < attachments.length; i++) {
      final OutgoingAttachment attachment = attachments[i];
      final String? data = attachment.data;
      if (attachment is StreamedAttachment || data == null) continue;
      final int size = _decodedLength(data);
      if (size <= kMaxAttachmentBytes &&
          inlineTotal + size <= kMaxAttachmentTotalBytes) {
        inlineTotal += size;
        continue;
      }
      final Uint8List bytes = base64Decode(data);
      result ??= List<OutgoingAttachment>.of(attachments);
      result[i] = StreamedAttachment(
        name: attachment.name,
        mimeType: attachment.mimeType,
        size: bytes.length,
        read: (int offset, int length) async => Uint8List.sublistView(
          bytes,
          offset,
          math.min(bytes.length, offset + length),
        ),
      );
    }
    return result ?? attachments;
  }

  /// Decoded size of padded base64 [data] without decoding it.
  static int _decodedLength(String data) {
    int padding = 0;
    if (data.endsWith('==')) {
      padding = 2;
    } else if (data.endsWith('=')) {
      padding = 1;
    }
    return data.length ~/ 4 * 3 - padding;
  }

  /// Uploads each [StreamedAttachment] in order, one chunk in flight at a
  /// time, and returns [attachments] with those replaced by upload ids.
  Future<List<OutgoingAttachment>> _uploadStreamed(
    DaemonClient client,
    List<OutgoingAttachment> attachments,
    List<String> uploadIds,
    ValueNotifier<double> progress,
  ) async {
    int total = 0;
    for (final OutgoingAttachment attachment in attachments) {
      if (attachment is StreamedAttachment) total += attachment.size;
    }
    int done = 0;
    final List<OutgoingAttachment> sent = <OutgoingAttachment>[];
    for (final OutgoingAttachment attachment in attachments) {
      if (attachment is! StreamedAttachment) {
        sent.add(attachment);
        continue;
      }
      final String uploadId = await client.beginUpload(attachment.size);
      uploadIds.add(uploadId);
      int offset = 0;
      while (offset < attachment.size) {
        final Uint8List chunk = await attachment.read(
          offset,
          math.min(kMaxUploadChunkBytes, attachment.size - offset),
        );
        if (chunk.isEmpty) {
          throw StateError('${attachment.name} ended before its full size');
        }
        offset = await client.appendUpload(uploadId, offset, chunk);
        done += chunk.length;
        progress.value = total == 0 ? 1 : done / total;
      }
      sent.add(
        OutgoingAttachment(
          name: attachment.name,
          mimeType: attachment.mimeType,
          uploadId: uploadId,
        ),
      );
    }
    progress.value = 1;
    return sent;
  }

  Future<List<NativeCommand>> listCommands(String daemonId, String sessionId) =>
      _clientFor(daemonId).listCommands(sessionId);

  /// Starts a native command turn, tracked through [outgoingFor] like
  /// [send].
  Future<void> runCommand(
    String daemonId,
    String sessionId,
    String name, {
    String arguments = '',
  }) => _sendOutgoing(
    daemonId,
    sessionId,
    // PROTOCOL.md `sessions.command`: the daemon persists exactly this text
    // as the turn's user event.
    '/$name${arguments.isEmpty ? '' : ' $arguments'}',
    const <OutgoingAttachment>[],
    () =>
        _clientFor(daemonId).runCommand(sessionId, name, arguments: arguments),
  );

  Future<void> _sendOutgoing(
    String daemonId,
    String sessionId,
    String text,
    List<OutgoingAttachment> attachments,
    Future<void> Function() request, {
    ValueListenable<double>? upload,
  }) async {
    final _SessionBuffer? buffer = _buffers[_scopedKey(daemonId, sessionId)];
    final OutgoingMessage? message = buffer?.eventSub == null
        ? null
        : OutgoingMessage(
            id: _nextOutgoingId++,
            text: text,
            attachments: attachments,
            upload: upload,
          );
    if (message != null) {
      buffer!.outgoing.add(message);
      _scheduleNotify();
    }
    try {
      await request();
    } on Object catch (error) {
      _lastError = error;
      _scheduleNotify();
      if (message != null && buffer!.outgoing.remove(message)) {
        _scheduleNotify();
      }
      rethrow;
    }
    // Usually the echo already retired it; otherwise it is still in flight.
    if (message != null && buffer!.outgoing.contains(message)) {
      buffer.acknowledged.add(message.id);
    }
  }

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

  Future<void> retryMessage(String daemonId, String sessionId, int seq) async {
    try {
      await _clientFor(daemonId).retryMessage(sessionId, seq);
    } on Object catch (error) {
      _lastError = error;
      _scheduleNotify();
      rethrow;
    }
  }

  Future<void> cancel(String daemonId, String sessionId) =>
      _clientFor(daemonId).cancelSession(sessionId);

  Future<void> respondPermission(
    String daemonId,
    String sessionId,
    String requestId,
    String optionId, {
    List<UserQuestionAnswer>? answers,
  }) =>
      _clientFor(daemonId)
          .respondPermission(sessionId, requestId, optionId, answers: answers);

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
      (_SessionBuffer b) => b.daemonId == daemonId && b.eventSub != null,
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
    _scheduleNotify();
  }

  void _onSessionRemoved(String daemonId, String sessionId) {
    final String key = _scopedKey(daemonId, sessionId);
    final _SessionBuffer? buffer = _buffers.remove(key);
    _retainedKeys.remove(key);
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
        if (buffer.daemonId == daemonId &&
            buffer.eventSub != null &&
            buffer.historyLoaded &&
            !buffer.resyncing)
          buffer,
    ];
    if (buffers.isEmpty) return;
    for (final _SessionBuffer buffer in buffers) {
      buffer.resyncing = true;
    }
    _scheduleNotify();
    for (final _SessionBuffer buffer in buffers) {
      await _resyncBuffer(client, buffer, alreadyMarked: true);
    }
  }

  Future<void> _resyncBuffer(
    DaemonClient client,
    _SessionBuffer buffer, {
    bool alreadyMarked = false,
    Future<_HistoryPage>? firstPage,
  }) async {
    if (client is SavedHistoryClient && !client.isConnected) {
      buffer.resyncing = false;
      _scheduleNotify();
      return;
    }
    if (!alreadyMarked) {
      if (buffer.resyncing) return;
      buffer.resyncing = true;
      _scheduleNotify();
    }
    final bool replaceSaved = buffer.savedOnly || buffer.replaceOnResync;
    final int knownMaxSeq = replaceSaved
        ? (buffer.oldestSeq ?? 0) - 1
        : buffer.maxSeq;
    try {
      final List<List<SessionEvent>> pages = <List<SessionEvent>>[];
      int? beforeSeq;
      bool hasMore = false;
      while (true) {
        if (client is SavedHistoryClient && !client.isConnected) {
          throw StateError('Daemon disconnected while updating conversation');
        }
        final _HistoryPage page =
            await (firstPage ??
                client.history(
                  buffer.sessionId,
                  limit: historyPageSize,
                  beforeSeq: beforeSeq,
                ));
        firstPage = null;
        if (client is SavedHistoryClient && !client.isConnected) {
          throw StateError('Daemon disconnected while updating conversation');
        }
        pages.add(page.events);
        hasMore = page.hasMore;
        if (replaceSaved ||
            page.events.isEmpty ||
            page.events.first.seq == null ||
            page.events.first.seq! <= knownMaxSeq + 1 ||
            !page.hasMore) {
          break;
        }
        beforeSeq = page.events.first.seq;
      }
      if (replaceSaved) {
        // Replace the saved summary with one normal latest page. Never walk
        // backwards to fill gaps in a sparse local summary; older pages stay lazy.
        _resetHistory(buffer);
        buffer.historyReplacementRevision++;
        buffer.hasOlderHistory = hasMore;
        buffer.oldestSeq = pages.last.firstOrNull?.seq;
      }
      for (final List<SessionEvent> page in pages.reversed) {
        for (final SessionEvent event in page) {
          _applyLive(buffer, event, live: false);
        }
      }
      // Replayed pages never set status (see [_noteEvent]); a missed
      // session.updated while out of reach is recovered from a snapshot.
      unawaited(_seedSession(client, buffer.daemonId, buffer.sessionId));
      buffer.savedOnly = false;
      buffer.savedComplete = buffer.savedComplete || !buffer.hasOlderHistory;
      buffer.replaceOnResync = false;
      buffer.historyError = null;
    } on Object catch (error) {
      buffer.replaceOnResync = true;
      buffer.historyError = error;
      _lastError = error;
    } finally {
      buffer.resyncing = false;
      final List<SessionEvent> pending = List<SessionEvent>.of(buffer.pending)
        ..sort(
          (SessionEvent a, SessionEvent b) =>
              (a.seq ?? 0).compareTo(b.seq ?? 0),
        );
      buffer.pending.clear();
      for (final SessionEvent event in pending) {
        _applyLive(buffer, event);
      }
      _scheduleNotify();
    }
  }

  void _onLiveEvent(_SessionBuffer buffer, SessionEvent event) {
    final int? seq = event.seq;
    if (!buffer.historyLoaded || buffer.resyncing) {
      buffer.pending.add(event);
      return;
    }
    if (seq != null && seq > buffer.maxSeq + 1) {
      buffer.pending.add(event);
      buffer.resyncing = true;
      _scheduleNotify();
      unawaited(
        _resyncBuffer(_clientFor(buffer.daemonId), buffer, alreadyMarked: true),
      );
      return;
    }
    _applyLive(buffer, event);
  }

  /// Applies [event] in seq order, skipping duplicates. [live] is false for
  /// events fetched from history during a resync: they may predate the
  /// current turn, so they must not derive status (see [_noteEvent]).
  void _applyLive(
    _SessionBuffer buffer,
    SessionEvent event, {
    bool live = true,
  }) {
    final int? seq = event.seq;
    if (seq != null && seq <= buffer.maxSeq) return; // duplicate
    _append(buffer, event, live: live);
    if (seq != null && seq > buffer.maxSeq) buffer.maxSeq = seq;
    _scheduleNotify();
  }

  /// Page size for history loads. Keeping frames modest protects mobile
  /// clients from oversized JSON responses while still filling a screen in
  /// one round trip.
  /// Loads the newest persisted-history page for a newly watched session.
  Future<void> _loadHistory(DaemonClient client, _SessionBuffer buffer) async {
    _resetHistory(buffer);
    Future<_HistoryPage>? fetch;
    try {
      if (client is SavedHistoryClient) {
        if (client.isConnected) {
          // A saved summary differs from the real page, so showing one just
          // before the other makes the conversation jump. Only a slow fetch
          // is worth that.
          fetch = client.history(buffer.sessionId, limit: historyPageSize);
          if (await _landsWithin(fetch, savedHistoryPatience)) {
            await _applyFetchedHistory(buffer, fetch);
            return;
          }
        }
        final saved = await (client as SavedHistoryClient).savedHistory(
          buffer.sessionId,
          limit: historyPageSize,
        );
        if (saved != null) {
          buffer.savedOnly = true;
          buffer.savedComplete = saved.complete;
          buffer.oldestSeq = saved.events.firstOrNull?.seq;
          buffer.hasOlderHistory = saved.hasMore;
          _applyLatestHistoryPage(buffer, saved.events);
          if (client.isConnected) {
            await _resyncBuffer(client, buffer, firstPage: fetch);
          }
          return;
        }
      }
    } on Object catch (error) {
      // A broken disk snapshot must not prevent fetching authoritative history.
      _lastError = error;
      _scheduleNotify();
    }
    await _applyFetchedHistory(
      buffer,
      fetch ?? client.history(buffer.sessionId, limit: historyPageSize),
    );
  }

  /// Whether [fetch] succeeds within [patience]. A failure counts as not
  /// landing, so saved content still shows; whoever awaits [fetch] next sees
  /// the error.
  Future<bool> _landsWithin(
    Future<_HistoryPage> fetch,
    Duration patience,
  ) async {
    final Completer<bool> landed = Completer<bool>();
    final Timer timer = Timer(patience, () {
      if (!landed.isCompleted) landed.complete(false);
    });
    unawaited(
      fetch.then(
        (_) {
          timer.cancel();
          if (!landed.isCompleted) landed.complete(true);
        },
        onError: (Object _) {
          timer.cancel();
          if (!landed.isCompleted) landed.complete(false);
        },
      ),
    );
    return landed.future;
  }

  Future<void> _applyFetchedHistory(
    _SessionBuffer buffer,
    Future<_HistoryPage> fetch,
  ) async {
    try {
      final _HistoryPage page = await fetch;
      _applyLatestHistoryPage(buffer, page.events);
      buffer.hasOlderHistory = page.hasMore;
      buffer.savedComplete = !page.hasMore;
      if (page.events.isNotEmpty) buffer.oldestSeq = page.events.first.seq;
      buffer.savedOnly = false;
      buffer.historyError = null;
    } catch (error) {
      buffer.historyError = error;
      _lastError = error;
    } finally {
      buffer.historyLoaded = true;
      for (final SessionEvent event in buffer.pending) {
        _applyLive(buffer, event);
      }
      buffer.pending.clear();
      _scheduleNotify();
    }
  }

  void _resetHistory(_SessionBuffer buffer) {
    final bool hadEvents = buffer.events.isNotEmpty;
    buffer.events.clear();
    buffer.rewinds.clear();
    buffer.permissions.clear();
    buffer.chunkRun = null;
    buffer.maxSeq = 0;
    buffer.oldestSeq = null;
    buffer.hasOlderHistory = false;
    buffer.olderHistoryError = null;
    _usageById.remove(buffer.key);
    if (hadEvents) _revisions[buffer.key] = (_revisions[buffer.key] ?? 0) + 1;
  }

  /// Appends the newest history page (the first one fetched) oldest-first
  /// and immediately publishes the buffer as loaded, so live events stop
  /// parking and the UI can render while older pages stream in.
  void _applyLatestHistoryPage(_SessionBuffer buffer, List<SessionEvent> page) {
    for (final SessionEvent event in page) {
      _append(buffer, event, live: false);
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
    buffer.events.insertAll(
      0,
      page.where(
        (event) => !buffer.rewinds.any(
          (rewind) =>
              event.seq != null &&
              event.seq! >= rewind.beforeSeq &&
              event.seq! < rewind.seq!,
        ),
      ),
    );
    buffer.permissions.clear();
    for (final SessionEvent event in buffer.events) {
      _notePermission(buffer, event);
    }
    _revisions[buffer.key] = (_revisions[buffer.key] ?? 0) + page.length;
    _scheduleNotify();
  }

  /// Appends [event], merging consecutive chunk deltas of the same kind into
  /// one buffered event, and records any derived state it carries. Every
  /// call is a buffer mutation, so it bumps the session's revision.
  void _append(
    _SessionBuffer buffer,
    SessionEvent event, {
    required bool live,
  }) {
    if (event is HistoryRewoundEvent) {
      if (event.seq != null) buffer.rewinds.add(event);
      _closeChunkRun(buffer);
      buffer.events.removeWhere(
        (e) =>
            e.seq != null &&
            e.seq! >= event.beforeSeq &&
            (event.seq == null || e.seq! < event.seq!),
      );
      buffer.permissions.clear();
      buffer.deliveredSeqs.removeWhere((seq) => seq >= event.beforeSeq);
      _usageById.remove(buffer.key);
      for (final retained in buffer.events) {
        _notePermission(buffer, retained);
        if (retained is UsageEvent) _usageById[buffer.key] = retained.usage;
      }
      buffer.oldestSeq = buffer.events.firstOrNull?.seq ?? event.seq;
    }

    _notePermission(buffer, event);
    _revisions[buffer.key] = (_revisions[buffer.key] ?? 0) + 1;

    // A switch over the sealed type reaches the chunk getters via pattern
    // bindings (an `is A || is B` test would not promote the scrutinee).
    switch (event) {
      case AgentMessageChunkEvent(
        :final String text,
        :final String? messageId,
        :final int? seq,
        :final DateTime? timestamp,
      ):
        _mergeChunk(
          buffer,
          isMessage: true,
          text: text,
          messageId: messageId,
          seq: seq,
          timestamp: timestamp,
          event: event,
          live: live,
        );
      case AgentThoughtChunkEvent(
        :final String text,
        :final String? messageId,
        :final int? seq,
        :final DateTime? timestamp,
      ):
        _mergeChunk(
          buffer,
          isMessage: false,
          text: text,
          messageId: messageId,
          seq: seq,
          timestamp: timestamp,
          event: event,
          live: live,
        );
      default:
        _closeChunkRun(buffer);
        buffer.events.add(event);
        _noteEvent(buffer, event, live: live);
    }
  }

  /// Extends the open same-family chunk run with [text], or — when [event]
  /// opens a different family or no run is open — closes any open run and
  /// starts a fresh one. Never merges message chunks with thought chunks.
  void _mergeChunk(
    _SessionBuffer buffer, {
    required bool isMessage,
    required String text,
    required String? messageId,
    required int? seq,
    required DateTime? timestamp,
    required SessionEvent event,
    required bool live,
  }) {
    final _ChunkRun? run = buffer.chunkRun;
    if (run != null &&
        run.isMessage == isMessage &&
        run.messageId == messageId) {
      // Same-kind run continues: accumulate in the scratch buffer only.
      run.buffer.write(text);
      run.dirty = true;
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
      messageId: messageId,
      seq: seq,
      timestamp: timestamp,
    );
    buffer.events.add(event);
    _noteEvent(buffer, event, live: live);
  }

  /// Replaces the tail event with one built from the run's scratch buffer —
  /// the merged text, built once at its final size. Leaves the run open so
  /// more same-kind chunks can keep accumulating.
  void _materializeChunkRun(_SessionBuffer buffer) {
    final _ChunkRun? run = buffer.chunkRun;
    if (run == null || !run.dirty) return;
    run.dirty = false;
    final List<SessionEvent> events = buffer.events;
    if (events.isEmpty) {
      buffer.chunkRun = null;
      return;
    }
    events[events.length - 1] = run.isMessage
        ? AgentMessageChunkEvent(
            text: run.buffer.toString(),
            messageId: run.messageId,
            seq: run.seq,
            timestamp: run.timestamp,
          )
        : AgentThoughtChunkEvent(
            text: run.buffer.toString(),
            messageId: run.messageId,
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

  void _notePermission(_SessionBuffer buffer, SessionEvent event) {
    switch (event) {
      case PermissionRequestEvent(:final request):
        buffer.permissions.remove(request.requestId);
        buffer.permissions[request.requestId] = request;
      case PermissionResolvedEvent(:final requestId):
        buffer.permissions.remove(requestId);
      default:
        break;
    }
  }

  /// Records derived state carried by [event]. Only [live] events change
  /// status: a replayed history page holds earlier turns' `turnComplete`s,
  /// and applying them could mark a running turn idle after the session
  /// snapshot said otherwise (re-enabling Send mid-turn). Session snapshots
  /// (`session.updated`, [_seedSession]) own status for history.
  void _noteEvent(
    _SessionBuffer buffer,
    SessionEvent event, {
    required bool live,
  }) {
    switch (event) {
      case final UserMessageEvent message:
        _deliverOutgoing(buffer, message);
      case TurnCompleteEvent():
        if (live) _statusById[buffer.key] = SessionStatus.idle;
        _dropAcknowledged(buffer);
      case SessionErrorEvent():
        if (live) _statusById[buffer.key] = SessionStatus.error;
        _dropAcknowledged(buffer);
      // Permission events do not imply a status: auto-approved requests and
      // requests from the agent's own background work arrive outside a turn,
      // and no turnComplete follows them. The daemon broadcasts the real
      // waitingPermission/running transitions as session.updated.
      case UsageEvent(:final usage):
        _usageById[buffer.key] = usage;
      default:
        break;
    }
  }

  /// Retires the oldest outgoing message [event] echoes, remembering its seq
  /// so the timeline can celebrate that arrival.
  void _deliverOutgoing(_SessionBuffer buffer, UserMessageEvent event) {
    final List<OutgoingMessage> outgoing = buffer.outgoing;
    for (int i = 0; i < outgoing.length; i++) {
      final OutgoingMessage message = outgoing[i];
      if (message.text != event.text ||
          message.attachments.length != event.attachments.length) {
        continue;
      }
      outgoing.removeAt(i);
      buffer.acknowledged.remove(message.id);
      final int? seq = event.seq;
      if (seq != null) buffer.deliveredSeqs.add(seq);
      return;
    }
  }

  /// Events arrive in seq order and an acknowledged send's echo precedes the
  /// turn's end, so an acknowledged message still unmatched here never will
  /// be; drop it rather than leave it pending forever.
  void _dropAcknowledged(_SessionBuffer buffer) {
    if (buffer.acknowledged.isEmpty) return;
    buffer.outgoing.removeWhere(
      (OutgoingMessage message) => buffer.acknowledged.contains(message.id),
    );
    buffer.acknowledged.clear();
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
    _retainedKeys.clear();
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
