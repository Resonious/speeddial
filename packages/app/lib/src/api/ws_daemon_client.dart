import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'daemon_client.dart';

/// Live [DaemonClient] speaking PROTOCOL.md's JSON-RPC 2.0 envelope over a
/// WebSocket. Transport is `package:web_socket_channel` (works on native and
/// web; no `dart:io` import), decoded frames are fed to an [RpcPeer].
///
/// [connect] must be called before use: the client authenticates first when a
/// [token] is configured and then switches `connState` to connected. Socket
/// drops (server close or network error) and failed initial connects alike
/// are retried with exponential backoff starting at [reconnectBase] (doubling
/// per attempt, capped at 15s); after each successful connect that followed
/// a failure the client re-authenticates and emits on [resynced] so stores
/// can backfill history missed while offline. [retryNow] resets the backoff
/// and retries immediately.
///
/// Live notifications are broadcast without buffering: a session that nobody
/// is watching simply loses its events (stores watch deliberately and recover
/// through [resynced] + `history()`).
class WsDaemonClient implements DaemonClient {
  WsDaemonClient({
    required this.url,
    this.token,
    // The explicit initializer (rather than a `this.` formal) keeps the
    // field's default next to its declaration.
    Duration reconnectBase = const Duration(milliseconds: 500),
  }) : reconnectBase = reconnectBase; // ignore: prefer_initializing_formals

  /// WebSocket endpoint, e.g. `ws://127.0.0.1:7331/ws`.
  final String url;

  /// Token for `auth.authenticate`; null means the daemon requires none
  /// (loopback per PROTOCOL.md).
  final String? token;

  /// Delay of the first reconnect attempt; every retry doubles this,
  /// capped at 15 seconds.
  final Duration reconnectBase;

  /// Live connection state; drive UI/status off this (or [isConnected]).
  /// Starts at [DaemonConnectionState.connecting].
  final ValueNotifier<DaemonConnectionState> connState =
      ValueNotifier<DaemonConnectionState>(DaemonConnectionState.connecting);

  /// Emits after each successful reconnect (never on the first connect).
  final StreamController<void> _resyncController =
      StreamController<void>.broadcast();

  /// Every decoded `session.event` notification, keyed by session id.
  final StreamController<({String sessionId, SessionEvent event})>
      _sessionEventFeed = StreamController.broadcast();

  final StreamController<Session> _sessionUpdatesController =
      StreamController<Session>.broadcast();

  final StreamController<String> _sessionRemovalsController =
      StreamController<String>.broadcast();

  final StreamController<void> _projectsChangedController =
      StreamController<void>.broadcast();

  static const Duration _maxReconnectDelay = Duration(seconds: 15);

  WebSocketChannel? _channel;

  /// Whether [_channel] has completed its connect handshake (`ready`). Only
  /// an established channel gets a graceful (awaited) close; closing a
  /// channel whose handshake failed can wait forever for a close handshake
  /// the peer will never send, so those are released without awaiting.
  bool _socketReady = false;
  RpcPeer? _peer;
  StreamSubscription<dynamic>? _socketSub;
  StreamSubscription<RpcNotification>? _notificationSub;
  Timer? _reconnectTimer;
  Future<void>? _inFlightConnect;
  bool _establishing = false;
  int _reconnectAttempt = 0;

  /// Set by any connect failure or socket drop; the next successful
  /// establish emits [resynced] (stores may have missed events meanwhile)
  /// and clears it. Keeps the very first clean connect from emitting.
  bool _resyncNeeded = false;
  bool _disposed = false;

  // ---------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------

  /// Opens the socket (authenticating when [token] is set) and switches
  /// [connState] to connected. Idempotent: a no-op while a connection attempt
  /// is in flight or the client is already connected. A failed auth (or any
  /// other initial-connect failure) propagates as a [DaemonError] and leaves
  /// [connState] at [DaemonConnectionState.failed], with the backoff retry
  /// armed — the state self-heals to connected once the daemon answers.
  Future<void> connect() {
    if (_disposed) return Future<void>.value();
    final Future<void>? inFlight = _inFlightConnect;
    if (inFlight != null) return inFlight;
    if (connState.value == DaemonConnectionState.connected) {
      return Future<void>.value();
    }
    final Future<void> attempt =
        _establish(initial: true).whenComplete(() => _inFlightConnect = null);
    _inFlightConnect = attempt;
    return attempt;
  }

