import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'daemon_client.dart';

/// One bidirectional stream of daemon WebSocket text frames.
///
/// The normal implementation wraps `package:web_socket_channel`. The Wear OS
/// target injects a channel whose frames cross the Wear Data Layer and whose
/// actual WebSocket is opened by the paired phone. Keeping this boundary at
/// raw text frames preserves the protocol codec, authentication, reconnect,
/// and notification behavior in one place.
abstract interface class DaemonFrameChannel {
  Future<void> get ready;
  Stream<Object?> get stream;
  void add(Object? data);
  Future<void> close();
}

typedef DaemonFrameChannelFactory = DaemonFrameChannel Function(Uri uri);

class _WebSocketDaemonFrameChannel implements DaemonFrameChannel {
  _WebSocketDaemonFrameChannel(Uri uri)
    : _channel = WebSocketChannel.connect(uri);

  final WebSocketChannel _channel;

  @override
  Future<void> get ready => _channel.ready;

  @override
  Stream<Object?> get stream => _channel.stream;

  @override
  void add(Object? data) => _channel.sink.add(data);

  @override
  Future<void> close() => _channel.sink.close();
}

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
    DaemonFrameChannelFactory? channelFactory,
    // The explicit initializers (rather than `this.` formals) keep each
    // field's default next to its declaration.
    Duration reconnectBase = const Duration(milliseconds: 500),
    Duration livenessProbeTimeout = const Duration(seconds: 3),
    this.historyDetail = SessionHistoryDetail.full,
  }) : _channelFactory = channelFactory ?? _WebSocketDaemonFrameChannel.new,
       reconnectBase = reconnectBase, // ignore: prefer_initializing_formals
       // ignore: prefer_initializing_formals
       livenessProbeTimeout = livenessProbeTimeout;

  /// WebSocket endpoint, e.g. `ws://127.0.0.1:7331/ws`.
  final String url;

  /// Token for `auth.authenticate`; null means the daemon requires none
  /// (loopback per PROTOCOL.md).
  final String? token;

  final DaemonFrameChannelFactory _channelFactory;

  /// Delay of the first reconnect attempt; every retry doubles this,
  /// capped at 15 seconds.
  final Duration reconnectBase;

  /// How long [verifyLiveness] waits for the daemon to answer its probe
  /// before declaring the socket half-dead (see there).
  final Duration livenessProbeTimeout;

  /// Projection requested for persisted history pages. Compact targets use
  /// summary events while desktop/mobile retain the full payload by default.
  final SessionHistoryDetail historyDetail;

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

  final StreamController<String> _gitChangedController =
      StreamController<String>.broadcast();

  final StreamController<String> _sessionRemovalsController =
      StreamController<String>.broadcast();

  final StreamController<void> _projectsChangedController =
      StreamController<void>.broadcast();

  static const Duration _maxReconnectDelay = Duration(seconds: 15);

  DaemonFrameChannel? _channel;

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
  /// [connState] to connected. Idempotent: joins any connection attempt
  /// already in flight (including an automatic reconnect), or is a no-op when
  /// the client is already connected. A failed auth (or any other
  /// initial-connect failure) propagates as a [DaemonError] and leaves
  /// [connState] at [DaemonConnectionState.failed], with the backoff retry
  /// armed — the state self-heals to connected once the daemon answers.
  Future<void> connect() => _startEstablish(initial: true);

  Future<void> _startEstablish({required bool initial}) {
    if (_disposed) return Future<void>.value();
    final Future<void>? inFlight = _inFlightConnect;
    if (inFlight != null) return inFlight;
    if (connState.value == DaemonConnectionState.connected &&
        _channel != null &&
        _socketReady &&
        _peer != null) {
      return Future<void>.value();
    }
    late final Future<void> attempt;
    attempt = _establish(initial: initial).whenComplete(() {
      if (identical(_inFlightConnect, attempt)) _inFlightConnect = null;
    });
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
        await _peer!.call('auth.authenticate', <String, Object?>{
          'token': token,
        });
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
      if (initial) connState.value = DaemonConnectionState.failed;
      rethrow;
    } on Object {
      if (_disposed) return;
      _resyncNeeded = true;
      await _tearDownSocket();
      _scheduleReconnect();
      if (initial) connState.value = DaemonConnectionState.failed;
      rethrow;
    } finally {
      _establishing = false;
    }
  }

  /// Closes the current socket and its peer, if any. Idempotent; safe to run
  /// when the transport already shut the channel down on its own.
  Future<void> _tearDownSocket() async {
    final DaemonFrameChannel? channel = _channel;
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
        await channel.close();
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
  Future<void> _closeQuietly(DaemonFrameChannel channel) async {
    try {
      await channel.close();
    } on Object {
      // The socket was never established; nothing to clean up.
    }
  }

  /// Opens a fresh socket and attaches a fresh [RpcPeer] to it.
  Future<void> _openSocket() async {
    final Uri uri = Uri.parse(url);
    if (uri.scheme != 'ws' && uri.scheme != 'wss') {
      throw ArgumentError.value(
        url,
        'url',
        'WebSocket URL must use ws:// or wss://',
      );
    }
    final DaemonFrameChannel channel = _channelFactory(uri);
    _channel = channel;
    await channel.ready;
    _socketReady = true;
    if (_disposed) {
      await channel.close();
      return;
    }
    _peer?.close();
    await _notificationSub?.cancel();

    final StreamController<Object?> incoming = StreamController<Object?>();
    final RpcPeer peer = RpcPeer(
      incoming: incoming.stream,
      send: (Object? message) {
        try {
          channel.add(jsonEncode(message));
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
      onError: (Object error) {
        _handleSocketClosed(
          channel,
          error: DaemonConnectionError(_transportErrorText(error)),
        );
        unawaited(incoming.close());
      },
      onDone: () {
        _handleSocketClosed(channel);
        unawaited(incoming.close());
      },
    );
  }

  /// The socket ended or errored: unblock pending calls and schedule a
  /// reconnect. During an in-flight [connect]/[reconnect] the establish flow
  /// itself disposes of the failure, so it does nothing here.
  void _handleSocketClosed(
    DaemonFrameChannel source, {
    DaemonConnectionError error = const DaemonConnectionError('peer closed'),
  }) {
    if (_disposed || !identical(_channel, source)) return;
    _channel = null;
    _socketReady = false;
    unawaited(_peer?.close(error));
    if (_establishing) return;
    _resyncNeeded = true;
    connState.value = DaemonConnectionState.reconnecting;
    _scheduleReconnect();
  }

  static String _transportErrorText(Object error) {
    if (error is PlatformException) {
      final String? message = error.message?.trim();
      return message == null || message.isEmpty ? error.code : message;
    }
    if (error is DaemonError) return error.message;
    return error.toString();
  }

  /// Arms the exponential-backoff retry timer. base * 2^n, capped at 15s.
  /// Touches no state: the caller owns the visible state (`reconnecting` for
  /// a dropped socket, `failed` until the retry starts for an initial
  /// connect), and the attempt itself flips to `reconnecting` when it runs.
  void _scheduleReconnect() {
    if (_disposed) return;
    final int attempt = _reconnectAttempt++;
    var ms = reconnectBase.inMilliseconds;
    for (
      var i = 0;
      i < attempt && ms < _maxReconnectDelay.inMilliseconds;
      i++
    ) {
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
      // Automatic retries are best-effort, but they still occupy the shared
      // single-flight future so a foreground action can join this exact
      // attempt instead of opening a competing socket.
      unawaited(
        _startEstablish(initial: false).catchError((Object _) {
          // The failed attempt scheduled the next retry before rethrowing.
        }),
      );
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
    unawaited(
      connect().catchError((Object _) {
        // The failed attempt scheduled the next retry before rethrowing.
      }),
    );
  }

  /// Probes a socket that believes itself connected and tears it down when
  /// the daemon does not answer within [livenessProbeTimeout].
  ///
  /// Device suspend can kill the TCP connection without delivering a close
  /// event: [connState] then stays `connected` while every call hangs and
  /// no resync ever runs. Call this on app resume; a failed probe flips to
  /// [DaemonConnectionState.reconnecting] and arms the backoff retry, whose
  /// successful establish emits [resynced] like any other reconnect. A
  /// merely slow answer is treated as dead too — the reconnect it triggers
  /// is cheap, unlike a stale socket. `daemon.info` is answered pre-auth,
  /// so the probe works even if the daemon forgot the authentication.
  Future<void> verifyLiveness() async {
    if (_disposed || connState.value != DaemonConnectionState.connected) {
      return;
    }
    final RpcPeer? peer = _peer;
    if (peer == null || !_socketReady) return;
    try {
      await peer.call('daemon.info').timeout(livenessProbeTimeout);
    } on Object {
      // A genuine drop raced the probe: its close handler already tore the
      // socket down and armed its own reconnect; do not double up.
      if (_disposed || connState.value != DaemonConnectionState.connected) {
        return;
      }
      _resyncNeeded = true;
      connState.value = DaemonConnectionState.reconnecting;
      await _tearDownSocket();
      if (_disposed) return;
      _scheduleReconnect();
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _tearDownSocket();
    await _sessionUpdatesController.close();
    await _gitChangedController.close();
    await _sessionEventFeed.close();
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
            _sessionUpdatesController.add(
              Session.fromJson(Map<String, Object?>.from(session)),
            );
          } on Object {
            // Malformed session: drop.
          }
        }
      case 'session.removed':
        final Object? sessionId = params['sessionId'];
        if (sessionId is String) {
          _sessionRemovalsController.add(sessionId);
        }
      case 'git.changed':
        final Object? projectId = params['projectId'];
        if (projectId is String) {
          _gitChangedController.add(projectId);
        }
      case 'projects.changed':
        _projectsChangedController.add(null);
    }
  }

  // ---------------------------------------------------------------------
  // Live streams
  // ---------------------------------------------------------------------

  @override
  Stream<SessionEvent> sessionEvents(String sessionId) => _sessionEventFeed
      .stream
      .where(
        (({String sessionId, SessionEvent event}) entry) =>
            entry.sessionId == sessionId,
      )
      .map((({String sessionId, SessionEvent event}) entry) => entry.event);

  @override
  Stream<Session> get sessionUpdates => _sessionUpdatesController.stream;

  @override
  Stream<String> get sessionRemovals => _sessionRemovalsController.stream;

  @override
  Stream<String> get gitChanged => _gitChangedController.stream;

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
  Future<List<HarnessInfo>> listHarnesses() async {
    final Object? result = await _requirePeer().call('harnesses.list');
    return _decodeList(_resultField(result, 'harnesses'), HarnessInfo.fromJson);
  }

  @override
  Future<HarnessInfo> updateHarness(String id) async {
    final Object? result = await _requirePeer().call(
      'harnesses.update',
      <String, Object?>{'id': id},
    );
    return HarnessInfo.fromJson(_resultMap(_resultField(result, 'harness')));
  }

  @override
  Future<List<String>> listEnvironmentNames() async {
    final Object? result = await _requirePeer().call('environment.list');
    return (_resultField(result, 'names') as List<Object?>)
        .cast<String>()
        .toList(growable: false);
  }

  @override
  Future<List<String>> updateEnvironment({
    Map<String, String> set = const <String, String>{},
    List<String> remove = const <String>[],
  }) async {
    final Object? result = await _requirePeer().call(
      'environment.update',
      <String, Object?>{'set': set, 'remove': remove},
    );
    return (_resultField(result, 'names') as List<Object?>)
        .cast<String>()
        .toList(growable: false);
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
  // MCP servers
  // ---------------------------------------------------------------------

  @override
  Future<List<McpServerProfile>> listMcpServers() async {
    final Object? result = await _requirePeer().call('mcp.list');
    return _decodeList(
      _resultField(result, 'servers'),
      McpServerProfile.fromJson,
    );
  }

  @override
  Future<McpServerProfile> createMcpServer({
    required String name,
    required McpTransport transport,
    required bool enabled,
    String? projectId,
    String? command,
    List<String> args = const <String>[],
    String? url,
    Map<String, String> secrets = const <String, String>{},
    McpAuthType authType = McpAuthType.none,
    String? oauthClientId,
    String? oauthClientSecret,
  }) async {
    final Object? result = await _requirePeer().call(
      'mcp.create',
      <String, Object?>{
        'name': name,
        'transport': transport.wire,
        'enabled': enabled,
        'projectId': ?projectId,
        'command': ?command,
        'args': args,
        'url': ?url,
        'secrets': secrets,
        'authType': authType.wire,
        'oauthClientId': ?oauthClientId,
        'oauthClientSecret': ?oauthClientSecret,
      },
    );
    return McpServerProfile.fromJson(
      _resultMap(_resultField(result, 'server')),
    );
  }

  @override
  Future<McpServerProfile> updateMcpServer({
    required String id,
    required String name,
    required McpTransport transport,
    required bool enabled,
    required String? projectId,
    String? command,
    List<String> args = const <String>[],
    String? url,
    Map<String, String> secrets = const <String, String>{},
    List<String> removeSecretNames = const <String>[],
    McpAuthType authType = McpAuthType.none,
    String? oauthClientId,
    String? oauthClientSecret,
  }) async {
    final Object? result = await _requirePeer().call(
      'mcp.update',
      <String, Object?>{
        'id': id,
        'name': name,
        'transport': transport.wire,
        'enabled': enabled,
        'projectId': projectId,
        'command': ?command,
        'args': args,
        'url': ?url,
        'secrets': secrets,
        'removeSecretNames': removeSecretNames,
        'authType': authType.wire,
        'oauthClientId': ?oauthClientId,
        'oauthClientSecret': ?oauthClientSecret,
      },
    );
    return McpServerProfile.fromJson(
      _resultMap(_resultField(result, 'server')),
    );
  }

  @override
  Future<void> deleteMcpServer(String id) async {
    await _requirePeer().call('mcp.delete', <String, Object?>{'id': id});
  }

  @override
  Future<McpOAuthFlow> beginMcpOAuth(String id, {Uri? redirectUri}) async {
    final Uri callback = redirectUri ?? _daemonOAuthRedirectUri();
    final Object? result = await _requirePeer().call(
      'mcp.oauth.begin',
      <String, Object?>{'id': id, 'redirectUri': callback.toString()},
    );
    return McpOAuthFlow.fromJson(_resultMap(_resultField(result, 'flow')));
  }

  Uri _daemonOAuthRedirectUri() {
    final Uri endpoint = Uri.parse(url);
    final bool secure = endpoint.scheme == 'wss';
    if (!secure && !_isLoopbackOAuthHost(endpoint.host)) {
      throw DaemonError(
        kErrProviderUnavailable,
        'MCP OAuth for a remote daemon requires a wss:// endpoint with '
        'HTTPS /oauth/callback routing, or OAuth 2.1 (localhost)',
      );
    }
    return endpoint.replace(
      scheme: secure ? 'https' : 'http',
      // Canonicalize local IPv4 aliases because authorization servers may
      // recognize only numeric loopback redirect URIs. IPv6 stays on ::1.
      host: secure
          ? endpoint.host
          : endpoint.host == '::1'
          ? '::1'
          : '127.0.0.1',
      path: '/oauth/callback',
      query: null,
      fragment: null,
    );
  }

  bool _isLoopbackOAuthHost(String host) {
    final String normalized = host.toLowerCase();
    return normalized == 'localhost' ||
        normalized == '::1' ||
        normalized == '0:0:0:0:0:0:0:1' ||
        normalized.startsWith('127.');
  }

  @override
  Future<McpServerProfile> completeMcpOAuth(
    String id,
    String flowId,
    Uri callbackUri,
  ) async {
    final Object? result = await _requirePeer().call(
      'mcp.oauth.complete',
      <String, Object?>{
        'id': id,
        'flowId': flowId,
        'callbackUri': callbackUri.toString(),
      },
    );
    return McpServerProfile.fromJson(
      _resultMap(_resultField(result, 'server')),
    );
  }

  @override
  Future<McpServerProfile> mcpOAuthStatus(String id, String flowId) async {
    final Object? result = await _requirePeer().call(
      'mcp.oauth.status',
      <String, Object?>{'id': id, 'flowId': flowId},
    );
    return McpServerProfile.fromJson(
      _resultMap(_resultField(result, 'server')),
    );
  }

  @override
  Future<McpServerProfile> disconnectMcpOAuth(String id) async {
    final Object? result = await _requirePeer().call(
      'mcp.oauth.disconnect',
      <String, Object?>{'id': id},
    );
    return McpServerProfile.fromJson(
      _resultMap(_resultField(result, 'server')),
    );
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
    SessionSandboxMode? sandboxMode,
    bool yolo = false,
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
        'sandboxMode': ?sandboxMode?.wire,
        if (yolo) 'yolo': true,
      },
    );
    return Session.fromJson(_resultMap(_resultField(result, 'session')));
  }

  @override
  Future<Session> forkSession(String sessionId, int seq) async {
    final Object? result = await _requirePeer().call(
      'sessions.fork',
      <String, Object?>{'sessionId': sessionId, 'seq': seq},
    );
    return Session.fromJson(_resultMap(_resultField(result, 'session')));
  }

  @override
  Future<void> sendMessage(
    String sessionId,
    String text, {
    List<OutgoingAttachment> attachments = const [],
  }) async {
    await _requirePeer().call('sessions.send', <String, Object?>{
      'sessionId': sessionId,
      'text': text,
      // PROTOCOL.md: the wire param is omitted entirely when empty; the
      // daemon rejects `sessions.send` without text *and* without
      // attachments, so clients never send a bare attachment list here.
      if (attachments.isNotEmpty)
        'attachments': attachments
            .map((OutgoingAttachment a) => a.toJson())
            .toList(growable: false),
    });
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
    return AttachmentData.fromJson(
      _resultMap(_resultField(result, 'attachment')),
    );
  }

  @override
  Future<void> cancelSession(String sessionId) async {
    await _requirePeer().call('sessions.cancel', <String, Object?>{
      'sessionId': sessionId,
    });
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
  Future<Session> pinSession(String sessionId, bool pinned) async {
    final Object? result = await _requirePeer().call(
      'sessions.pin',
      <String, Object?>{'sessionId': sessionId, 'pinned': pinned},
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
  Future<Session> acknowledgeCompletion(
    String sessionId,
    int completionRevision,
  ) async {
    final Object? result = await _requirePeer().call(
      'sessions.acknowledgeCompletion',
      <String, Object?>{
        'sessionId': sessionId,
        'completionRevision': completionRevision,
      },
    );
    return Session.fromJson(_resultMap(_resultField(result, 'session')));
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    await _requirePeer().call('sessions.delete', <String, Object?>{
      'sessionId': sessionId,
    });
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
  Future<Session> setThinkingLevel(String sessionId, String level) async {
    final Object? result = await _requirePeer().call(
      'sessions.setThinkingLevel',
      <String, Object?>{'sessionId': sessionId, 'level': level},
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
        if (historyDetail != SessionHistoryDetail.full)
          'detail': historyDetail.wire,
      },
    );
    return (
      events: _decodeList(
        _resultField(result, 'events'),
        SessionEvent.fromJson,
      ),
      hasMore: _resultField(result, 'hasMore') == true,
    );
  }

  @override
  Future<void> respondPermission(
    String sessionId,
    String requestId,
    String optionId,
  ) async {
    await _requirePeer().call('sessions.respondPermission', <String, Object?>{
      'sessionId': sessionId,
      'requestId': requestId,
      'optionId': optionId,
    });
  }

  // ---------------------------------------------------------------------
  // Files
  // ---------------------------------------------------------------------

  @override
  Future<List<FileEntry>> listFiles(
    String projectId, [
    String path = '.',
  ]) async {
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

  @override
  Future<FileDownload> downloadFile(String sessionId, String path) async {
    final Object? result = await _requirePeer().call(
      'fs.download',
      <String, Object?>{'sessionId': sessionId, 'path': path},
    );
    return FileDownload.fromJson(_resultMap(result));
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
  Future<List<Branch>> gitBranches(
    String projectId, {
    String? sessionId,
  }) async {
    final Object? result = await _requirePeer().call(
      'git.branches',
      <String, Object?>{'projectId': projectId, 'sessionId': ?sessionId},
    );
    return _decodeList(_resultField(result, 'branches'), Branch.fromJson);
  }

  @override
  Future<void> gitCheckout(
    String projectId,
    String branch, {
    String? sessionId,
  }) async {
    await _requirePeer().call('git.checkout', <String, Object?>{
      'projectId': projectId,
      'sessionId': ?sessionId,
      'branch': branch,
    });
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
    await _requirePeer().call('git.push', <String, Object?>{
      'projectId': projectId,
      'sessionId': ?sessionId,
    });
  }

  @override
  Future<MergeResult> gitMergeToBase(
    String projectId, {
    required String sessionId,
  }) async {
    final Object? result = await _requirePeer().call(
      'git.mergeToBase',
      <String, Object?>{'projectId': projectId, 'sessionId': sessionId},
    );
    return MergeResult.fromJson(_resultMap(_resultField(result, 'merge')));
  }

  @override
  Future<RebaseResult> gitRebaseOntoBase(
    String projectId, {
    required String sessionId,
  }) async {
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
      _resultField(result, 'summaries'),
      SessionGitSummary.fromJson,
    );
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
    return <T>[for (final Object? item in raw) fromJson(_resultMap(item))];
  }
}