  /// Establishes one connection. [initial] distinguishes the user-visible
  /// first connect (failures propagate, state ends `failed`) from automatic
  /// reconnects (failures only schedule another backoff retry). Either way a
  /// failure arms the backoff timer, so a `failed` initial connect still
  /// self-heals once the daemon comes up.
  Future<void> _establish({required bool initial}) async {
    if (_disposed) return;
    _establishing = true;
    try {
      connState.value = initial
          ? DaemonConnectionState.connecting
          : DaemonConnectionState.reconnecting;
      await _openSocket();
      if (_disposed) return;
      final String? token = this.token;
      if (token != null) {
        await _peer!.call(
          'auth.authenticate',
          <String, Object?>{'token': token},
        );
      }
      if (_disposed) return;
      connState.value = DaemonConnectionState.connected;
      _reconnectAttempt = 0;
      if (!initial || _resyncNeeded) {
        // Back on the wire after a gap: stores backfill what they missed
        // while offline (or while the first connect was failing).
        _resyncNeeded = false;
        _resyncController.add(null);
      }
    } on DaemonError {
      if (_disposed) return;
      _resyncNeeded = true;
      await _tearDownSocket();
      _scheduleReconnect();
      if (initial) {
        connState.value = DaemonConnectionState.failed;
        rethrow;
      }
    } on Object {
      if (_disposed) return;
      _resyncNeeded = true;
      await _tearDownSocket();
      _scheduleReconnect();
      if (initial) {
        connState.value = DaemonConnectionState.failed;
        rethrow;
      }
    } finally {
      _establishing = false;
    }
  }

  /// Closes the current socket and its peer, if any. Idempotent; safe to run
  /// when the transport already shut the channel down on its own.
  Future<void> _tearDownSocket() async {
    final WebSocketChannel? channel = _channel;
    final bool established = _socketReady;
    _channel = null;
    _socketReady = false;
    await _notificationSub?.cancel();
    _notificationSub = null;
    await _socketSub?.cancel();
    _socketSub = null;
    await _peer?.close();
    _peer = null;
    if (channel == null) return;
    if (established) {
      // The handshake completed, so a close frame round-trips normally.
      try {
        await channel.sink.close();
      } on Object {
        // Already closed by the transport; nothing to do.
      }
    } else {
      // The channel never completed its handshake (connection refused,
      // unreachable host): adapters' `sink.close()` can wait forever for a
      // close handshake that will never arrive. Release it without awaiting
      // — the socket is unreachable either way.
      unawaited(_closeQuietly(channel));
    }
  }

  /// Best-effort close that never blocks or propagates.
  Future<void> _closeQuietly(WebSocketChannel channel) async {
    try {
      await channel.sink.close();
    } on Object {
      // The socket was never established; nothing to clean up.
    }
  }

  /// Opens a fresh socket and attaches a fresh [RpcPeer] to it.
  Future<void> _openSocket() async {
    final Uri uri = Uri.parse(url);
    if (uri.scheme != 'ws' && uri.scheme != 'wss') {
      throw ArgumentError.value(url, 'url', 'WebSocket URL must use ws:// or wss://');
    }
    final WebSocketChannel channel = WebSocketChannel.connect(uri);
    _channel = channel;
    await channel.ready;
    _socketReady = true;
    if (_disposed) {
      await channel.sink.close();
      return;
    }
    _peer?.close();
    await _notificationSub?.cancel();

    final StreamController<Object?> incoming = StreamController<Object?>();
    final RpcPeer peer = RpcPeer(
      incoming: incoming.stream,
      send: (Object? message) {
        try {
          channel.sink.add(jsonEncode(message));
        } on Object {
          // Socket may be closing underneath; the drop handler covers it.
        }
      },
    );
    _peer = peer;
    _notificationSub = peer.notifications.listen(_handleNotification);
    _socketSub = channel.stream.listen(
      (Object? data) {
        if (data is String) {
          try {
            incoming.add(jsonDecode(data));
          } on FormatException {
            // Malformed frame: ignore, mirroring RpcPeer's tolerance.
          }
        }
      },
      onError: (Object _) {
        unawaited(incoming.close());
        _handleSocketClosed();
      },
      onDone: () {
        unawaited(incoming.close());
        _handleSocketClosed();
      },
    );
  }

  /// The socket ended or errored: unblock pending calls and schedule a
  /// reconnect. During an in-flight [connect]/[reconnect] the establish flow
  /// itself disposes of the failure, so it does nothing here.
  void _handleSocketClosed() {
    if (_disposed) return;
    _channel = null;
    _socketReady = false;
    unawaited(_peer?.close());
    if (_establishing) return;
    _resyncNeeded = true;
    connState.value = DaemonConnectionState.reconnecting;
    _scheduleReconnect();
  }

  /// Arms the exponential-backoff retry timer. base * 2^n, capped at 15s.
  /// Touches no state: the caller owns the visible state (`reconnecting` for
  /// a dropped socket, `failed` until the retry starts for an initial
  /// connect), and the attempt itself flips to `reconnecting` when it runs.
  void _scheduleReconnect() {
    if (_disposed) return;
    final int attempt = _reconnectAttempt++;
    var ms = reconnectBase.inMilliseconds;
    for (var i = 0;
        i < attempt && ms < _maxReconnectDelay.inMilliseconds;
        i++) {
      ms *= 2;
    }
    if (ms > _maxReconnectDelay.inMilliseconds) {
      ms = _maxReconnectDelay.inMilliseconds;
    }
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: ms < 1 ? 1 : ms), () {
      if (_disposed || _establishing) return;
      // A manual connect() may have won the race since this was scheduled.
      if (connState.value == DaemonConnectionState.connected) return;
      unawaited(_establish(initial: false));
    });
  }

  @override
  bool get isConnected => connState.value == DaemonConnectionState.connected;

  /// Manual retry hook for the UI: cancels any pending backoff attempt,
  /// resets the backoff counter, and reconnects immediately. No-op when
  /// disposed or already connected; an in-flight attempt is joined.
  void retryNow() {
    if (_disposed) return;
    if (connState.value == DaemonConnectionState.connected) return;
    _reconnectTimer?.cancel();
    _reconnectAttempt = 0;
    unawaited(connect());
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _tearDownSocket();
    await _sessionEventFeed.close();
    await _sessionUpdatesController.close();
    await _sessionRemovalsController.close();
    await _projectsChangedController.close();
    await _resyncController.close();
    connState.dispose();
  }

  // ---------------------------------------------------------------------
  // Inbound notifications
  // ---------------------------------------------------------------------

  void _handleNotification(RpcNotification notification) {
    if (_disposed) return;
    final Map<String, Object?> params = notification.params;
    switch (notification.method) {
      case 'session.event':
        final Object? sessionId = params['sessionId'];
        final Object? event = params['event'];
        if (sessionId is String && event is Map) {
          // The daemon stamps seq/timestamp into the event itself; fall back
          // to the envelope-level fields for lenient servers.
          final Map<String, Object?> eventJson = Map<String, Object?>.from(
            event,
          );
          eventJson.putIfAbsent('seq', () => params['seq']);
          eventJson.putIfAbsent('timestamp', () => params['timestamp']);
          try {
            _sessionEventFeed.add((
              sessionId: sessionId,
              event: SessionEvent.fromJson(eventJson),
            ));
          } on Object {
            // Malformed event: drop rather than kill the notification feed.
          }
        }
      case 'session.created':
      case 'session.updated':
        final Object? session = params['session'];
        if (session is Map) {
          try {
            _sessionUpdatesController
                .add(Session.fromJson(Map<String, Object?>.from(session)));
          } on Object {
            // Malformed session: drop.
          }
        }
      case 'session.removed':
        final Object? sessionId = params['sessionId'];
        if (sessionId is String) {
          _sessionRemovalsController.add(sessionId);
        }
      case 'projects.changed':
        _projectsChangedController.add(null);
    }
  }

  // ---------------------------------------------------------------------
  // Live streams
  // ---------------------------------------------------------------------

  @override
  Stream<SessionEvent> sessionEvents(String sessionId) =>
      _sessionEventFeed.stream
          .where((({String sessionId, SessionEvent event}) entry) =>
              entry.sessionId == sessionId)
          .map((({String sessionId, SessionEvent event}) entry) =>
              entry.event);

  @override
  Stream<Session> get sessionUpdates => _sessionUpdatesController.stream;

  @override
  Stream<String> get sessionRemovals => _sessionRemovalsController.stream;

  @override
  Stream<void> get projectsChanged => _projectsChangedController.stream;

  @override
  Stream<void> get resynced => _resyncController.stream;

  // ---------------------------------------------------------------------
  // Daemon / projects
  // ---------------------------------------------------------------------

  @override
  Future<DaemonInfo> info() async {
    final Object? result = await _requirePeer().call('daemon.info');
    return DaemonInfo.fromJson(_resultMap(result));
  }

  @override
  Future<List<Project>> listProjects() async {
    final Object? result = await _requirePeer().call('projects.list');
    return _decodeList(_resultField(result, 'projects'), Project.fromJson);
  }

  @override
  Future<Project> addProject(String path, {String? name}) async {
    final Object? result = await _requirePeer().call(
      'projects.add',
      <String, Object?>{'path': path, 'name': ?name},
    );
    return Project.fromJson(_resultMap(_resultField(result, 'project')));
  }

  @override
  Future<void> removeProject(String id) async {
    await _requirePeer().call('projects.remove', <String, Object?>{'id': id});
  }

  // ---------------------------------------------------------------------
  // Sessions
  // ---------------------------------------------------------------------

  @override
  Future<List<Session>> listSessions({
    String? projectId,
    bool includeArchived = false,
  }) async {
    final Object? result = await _requirePeer().call(
      'sessions.list',
      <String, Object?>{
        'projectId': ?projectId,
        'includeArchived': includeArchived,
      },
    );
    return _decodeList(_resultField(result, 'sessions'), Session.fromJson);
  }

  @override
  Future<Session> createSession({
    required String projectId,
    required String providerId,
    String? model,
    SessionMode? mode,
    String? title,
    String? baseBranch,
  }) async {
    final Object? result = await _requirePeer().call(
      'sessions.create',
      <String, Object?>{
        'projectId': projectId,
        'providerId': providerId,
        'model': ?model,
        'mode': ?mode?.wire,
        'title': ?title,
        'baseBranch': ?baseBranch,
      },
    );
    return Session.fromJson(_resultMap(_resultField(result, 'session')));
  }

  @override
  Future<void> sendMessage(
    String sessionId,
    String text, {
    List<OutgoingAttachment> attachments = const [],
  }) async {
    await _requirePeer().call(
      'sessions.send',
      <String, Object?>{
        'sessionId': sessionId,
        'text': text,
        // PROTOCOL.md: the wire param is omitted entirely when empty; the
        // daemon rejects `sessions.send` without text *and* without
        // attachments, so clients never send a bare attachment list here.
        if (attachments.isNotEmpty)
          'attachments':
              attachments.map((OutgoingAttachment a) => a.toJson()).toList(growable: false),
      },
    );
  }

  @override
  Future<AttachmentData> readAttachment(
    String sessionId,
    String attachmentId,
  ) async {
    final Object? result = await _requirePeer().call(
      'attachments.read',
      <String, Object?>{'sessionId': sessionId, 'attachmentId': attachmentId},
    );
    return AttachmentData.fromJson(_resultMap(_resultField(result, 'attachment')));
  }

  @override
  Future<void> cancelSession(String sessionId) async {
    await _requirePeer()
        .call('sessions.cancel', <String, Object?>{'sessionId': sessionId});
  }

  @override
  Future<Session> renameSession(String sessionId, String title) async {
    final Object? result = await _requirePeer().call(
      'sessions.rename',
      <String, Object?>{'sessionId': sessionId, 'title': title},
    );
    return Session.fromJson(_resultMap(_resultField(result, 'session')));
  }

  @override
  Future<Session> archiveSession(String sessionId, bool archived) async {
    final Object? result = await _requirePeer().call(
      'sessions.archive',
      <String, Object?>{'sessionId': sessionId, 'archived': archived},
    );
    return Session.fromJson(_resultMap(_resultField(result, 'session')));
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    await _requirePeer().call(
      'sessions.delete',
      <String, Object?>{'sessionId': sessionId},
    );
  }

  @override
  Future<Session> setMode(String sessionId, SessionMode mode) async {
    final Object? result = await _requirePeer().call(
      'sessions.setMode',
      <String, Object?>{'sessionId': sessionId, 'mode': mode.wire},
    );
    return Session.fromJson(_resultMap(_resultField(result, 'session')));
  }

  @override
  Future<Session> setModel(String sessionId, String model) async {
    final Object? result = await _requirePeer().call(
      'sessions.setModel',
      <String, Object?>{'sessionId': sessionId, 'model': model},
    );
    return Session.fromJson(_resultMap(_resultField(result, 'session')));
  }

  @override
  Future<({List<SessionEvent> events, bool hasMore})> history(
    String sessionId, {
    int limit = 200,
    int? beforeSeq,
  }) async {
    final Object? result = await _requirePeer().call(
      'sessions.history',
      <String, Object?>{
        'sessionId': sessionId,
        'limit': limit,
        'beforeSeq': ?beforeSeq,
      },
    );
    return (
      events: _decodeList(_resultField(result, 'events'), SessionEvent.fromJson),
      hasMore: _resultField(result, 'hasMore') == true,
    );
  }

  @override
  Future<void> respondPermission(
    String sessionId,
    String requestId,
    String optionId,
  ) async {
    await _requirePeer().call(
      'sessions.respondPermission',
      <String, Object?>{
        'sessionId': sessionId,
        'requestId': requestId,
        'optionId': optionId,
      },
    );
  }

  // ---------------------------------------------------------------------
  // Files
  // ---------------------------------------------------------------------

  @override
  Future<List<FileEntry>> listFiles(String projectId,
      [String path = '.']) async {
    final Object? result = await _requirePeer().call(
      'fs.list',
      <String, Object?>{'projectId': projectId, 'path': path},
    );
    return _decodeList(_resultField(result, 'entries'), FileEntry.fromJson);
  }

  @override
  Future<FileReadResult> readFile(
    String projectId,
    String path, {
    int? maxBytes,
  }) async {
    final Object? result = await _requirePeer().call(
      'fs.read',
      <String, Object?>{
        'projectId': projectId,
        'path': path,
        'maxBytes': ?maxBytes,
      },
    );
    return FileReadResult.fromJson(_resultMap(result));
  }

  // ---------------------------------------------------------------------
  // Git
  // ---------------------------------------------------------------------

  @override
  Future<GitStatus> gitStatus(String projectId, {String? sessionId}) async {
    final Object? result = await _requirePeer().call(
      'git.status',
      <String, Object?>{'projectId': projectId, 'sessionId': ?sessionId},
    );
    return GitStatus.fromJson(_resultMap(_resultField(result, 'status')));
  }

  @override
  Future<List<GitDiff>> gitDiff(
    String projectId, {
    String? sessionId,
    String? path,
    bool staged = false,
  }) async {
    final Object? result = await _requirePeer().call(
      'git.diff',
      <String, Object?>{
        'projectId': projectId,
        'sessionId': ?sessionId,
        'path': ?path,
        'staged': staged,
      },
    );
    return _decodeList(_resultField(result, 'diffs'), GitDiff.fromJson);
  }

  @override
  Future<List<Branch>> gitBranches(String projectId,
      {String? sessionId}) async {
    final Object? result = await _requirePeer().call(
      'git.branches',
      <String, Object?>{'projectId': projectId, 'sessionId': ?sessionId},
    );
    return _decodeList(_resultField(result, 'branches'), Branch.fromJson);
  }

  @override
  Future<void> gitCheckout(String projectId, String branch,
      {String? sessionId}) async {
    await _requirePeer().call(
      'git.checkout',
      <String, Object?>{
        'projectId': projectId,
        'sessionId': ?sessionId,
        'branch': branch,
      },
    );
  }

  @override
  Future<String> gitCommit(
    String projectId,
    String message, {
    String? sessionId,
    bool stageAll = false,
  }) async {
    final Object? result = await _requirePeer().call(
      'git.commit',
      <String, Object?>{
        'projectId': projectId,
        'sessionId': ?sessionId,
        'message': message,
        'stageAll': stageAll,
      },
    );
    return _resultField(result, 'commitHash')! as String;
  }

  @override
  Future<void> gitPush(String projectId, {String? sessionId}) async {
    await _requirePeer().call(
        'git.push',
        <String, Object?>{'projectId': projectId, 'sessionId': ?sessionId});
  }

  @override
  Future<MergeResult> gitMergeToBase(String projectId,
      {required String sessionId}) async {
    final Object? result = await _requirePeer().call(
      'git.mergeToBase',
      <String, Object?>{'projectId': projectId, 'sessionId': sessionId},
    );
    return MergeResult.fromJson(_resultMap(_resultField(result, 'merge')));
  }

  @override
  Future<RebaseResult> gitRebaseOntoBase(String projectId,
      {required String sessionId}) async {
    final Object? result = await _requirePeer().call(
      'git.rebaseOntoBase',
      <String, Object?>{'projectId': projectId, 'sessionId': sessionId},
    );
    return RebaseResult.fromJson(_resultMap(_resultField(result, 'rebase')));
  }

  @override
  Future<String> gitCreatePr(
    String projectId, {
    String? sessionId,
    String? title,
    String? body,
    String? base,
    bool draft = false,
  }) async {
    final Object? result = await _requirePeer().call(
      'git.createPullRequest',
      <String, Object?>{
        'projectId': projectId,
        'sessionId': ?sessionId,
        'title': ?title,
        'body': ?body,
        'base': ?base,
        'draft': draft,
      },
    );
    return _resultField(result, 'url')! as String;
  }

  @override
  Future<List<SessionGitSummary>> gitSessionSummaries(String projectId) async {
    final Object? result = await _requirePeer().call(
      'git.sessionSummaries',
      <String, Object?>{'projectId': projectId},
    );
    return _decodeList(
        _resultField(result, 'summaries'), SessionGitSummary.fromJson);
  }

  // ---------------------------------------------------------------------
  // Result decoding helpers
  // ---------------------------------------------------------------------

  RpcPeer _requirePeer() {
    if (_disposed) {
      throw const DaemonConnectionError('daemon client disposed');
    }
    final RpcPeer? peer = _peer;
    if (peer == null || connState.value != DaemonConnectionState.connected) {
      throw const DaemonConnectionError('daemon client is not connected');
    }
    return peer;
  }

  static Map<String, Object?> _resultMap(Object? raw) {
    if (raw is Map) return Map<String, Object?>.from(raw);
    throw DaemonError(kErrInternal, 'malformed result: expected an object');
  }

  static Object? _resultField(Object? result, String key) {
    final Map<String, Object?> map = _resultMap(result);
    if (!map.containsKey(key)) {
      throw DaemonError(kErrInternal, 'malformed result: missing "$key"');
    }
    return map[key];
  }

  static List<T> _decodeList<T>(
    Object? raw,
    T Function(Map<String, Object?>) fromJson,
  ) {
    if (raw is! List) {
      throw DaemonError(kErrInternal, 'malformed result: expected a list');
    }
    return <T>[
      for (final Object? item in raw) fromJson(_resultMap(item)),
    ];
  }
}
