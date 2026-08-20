/// WebSocket JSON-RPC server implementing PROTOCOL.md exactly.
///
/// One HTTP server upgrades `GET /ws` connections to WebSockets; each
/// connection is one [RpcPeer] answering the full protocol method surface.
/// Text frames carry exactly one JSON-RPC message. When an [authToken] is
/// configured, connections start unauthenticated: only `auth.authenticate`
/// and `daemon.info` are answered until the token is proven, and
/// notifications fan out to authenticated clients only.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:uuid/uuid.dart';

import '../engine/session_engine.dart';
import '../git/git_service.dart';
import '../git/pr_service.dart';
import '../mcp/built_in_mcp_server.dart';
import '../paths.dart';
import '../git/summary_watcher.dart';
import '../providers/provider_registry.dart';
import '../store/daemon_store.dart';
import 'fs_service.dart';
import 'mcp_oauth_service.dart';

/// Daemon semver reported by `daemon.info`; keep in sync with pubspec.yaml.
const String kDaemonVersion = '0.1.0';

/// JSON-RPC code: invalid params.
const int _kErrInvalidParams = -32602;

/// Wire protocol version (PROTOCOL.md).
const int _kProtocolVersion = 1;

/// Every method PROTOCOL.md defines; one handler is registered per method.
const List<String> _kProtocolMethods = <String>[
  'auth.authenticate',
  'daemon.info',
  'providers.list',
  'attachments.read',
  'mcp.list',
  'mcp.create',
  'mcp.update',
  'mcp.delete',
  'mcp.oauth.begin',
  'mcp.oauth.status',
  'mcp.oauth.disconnect',
  'projects.list',
  'projects.add',
  'projects.remove',
  'projects.rename',
  'sessions.list',
  'sessions.create',
  'sessions.fork',
  'sessions.send',
  'sessions.cancel',
  'sessions.rename',
  'sessions.archive',
  'sessions.delete',
  'sessions.setMode',
  'sessions.setModel',
  'sessions.setThinkingLevel',
  'sessions.history',
  'sessions.respondPermission',
  'fs.list',
  'fs.read',
  'git.status',
  'git.diff',
  'git.branches',
  'git.checkout',
  'git.createBranch',
  'git.commit',
  'git.push',
  'git.createPullRequest',
  'git.mergeToBase',
  'git.rebaseOntoBase',
  'git.sessionSummaries',
];

const List<String> _kInternalMcpMethods = <String>[
  'internal.mcpAuthenticate',
  'internal.mcpSearchProjects',
  'internal.mcpSearchSessions',
  'internal.mcpDisplayImage',
];

/// One connected client: its peer, socket, and authentication state.
class _Client {
  _Client({
    required this.peer,
    required this.socket,
    required this.authenticated,
  });

  final RpcPeer peer;
  final WebSocket socket;
  bool authenticated;
  String? mcpSessionId;
}

/// Implements the SpeedDial daemon wire API over WebSocket JSON-RPC.
class SpeedDialServer {
  SpeedDialServer({
    required SessionEngine engine,
    required DaemonStore store,
    required ProviderRegistry providers,
    GitService? git,
    PrService? pr,
    String? authToken,
    this.gitPollInterval = const Duration(seconds: 15),
    this.gitFetchInterval = const Duration(minutes: 2),
  }) : _engine = engine, // ignore: prefer_initializing_formals
       _store = store, // ignore: prefer_initializing_formals
       _providers = providers, // ignore: prefer_initializing_formals
       _authToken = authToken, // ignore: prefer_initializing_formals
       _git = git ?? GitService(),
       _pr = pr ?? PrService() {
    _init();
  }

  /// Binds an [HttpServer] on [host]:[port] and wires it to [engine]/[store].
  static Future<SpeedDialServer> bind({
    required String host,
    required int port,
    required SessionEngine engine,
    required DaemonStore store,
    required ProviderRegistry providers,
    String? authToken,
    GitService? git,
    PrService? pr,
    Duration gitPollInterval = const Duration(seconds: 15),
    Duration gitFetchInterval = const Duration(minutes: 2),
  }) async {
    final server = SpeedDialServer(
      engine: engine,
      store: store,
      providers: providers,
      authToken: authToken,
      git: git,
      pr: pr,
      gitPollInterval: gitPollInterval,
      gitFetchInterval: gitFetchInterval,
    );
    await server._bind(host, port);
    return server;
  }

  final SessionEngine _engine;
  final DaemonStore _store;
  final ProviderRegistry _providers;
  final String? _authToken;
  final GitService _git;
  final PrService _pr;
  final FsService _fs = FsService();
  final Uuid _uuid = const Uuid();
  final Map<String, String> _mcpSecretsBySession = <String, String>{};
  McpOAuthService? _oauth;

  String _mcpSecretForSession(String sessionId) => _mcpSecretsBySession
      .putIfAbsent(sessionId, () => '${_uuid.v4()}${_uuid.v4()}');

  /// How often the summary watcher recomputes session summaries, and how
  /// often it refetches a project's base branches. Injectable for tests.
  final Duration gitPollInterval;
  final Duration gitFetchInterval;
  late final SummaryWatcher _summaryWatcher;

  HttpServer? _httpServer;
  final List<_Client> _clients = <_Client>[];
  late final StreamSubscription<
    ({String sessionId, int seq, SessionEvent event})
  >
  _eventsSub;
  late final StreamSubscription<Session> _changesSub;
  late final StreamSubscription<String> _removalsSub;
  bool _closed = false;

  /// Session ids whose `session.created` broadcast has been sent. The engine
  /// publishes `session.updated` during `sessions.create` (before the wire
  /// handler has broadcast `session.created`); relaying those would deliver
  /// an update for a session the client has never seen created. The relay
  /// skips ids absent from this set, the create handler adds the id right
  /// after broadcasting `session.created`, and removals drop it.
  final Set<String> _createdBroadcast = <String>{};

  /// The bound port (meaningful after [bind]).
  int get port => _httpServer?.port ?? 0;

  /// Shuts the server down: closes every client connection, cancels the
  /// engine subscriptions, and releases the [HttpServer]. Idempotent.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _summaryWatcher.close();
    await _eventsSub.cancel();
    await _changesSub.cancel();
    await _removalsSub.cancel();
    for (final client in _clients.toList()) {
      client.peer.close();
      unawaited(
        client.socket
            .close(WebSocketStatus.normalClosure, 'daemon closing')
            .catchError((Object _) {}),
      );
    }
    _clients.clear();
    _oauth?.close();
    await _httpServer?.close(force: true);
  }

  // -------------------------------------------------------------------------
  // Startup wiring
  // -------------------------------------------------------------------------
  void _init() {
    _summaryWatcher = SummaryWatcher(
      store: _store,
      git: _git,
      hasClients: () => _clients.any((_Client client) => client.authenticated),
      pollInterval: gitPollInterval,
      fetchInterval: gitFetchInterval,
      onChanged: (String projectId) =>
          _broadcast('git.changed', <String, Object?>{'projectId': projectId}),
    )..start();

    // Broadcast every engine emission as a PROTOCOL.md notification. The
    // events stream carries persisted events (seq + timestamp already
    // stamped by the engine), so they are forwarded verbatim.
    _eventsSub = _engine.events.listen((tuple) {
      _broadcast('session.event', <String, Object?>{
        'sessionId': tuple.sessionId,
        'seq': tuple.seq,
        'event': tuple.event.toJson(),
      });
    });
    _changesSub = _engine.sessionChanges.listen((session) {
      // Skip updates for sessions whose `session.created` has not been
      // broadcast yet: the engine emits updates while `sessions.create` is
      // still in flight, and a client must observe created before updated.
      if (!_createdBroadcast.contains(session.id)) return;
      _broadcast('session.updated', <String, Object?>{
        'session': session.toJson(),
      });
    });
    _removalsSub = _engine.sessionRemovals.listen((sessionId) {
      _createdBroadcast.remove(sessionId);
      _mcpSecretsBySession.remove(sessionId);
      _broadcast('session.removed', <String, Object?>{'sessionId': sessionId});
    });
  }

  Future<void> _bind(String host, int port) async {
    _httpServer = await HttpServer.bind(host, port);
    final String loopbackHost =
        _httpServer!.address.type == InternetAddressType.IPv6
        ? '::1'
        : '127.0.0.1';
    final String daemonUrl = Uri(
      scheme: 'ws',
      host: loopbackHost,
      port: _httpServer!.port,
      path: '/ws',
    ).toString();
    final launch = builtInMcpLaunchCommand();
    _engine.configureBuiltInMcp(
      daemonUrl: daemonUrl,
      secretForSession: _mcpSecretForSession,
      command: launch.command,
      args: launch.args,
    );
    _oauth = McpOAuthService(
      store: _store,
      onChanged: (String serverId) => _engine.reloadMcpServers(
        projectId: _store.getMcpServer(serverId)?.projectId,
      ),
    );
    _engine.configureMcpAuth(prepare: _oauth!.refreshEnabled);
    _httpServer!.listen(_handleRequest);
  }

  // -------------------------------------------------------------------------
  // Connection handling
  // -------------------------------------------------------------------------

  Future<void> _handleRequest(HttpRequest request) async {
    if (request.method == 'GET' && request.uri.path == '/oauth/callback') {
      await _oauth!.handleCallback(request);
      return;
    }
    if (request.uri.path == '/ws' &&
        WebSocketTransformer.isUpgradeRequest(request)) {
      // Cross-Site WebSocket Hijacking: a browser page on any origin can open
      // a WebSocket to the daemon (cookies are not involved, but an Origin
      // check keeps third-party pages from driving the local daemon). When an
      // Origin is present its host must be loopback; non-browser clients
      // (like our CLI) send no Origin and are always allowed.
      final origin = request.headers.value('origin');
      if (origin != null && !_isLoopbackOrigin(origin)) {
        request.response
          ..statusCode = HttpStatus.forbidden
          ..write('forbidden')
          ..close();
        return;
      }
      try {
        final socket = await WebSocketTransformer.upgrade(request);
        unawaited(
          _handleSocket(socket).catchError((Object _) {
            // Connection died before the handler wiring settled.
          }),
        );
      } on Object {
        // Handshake failed mid-upgrade: nothing left to respond to.
      }
      return;
    }
    request.response
      ..statusCode = HttpStatus.notFound
      ..write('not found')
      ..close();
  }

  Future<void> _handleSocket(WebSocket socket) async {
    final incoming = StreamController<Object?>(sync: true);
    final client = _Client(
      socket: socket,
      peer: RpcPeer(
        incoming: incoming.stream,
        send: (message) => _sendJson(socket, message),
      ),
      authenticated: _authToken == null,
    );
    _clients.add(client);
    for (final method in _kProtocolMethods) {
      client.peer.registerHandler(
        method,
        (params) => _dispatch(client, method, params),
      );
    }
    for (final method in _kInternalMcpMethods) {
      client.peer.registerHandler(
        method,
        (params) => _dispatch(client, method, params),
      );
    }
    socket.listen(
      (data) {
        if (data is! String) return; // Binary frames carry no JSON-RPC.
        Object? decoded;
        try {
          decoded = jsonDecode(data);
        } on FormatException {
          return; // Malformed frame: ignore.
        }
        incoming.add(decoded);
      },
      onDone: () => _dropClient(client, incoming),
      onError: (Object _) => _dropClient(client, incoming),
    );
  }

  /// Whether an Origin header's host is loopback (localhost / 127.0.0.1 /
  /// ::1). Malformed or opaque origins ("null") have no host and are not
  /// loopback.
  bool _isLoopbackOrigin(String origin) {
    final Uri? uri = Uri.tryParse(origin);
    return uri != null && _isLoopbackHost(uri.host);
  }

  bool _isLoopbackHost(String host) {
    if (host.toLowerCase() == 'localhost') return true;
    return InternetAddress.tryParse(host)?.isLoopback ?? false;
  }

  void _dropClient(_Client client, StreamController<Object?> incoming) {
    _clients.remove(client);
    client.peer.close();
    if (!incoming.isClosed) incoming.close();
  }

  void _sendJson(WebSocket socket, Object? message) {
    try {
      // Text frame per PROTOCOL.md: one JSON-RPC message per string frame.
      socket.add(jsonEncode(message));
    } on Object {
      // Socket is closing; the done handler reaps this client.
    }
  }

  void _broadcast(String method, Map<String, Object?> params) {
    for (final client in _clients) {
      if (!client.authenticated) continue;
      client.peer.notify(method, params);
    }
  }

  // -------------------------------------------------------------------------
  // Method dispatch
  // -------------------------------------------------------------------------

  FutureOr<Object?> _dispatch(
    _Client client,
    String method,
    Map<String, Object?> params,
  ) {
    if (method == 'internal.mcpAuthenticate') {
      return _mcpAuthenticate(client, params);
    }
    if (client.mcpSessionId != null) {
      return switch (method) {
        'internal.mcpSearchProjects' => _mcpSearchProjects(client, params),
        'internal.mcpSearchSessions' => _mcpSearchSessions(client, params),
        'internal.mcpDisplayImage' => _mcpDisplayImage(client, params),
        _ => throw DaemonError(
          kErrUnauthenticated,
          'MCP bridge connections may only call internal MCP methods',
        ),
      };
    }
    if (method.startsWith('internal.')) {
      throw DaemonError(kErrUnauthenticated, 'MCP authentication required');
    }
    if (!client.authenticated) {
      return switch (method) {
        'auth.authenticate' => _authenticate(client, params),
        'daemon.info' => _daemonInfo(),
        _ => throw DaemonError(kErrUnauthenticated, 'authentication required'),
      };
    }
    return switch (method) {
      'auth.authenticate' => _authenticate(client, params),
      'daemon.info' => _daemonInfo(),
      'providers.list' => _providersList(),
      'mcp.list' => _mcpList(),
      'mcp.create' => _mcpCreate(params),
      'mcp.update' => _mcpUpdate(params),
      'mcp.delete' => _mcpDelete(params),
      'mcp.oauth.begin' => _mcpOAuthBegin(params),
      'mcp.oauth.status' => _mcpOAuthStatus(params),
      'mcp.oauth.disconnect' => _mcpOAuthDisconnect(params),
      'attachments.read' => _attachmentsRead(params),
      'projects.list' => _projectsList(),
      'projects.add' => _projectsAdd(params),
      'projects.remove' => _projectsRemove(params),
      'projects.rename' => _projectsRename(params),
      'sessions.list' => _sessionsList(params),
      'sessions.create' => _sessionsCreate(params),
      'sessions.fork' => _sessionsFork(params),
      'sessions.send' => _sessionsSend(params),
      'sessions.cancel' => _sessionsCancel(params),
      'sessions.rename' => _sessionsRename(params),
      'sessions.archive' => _sessionsArchive(params),
      'sessions.delete' => _sessionsDelete(params),
      'sessions.setMode' => _sessionsSetMode(params),
      'sessions.setModel' => _sessionsSetModel(params),
      'sessions.setThinkingLevel' => _sessionsSetThinkingLevel(params),
      'sessions.history' => _sessionsHistory(params),
      'sessions.respondPermission' => _sessionsRespondPermission(params),
      'fs.list' => _fsList(params),
      'fs.read' => _fsRead(params),
      'git.status' => _gitStatus(params),
      'git.diff' => _gitDiff(params),
      'git.branches' => _gitBranches(params),
      'git.checkout' => _gitCheckout(params),
      'git.createBranch' => _gitCreateBranch(params),
      'git.commit' => _gitCommit(params),
      'git.push' => _gitPush(params),
      'git.createPullRequest' => _gitCreatePullRequest(params),
      'git.mergeToBase' => _gitMergeToBase(params),
      'git.rebaseOntoBase' => _gitRebaseOntoBase(params),
      'git.sessionSummaries' => _gitSessionSummaries(params),
      _ => throw DaemonError(
        _kErrInvalidParams,
        'Unknown method: $method', // Unreachable: the peer answers -32601.
      ),
    };
  }

  Object? _mcpAuthenticate(_Client client, Map<String, Object?> params) {
    final String secret = _requiredString(params, 'secret');
    final String sessionId = _requiredString(params, 'sessionId');
    if (_mcpSecretsBySession[sessionId] != secret ||
        _store.getSession(sessionId) == null) {
      throw DaemonError(kErrUnauthenticated, 'invalid MCP credentials');
    }
    client.authenticated = false;
    client.mcpSessionId = sessionId;
    return <String, Object?>{'ok': true};
  }

  Object? _mcpSearchProjects(_Client client, Map<String, Object?> params) {
    final String query = (params['query'] as String? ?? '').toLowerCase();
    final List<Project> projects = _store
        .listProjects()
        .where((Project project) {
          return query.isEmpty ||
              project.name.toLowerCase().contains(query) ||
              project.path.toLowerCase().contains(query);
        })
        .toList(growable: false);
    return <String, Object?>{
      'projects': projects
          .map((Project project) => project.toJson())
          .toList(growable: false),
    };
  }

  Object? _mcpSearchSessions(_Client client, Map<String, Object?> params) {
    final String sessionId = client.mcpSessionId!;
    final Object? rawLimit = params['limit'];
    final int limit = rawLimit is int ? rawLimit : 20;
    if (limit < 1 || limit > 100) {
      throw DaemonError(_kErrInvalidParams, 'limit must be between 1 and 100');
    }
    final Object? rawProjectId = params['projectId'];
    if (rawProjectId != null && rawProjectId is! String) {
      throw DaemonError(_kErrInvalidParams, 'projectId must be a string');
    }
    final Object? rawQuery = params['query'];
    if (rawQuery != null && rawQuery is! String) {
      throw DaemonError(_kErrInvalidParams, 'query must be a string');
    }
    return <String, Object?>{
      'sessions': _store.searchSessions(
        query: rawQuery as String? ?? '',
        excludeSessionId: sessionId,
        projectId: rawProjectId as String?,
        limit: limit,
      ),
    };
  }

  Future<Object?> _mcpDisplayImage(
    _Client client,
    Map<String, Object?> params,
  ) async {
    final String name = _requiredString(params, 'name');
    final String mimeType = _requiredString(params, 'mimeType');
    final String data = _requiredString(params, 'data');
    if (!isImageMimeType(mimeType)) {
      throw DaemonError(_kErrInvalidParams, 'mimeType must be image/*');
    }
    final List<int> bytes;
    try {
      bytes = base64Decode(data);
    } on FormatException {
      throw DaemonError(_kErrInvalidParams, 'data must be valid base64');
    }
    if (bytes.length > kMaxAttachmentBytes) {
      throw DaemonError(
        _kErrInvalidParams,
        'image exceeds $kMaxAttachmentBytes decoded bytes',
      );
    }
    await _engine.displayImage(
      client.mcpSessionId!,
      name: name,
      mimeType: mimeType,
      data: data,
    );
    return <String, Object?>{'ok': true};
  }

  // -------------------------------------------------------------------------
  // daemon.* / providers.* / auth
  // -------------------------------------------------------------------------

  Future<Object?> _authenticate(
    _Client client,
    Map<String, Object?> params,
  ) async {
    if (!client.authenticated && params['token'] != _authToken) {
      throw DaemonError(kErrUnauthenticated, 'invalid token');
    }
    client.authenticated = true;
    return <String, Object?>{'ok': true, 'daemon': await _daemonInfo()};
  }

  Future<Map<String, Object?>> _daemonInfo() async => DaemonInfo(
    version: kDaemonVersion,
    protocolVersion: _kProtocolVersion,
    authRequired: _authToken != null,
    providers: await _providers.list(),
  ).toJson();

  Future<Object?> _providersList() async => <String, Object?>{
    'providers': (await _providers.list())
        .map((info) => info.toJson())
        .toList(growable: false),
  };
  // -------------------------------------------------------------------------
  // mcp.*
  // -------------------------------------------------------------------------

  Object? _mcpList() => <String, Object?>{
    'servers': _store
        .listMcpServers()
        .map((McpServerProfile profile) => profile.toJson())
        .toList(growable: false),
  };

  Future<Object?> _mcpCreate(Map<String, Object?> params) async {
    final DateTime now = DateTime.now().toUtc();
    final McpServerProfile profile = _mcpProfileFromParams(
      params,
      id: _uuid.v4(),
      projectId: _mcpProjectIdFromParams(params),
      createdAt: now,
      updatedAt: now,
    );
    _validateMcpOAuthParams(profile, params);
    _store.insertMcpServer(profile, _mcpSecretsParam(params));
    _configureMcpOAuth(profile, params, reset: true);
    await _engine.reloadMcpServers(projectId: profile.projectId);
    return <String, Object?>{
      'server': _store.getMcpServer(profile.id)!.toJson(),
    };
  }

  Future<Object?> _mcpUpdate(Map<String, Object?> params) async {
    final String id = _requiredString(params, 'id');
    final McpServerProfile? existing = _store.getMcpServer(id);
    if (existing == null) {
      throw DaemonError(kErrNotFound, 'Unknown MCP server: $id');
    }
    final McpServerProfile profile = _mcpProfileFromParams(
      params,
      id: id,
      projectId: existing.projectId,
      createdAt: existing.createdAt,
      updatedAt: DateTime.now().toUtc(),
    );
    _validateMcpOAuthParams(
      profile,
      params,
      existingClientId: existing.oauthClientId,
    );
    final Object? rawClientId = params['oauthClientId'];
    final String? requestedClientId = switch (rawClientId) {
      final String value when value.trim().isNotEmpty => value.trim(),
      final String _ => null,
      _ => existing.oauthClientId,
    };
    final Object? rawClientSecret = params['oauthClientSecret'];
    final bool clientSecretChanged =
        rawClientSecret is String && rawClientSecret.isNotEmpty;
    final bool resetOAuth =
        existing.authType != profile.authType ||
        existing.url != profile.url ||
        requestedClientId != existing.oauthClientId ||
        clientSecretChanged;
    _store.updateMcpServer(
      profile,
      setSecrets: _mcpSecretsParam(params),
      removeSecretNames: _stringListParam(params, 'removeSecretNames'),
    );
    _configureMcpOAuth(profile, params, reset: resetOAuth);
    await _engine.reloadMcpServers(projectId: existing.projectId);
    return <String, Object?>{'server': _store.getMcpServer(id)!.toJson()};
  }

  Future<Object?> _mcpDelete(Map<String, Object?> params) async {
    final String id = _requiredString(params, 'id');
    final McpServerProfile? existing = _store.getMcpServer(id);
    if (existing == null || !_store.deleteMcpServer(id)) {
      throw DaemonError(kErrNotFound, 'Unknown MCP server: $id');
    }
    await _engine.reloadMcpServers(projectId: existing.projectId);
    return const <String, Object?>{'ok': true};
  }

  Future<Object?> _mcpOAuthBegin(Map<String, Object?> params) async {
    final String id = _requiredString(params, 'id');
    final String rawRedirectUri = _requiredString(params, 'redirectUri');
    final Uri? redirectUri = Uri.tryParse(rawRedirectUri);
    if (redirectUri == null ||
        !redirectUri.hasAuthority ||
        redirectUri.hasFragment ||
        redirectUri.path != '/oauth/callback' ||
        (redirectUri.scheme != 'https' &&
            !(redirectUri.scheme == 'http' &&
                _isLoopbackHost(redirectUri.host)))) {
      throw DaemonError(
        _kErrInvalidParams,
        'redirectUri must be HTTPS or loopback HTTP at /oauth/callback',
      );
    }
    final McpOAuthFlow flow = await _oauth!.begin(id, redirectUri);
    return <String, Object?>{'flow': flow.toJson()};
  }

  Object? _mcpOAuthStatus(Map<String, Object?> params) {
    final String id = _requiredString(params, 'id');
    final String flowId = _requiredString(params, 'flowId');
    final McpServerProfile? profile = _store.getMcpServer(id);
    if (profile == null) {
      throw DaemonError(kErrNotFound, 'Unknown MCP server: $id');
    }
    final Map<String, Object?> json = profile.toJson();
    if (_oauth!.isAuthorizing(id, flowId)) {
      json['oauthStatus'] = McpOAuthStatus.authorizing.wire;
      json.remove('oauthError');
    }
    return <String, Object?>{'server': json};
  }

  Future<Object?> _mcpOAuthDisconnect(Map<String, Object?> params) async {
    final String id = _requiredString(params, 'id');
    await _oauth!.disconnect(id);
    return <String, Object?>{'server': _store.getMcpServer(id)!.toJson()};
  }

  void _validateMcpOAuthParams(
    McpServerProfile profile,
    Map<String, Object?> params, {
    String? existingClientId,
  }) {
    final Object? rawClientId = params['oauthClientId'];
    final Object? rawClientSecret = params['oauthClientSecret'];
    if (rawClientId != null && rawClientId is! String) {
      throw DaemonError(_kErrInvalidParams, 'oauthClientId must be a string');
    }
    if (rawClientSecret != null && rawClientSecret is! String) {
      throw DaemonError(
        _kErrInvalidParams,
        'oauthClientSecret must be a string',
      );
    }
    final String? clientId = switch (rawClientId) {
      final String value when value.trim().isNotEmpty => value.trim(),
      final String _ => null,
      _ => existingClientId,
    };
    if (profile.authType == McpAuthType.oauth &&
        rawClientSecret is String &&
        rawClientSecret.isNotEmpty &&
        clientId == null) {
      throw DaemonError(
        _kErrInvalidParams,
        'oauthClientSecret requires oauthClientId',
      );
    }
  }

  void _configureMcpOAuth(
    McpServerProfile profile,
    Map<String, Object?> params, {
    required bool reset,
  }) {
    final StoredMcpOAuth? existing = _store.getMcpOAuth(profile.id);
    final Object? rawClientId = params['oauthClientId'];
    final Object? rawClientSecret = params['oauthClientSecret'];
    if (rawClientId != null && rawClientId is! String) {
      throw DaemonError(_kErrInvalidParams, 'oauthClientId must be a string');
    }
    if (rawClientSecret != null && rawClientSecret is! String) {
      throw DaemonError(
        _kErrInvalidParams,
        'oauthClientSecret must be a string',
      );
    }
    final String? clientId = switch (rawClientId) {
      final String value when value.trim().isNotEmpty => value.trim(),
      _ => reset ? null : existing?.clientId,
    };
    if (profile.authType == McpAuthType.oauth &&
        rawClientSecret is String &&
        rawClientSecret.isNotEmpty &&
        clientId == null) {
      throw DaemonError(
        _kErrInvalidParams,
        'oauthClientSecret requires oauthClientId',
      );
    }

    if (reset) _store.resetMcpOAuth(profile.id);
    if (profile.authType != McpAuthType.oauth) return;
    if (clientId == null) {
      _store.setMcpOAuthStatus(profile.id, McpOAuthStatus.notConnected);
      return;
    }
    _store.setMcpOAuthClient(
      profile.id,
      clientId: clientId,
      clientSecret: rawClientSecret is String && rawClientSecret.isNotEmpty
          ? rawClientSecret
          : reset
          ? null
          : existing?.clientSecret,
      tokenEndpointAuthMethod: reset ? null : existing?.tokenEndpointAuthMethod,
      redirectUri: reset ? null : existing?.redirectUri,
    );
    if (reset) {
      _store.setMcpOAuthStatus(profile.id, McpOAuthStatus.notConnected);
    }
  }

  McpServerProfile _mcpProfileFromParams(
    Map<String, Object?> params, {
    required String id,
    required String? projectId,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) {
    final String name = _requiredString(params, 'name').trim();
    if (name.isEmpty) {
      throw DaemonError(_kErrInvalidParams, 'name must not be empty');
    }
    if (name.toLowerCase() == kMcpServerName) {
      throw DaemonError(
        _kErrInvalidParams,
        '"$kMcpServerName" is reserved for SpeedDial tools',
      );
    }
    final McpTransport transport;
    try {
      transport = McpTransport.parse(_requiredString(params, 'transport'));
    } on FormatException {
      throw DaemonError(
        _kErrInvalidParams,
        'transport must be "stdio" or "http"',
      );
    }
    final List<String> args = _stringListParam(params, 'args');
    String? command;
    String? url;
    switch (transport) {
      case McpTransport.stdio:
        command = _requiredString(params, 'command').trim();
        if (command.isEmpty) {
          throw DaemonError(_kErrInvalidParams, 'command must not be empty');
        }
      case McpTransport.http:
        url = _requiredString(params, 'url').trim();
        final Uri? parsed = Uri.tryParse(url);
        if (parsed == null ||
            !parsed.hasAuthority ||
            (parsed.scheme != 'http' && parsed.scheme != 'https')) {
          throw DaemonError(
            _kErrInvalidParams,
            'url must be an absolute http or https URL',
          );
        }
    }
    final McpAuthType authType;
    try {
      authType = McpAuthType.parse(
        (params['authType'] as String?) ?? McpAuthType.none.wire,
      );
    } on Object {
      throw DaemonError(
        _kErrInvalidParams,
        'authType must be "none" or "oauth"',
      );
    }
    if (transport == McpTransport.stdio && authType != McpAuthType.none) {
      throw DaemonError(
        _kErrInvalidParams,
        'OAuth is available only for HTTP MCP servers',
      );
    }
    return McpServerProfile(
      projectId: projectId,
      id: id,
      name: name,
      transport: transport,
      enabled: params['enabled'] != false,
      command: command,
      args: transport == McpTransport.stdio ? args : const <String>[],
      url: url,
      authType: authType,
      secretNames: const <String>[],
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  String? _mcpProjectIdFromParams(Map<String, Object?> params) {
    final Object? raw = params['projectId'];
    if (raw == null) return null;
    if (raw is! String || raw.isEmpty) {
      throw DaemonError(_kErrInvalidParams, 'projectId must be a string');
    }
    if (_store.getProject(raw) == null) {
      throw DaemonError(kErrNotFound, 'Unknown project: $raw');
    }
    return raw;
  }

  Map<String, String> _mcpSecretsParam(Map<String, Object?> params) {
    final Object? raw = params['secrets'];
    if (raw == null) return const <String, String>{};
    if (raw is! Map) {
      throw DaemonError(_kErrInvalidParams, 'secrets must be an object');
    }
    final Map<String, String> secrets = <String, String>{};
    for (final MapEntry<Object?, Object?> entry in raw.entries) {
      if (entry.key is! String ||
          (entry.key! as String).trim().isEmpty ||
          entry.value is! String) {
        throw DaemonError(
          _kErrInvalidParams,
          'secret names and values must be strings',
        );
      }
      secrets[(entry.key! as String).trim()] = entry.value! as String;
    }
    return secrets;
  }

  List<String> _stringListParam(Map<String, Object?> params, String field) {
    final Object? raw = params[field];
    if (raw == null) return const <String>[];
    if (raw is! List<Object?> || raw.any((Object? value) => value is! String)) {
      throw DaemonError(_kErrInvalidParams, '$field must be a string array');
    }
    return raw.cast<String>().toList(growable: false);
  }

  // -------------------------------------------------------------------------
  // projects.*
  // -------------------------------------------------------------------------

  Object? _projectsList() => <String, Object?>{
    'projects': _store
        .listProjects()
        .map((project) => project.toJson())
        .toList(growable: false),
  };

  Future<Object?> _projectsAdd(Map<String, Object?> params) async {
    final path = expandTilde(_requiredString(params, 'path'));
    if (!Directory(path).existsSync()) {
      throw DaemonError(_kErrInvalidParams, 'Not a directory: $path');
    }
    final rawName = params['name'];
    final name = rawName is String && rawName.isNotEmpty
        ? rawName
        : p.basename(p.normalize(path));
    final now = DateTime.now().toUtc();
    final project = Project(
      id: _uuid.v4(),
      name: name,
      path: p.normalize(path),
      addedAt: now,
      lastActiveAt: now,
    );
    _store.insertProject(project); // Duplicate path → kErrConflict.
    _broadcast('projects.changed', <String, Object?>{});
    return <String, Object?>{'project': project.toJson()};
  }

  Future<Object?> _projectsRemove(Map<String, Object?> params) async {
    final id = _requiredString(params, 'id');
    if (_store.getProject(id) == null) {
      throw DaemonError(kErrNotFound, 'Unknown project: $id');
    }
    _store.removeProject(id);
    _broadcast('projects.changed', <String, Object?>{});
    return <String, Object?>{};
  }

  Future<Object?> _projectsRename(Map<String, Object?> params) async {
    final id = _requiredString(params, 'id');
    final name = _requiredString(params, 'name');
    final project = _store.renameProject(id, name);
    _broadcast('projects.changed', <String, Object?>{});
    return <String, Object?>{'project': project.toJson()};
  }

  // -------------------------------------------------------------------------
  // sessions.*
  // -------------------------------------------------------------------------

  Object? _sessionsList(Map<String, Object?> params) {
    final projectId = params['projectId'];
    final includeArchived = params['includeArchived'];
    final sessions = _store.listSessions(
      projectId: projectId is String && projectId.isNotEmpty ? projectId : null,
      includeArchived: includeArchived is bool ? includeArchived : false,
    );
    return <String, Object?>{
      'sessions': sessions
          .map((session) => session.toJson())
          .toList(growable: false),
    };
  }

  Future<Object?> _sessionsCreate(Map<String, Object?> params) async {
    final projectId = _requiredString(params, 'projectId');
    final providerId = _requiredString(params, 'providerId');
    final rawModel = params['model'];
    final rawMode = params['mode'];
    final rawTitle = params['title'];
    final rawCwd = params['cwd'];
    final rawBaseBranch = params['baseBranch'];
    final rawYolo = params['yolo'];
    final session = await _engine.createSession(
      projectId: projectId,
      providerId: providerId,
      model: rawModel is String && rawModel.isNotEmpty ? rawModel : null,
      mode: rawMode == null ? null : _parseMode(rawMode),
      title: rawTitle is String && rawTitle.isNotEmpty ? rawTitle : null,
      cwd: rawCwd is String && rawCwd.isNotEmpty ? rawCwd : null,
      baseBranch: rawBaseBranch is String && rawBaseBranch.isNotEmpty
          ? rawBaseBranch
          : null,
      yolo: rawYolo is bool && rawYolo,
    );
    // The engine already published `session.updated` (suppressed by the
    // created-set while `sessions.create` is in flight); PROTOCOL.md wants an
    // explicit `session.created` for new sessions. Only after broadcasting it
    // may the sessionChanges relay let updates through. Broadcasts are
    // synchronous and per-connection FIFO, so on every socket
    // `session.created` is queued before any later `session.updated`.
    _broadcast('session.created', <String, Object?>{
      'session': session.toJson(),
    });
    _createdBroadcast.add(session.id);
    return <String, Object?>{'session': session.toJson()};
  }

  Future<Object?> _sessionsFork(Map<String, Object?> params) async {
    final sessionId = _requiredString(params, 'sessionId');
    final rawSeq = params['seq'];
    if (rawSeq is! int || rawSeq < 1) {
      throw DaemonError(
        _kErrInvalidParams,
        'Missing or invalid parameter: seq',
      );
    }
    final session = await _engine.forkSession(
      sourceSessionId: sessionId,
      throughSeq: rawSeq,
    );
    _broadcast('session.created', <String, Object?>{
      'session': session.toJson(),
    });
    _createdBroadcast.add(session.id);
    return <String, Object?>{'session': session.toJson()};
  }

  Future<Object?> _sessionsSend(Map<String, Object?> params) async {
    final sessionId = _requiredString(params, 'sessionId');
    final rawAttachments = params['attachments'];
    final List<OutgoingAttachment> attachments;
    if (rawAttachments != null) {
      if (rawAttachments is! List) {
        throw DaemonError(
          _kErrInvalidParams,
          'Missing or invalid parameter: attachments',
        );
      }
      if (rawAttachments.length > kMaxAttachmentsPerMessage) {
        throw DaemonError(
          _kErrInvalidParams,
          'Too many attachments: ${rawAttachments.length} '
          '(max $kMaxAttachmentsPerMessage)',
        );
      }
      attachments = <OutgoingAttachment>[];
      var totalBytes = 0;
      for (final entry in rawAttachments) {
        if (entry is! Map) {
          throw DaemonError(
            _kErrInvalidParams,
            'Each attachment must be an object with name, mimeType, and data',
          );
        }
        final map = Map<String, Object?>.from(entry);
        final name = map['name'];
        final mimeType = map['mimeType'];
        final rawData = map['data'];
        if (name is! String || mimeType is! String || rawData is! String) {
          throw DaemonError(
            _kErrInvalidParams,
            'Each attachment must be an object with string name, mimeType, '
            'and data',
          );
        }
        final List<int> decoded;
        try {
          decoded = base64Decode(rawData);
        } on FormatException {
          throw DaemonError(
            _kErrInvalidParams,
            'Attachment "$name" carries malformed base64 data',
          );
        }
        if (decoded.length > kMaxAttachmentBytes) {
          throw DaemonError(
            _kErrInvalidParams,
            'Attachment "$name" is $decoded.length bytes '
            '(max $kMaxAttachmentBytes per attachment)',
          );
        }
        totalBytes += decoded.length;
        if (totalBytes > kMaxAttachmentTotalBytes) {
          throw DaemonError(
            _kErrInvalidParams,
            'Attachments total $totalBytes bytes '
            '(max $kMaxAttachmentTotalBytes per message)',
          );
        }
        attachments.add(
          OutgoingAttachment(name: name, mimeType: mimeType, data: rawData),
        );
      }
    } else {
      attachments = const <OutgoingAttachment>[];
    }
    // `text` may be empty only when attachments are present; otherwise it
    // keeps the non-empty required semantics.
    final rawText = params['text'];
    final String text;
    if (rawText is String) {
      if (rawText.isNotEmpty || attachments.isNotEmpty) {
        text = rawText;
      } else {
        throw DaemonError(
          _kErrInvalidParams,
          'Missing or invalid parameter: text',
        );
      }
    } else if (rawText == null && attachments.isNotEmpty) {
      text = '';
    } else {
      throw DaemonError(
        _kErrInvalidParams,
        'Missing or invalid parameter: text',
      );
    }
    await _engine.sendMessage(sessionId, text, attachments: attachments);
    return <String, Object?>{};
  }

  Object? _attachmentsRead(Map<String, Object?> params) {
    final sessionId = _requiredString(params, 'sessionId');
    final attachmentId = _requiredString(params, 'attachmentId');
    if (_store.getSession(sessionId) == null) {
      throw DaemonError(kErrNotFound, 'Unknown session: $sessionId');
    }
    final attachment = _store.getAttachment(sessionId, attachmentId);
    if (attachment == null) {
      throw DaemonError(kErrNotFound, 'Unknown attachment: $attachmentId');
    }
    return <String, Object?>{'attachment': attachment.toJson()};
  }

  Future<Object?> _sessionsCancel(Map<String, Object?> params) async {
    final sessionId = _requiredString(params, 'sessionId');
    await _engine.cancel(sessionId);
    return <String, Object?>{};
  }

  Future<Object?> _sessionsRename(Map<String, Object?> params) async {
    final sessionId = _requiredString(params, 'sessionId');
    final title = _requiredString(params, 'title');
    final session = await _engine.rename(sessionId, title);
    return <String, Object?>{'session': session.toJson()};
  }

  Future<Object?> _sessionsArchive(Map<String, Object?> params) async {
    final sessionId = _requiredString(params, 'sessionId');
    final archived = params['archived'];
    if (archived is! bool) {
      throw DaemonError(
        _kErrInvalidParams,
        'Missing or invalid parameter: archived',
      );
    }
    final session = await _engine.archive(sessionId, archived);
    return <String, Object?>{'session': session.toJson()};
  }

  Future<Object?> _sessionsDelete(Map<String, Object?> params) async {
    final sessionId = _requiredString(params, 'sessionId');
    await _engine.delete(sessionId);
    return <String, Object?>{};
  }

  Future<Object?> _sessionsSetMode(Map<String, Object?> params) async {
    final sessionId = _requiredString(params, 'sessionId');
    final mode = _parseMode(params['mode']);
    final session = await _engine.setMode(sessionId, mode);
    return <String, Object?>{'session': session.toJson()};
  }

  Future<Object?> _sessionsSetModel(Map<String, Object?> params) async {
    final sessionId = _requiredString(params, 'sessionId');
    final model = _requiredString(params, 'model');
    final session = await _engine.setModel(sessionId, model);
    return <String, Object?>{'session': session.toJson()};
  }

  Future<Object?> _sessionsSetThinkingLevel(Map<String, Object?> params) async {
    final sessionId = _requiredString(params, 'sessionId');
    final level = _requiredString(params, 'level');
    final session = await _engine.setThinkingLevel(sessionId, level);
    return <String, Object?>{'session': session.toJson()};
  }

  Object? _sessionsHistory(Map<String, Object?> params) {
    final sessionId = _requiredString(params, 'sessionId');
    if (_store.getSession(sessionId) == null) {
      throw DaemonError(kErrNotFound, 'Unknown session: $sessionId');
    }
    final rawLimit = params['limit'];
    final limit = rawLimit is int && rawLimit > 0
        ? (rawLimit > 1000 ? 1000 : rawLimit)
        : 200;
    final rawBefore = params['beforeSeq'];
    final beforeSeq = rawBefore is int ? rawBefore : null;
    final page = _store.listEvents(
      sessionId,
      limit: limit,
      beforeSeq: beforeSeq,
    );
    return <String, Object?>{
      'events': page.events
          .map((event) => event.toJson())
          .toList(growable: false),
      'hasMore': page.hasMore,
    };
  }

  Future<Object?> _sessionsRespondPermission(
    Map<String, Object?> params,
  ) async {
    final sessionId = _requiredString(params, 'sessionId');
    final requestId = _requiredString(params, 'requestId');
    final optionId = _requiredString(params, 'optionId');
    await _engine.respondPermission(sessionId, requestId, optionId);
    return <String, Object?>{};
  }

  // -------------------------------------------------------------------------
  // fs.*
  // -------------------------------------------------------------------------

  Object? _fsList(Map<String, Object?> params) {
    final project = _requireProject(_requiredString(params, 'projectId'));
    final rawPath = params['path'];
    final entries = _fs.list(
      rootPath: project.path,
      path: rawPath is String && rawPath.isNotEmpty ? rawPath : '.',
    );
    return <String, Object?>{
      'entries': entries.map((entry) => entry.toJson()).toList(growable: false),
    };
  }

  Object? _fsRead(Map<String, Object?> params) {
    final project = _requireProject(_requiredString(params, 'projectId'));
    final path = _requiredString(params, 'path');
    final rawMaxBytes = params['maxBytes'];
    final result = _fs.read(
      rootPath: project.path,
      path: path,
      maxBytes: rawMaxBytes is int && rawMaxBytes > 0 ? rawMaxBytes : null,
    );
    return result.toJson();
  }

  // -------------------------------------------------------------------------
  // git.*
  // -------------------------------------------------------------------------

  Project _requireProject(String id) {
    final project = _store.getProject(id);
    if (project == null) {
      throw DaemonError(kErrNotFound, 'Unknown project: $id');
    }
    return project;
  }

  /// The directory git.* runs in: the session's working directory when
  /// `sessionId` is given (worktree sessions live outside the project path),
  /// otherwise the project path. The session must belong to the project.
  String _gitRepoPath(Map<String, Object?> params) {
    final project = _requireProject(_requiredString(params, 'projectId'));
    return _gitSession(params, project)?.cwd ?? project.path;
  }

  /// The session referenced by `sessionId` in [params], validated against
  /// [project]; null when no `sessionId` was given.
  Session? _gitSession(Map<String, Object?> params, Project project) {
    final rawSessionId = params['sessionId'];
    if (rawSessionId == null) return null;
    if (rawSessionId is! String || rawSessionId.isEmpty) {
      throw DaemonError(
        _kErrInvalidParams,
        'sessionId must be a non-empty string',
      );
    }
    final session = _store.getSession(rawSessionId);
    if (session == null) {
      throw DaemonError(kErrNotFound, 'Unknown session: $rawSessionId');
    }
    if (session.projectId != project.id) {
      throw DaemonError(
        _kErrInvalidParams,
        'session $rawSessionId does not belong to project ${project.id}',
      );
    }
    return session;
  }

  Future<Object?> _gitStatus(Map<String, Object?> params) async {
    final status = await _git.status(_gitRepoPath(params));
    return <String, Object?>{'status': status.toJson()};
  }

  Future<Object?> _gitDiff(Map<String, Object?> params) async {
    final rawPath = params['path'];
    final rawStaged = params['staged'];
    final diffs = await _git.diff(
      _gitRepoPath(params),
      path: rawPath is String && rawPath.isNotEmpty ? rawPath : null,
      staged: rawStaged is bool ? rawStaged : false,
    );
    return <String, Object?>{
      'diffs': diffs.map((diff) => diff.toJson()).toList(growable: false),
    };
  }

  Future<Object?> _gitBranches(Map<String, Object?> params) async {
    final branches = await _git.branches(_gitRepoPath(params));
    return <String, Object?>{
      'branches': branches
          .map((branch) => branch.toJson())
          .toList(growable: false),
    };
  }

  Future<Object?> _gitCheckout(Map<String, Object?> params) async {
    await _git.checkout(
      _gitRepoPath(params),
      _requiredString(params, 'branch'),
    );
    return <String, Object?>{};
  }

  Future<Object?> _gitCreateBranch(Map<String, Object?> params) async {
    final rawCheckout = params['checkout'];
    await _git.createBranch(
      _gitRepoPath(params),
      _requiredString(params, 'name'),
      checkout: rawCheckout is bool ? rawCheckout : true,
    );
    return <String, Object?>{};
  }

  Future<Object?> _gitCommit(Map<String, Object?> params) async {
    final rawStageAll = params['stageAll'];
    final commitHash = await _git.commit(
      _gitRepoPath(params),
      _requiredString(params, 'message'),
      stageAll: rawStageAll is bool ? rawStageAll : false,
    );
    return <String, Object?>{'commitHash': commitHash};
  }

  Future<Object?> _gitPush(Map<String, Object?> params) async {
    final rawSetUpstream = params['setUpstream'];
    await _git.push(
      _gitRepoPath(params),
      setUpstream: rawSetUpstream is bool ? rawSetUpstream : false,
    );
    return <String, Object?>{};
  }

  Future<Object?> _gitCreatePullRequest(Map<String, Object?> params) async {
    final rawTitle = params['title'];
    final rawBody = params['body'];
    final rawBase = params['base'];
    final rawDraft = params['draft'];
    final project = _requireProject(_requiredString(params, 'projectId'));
    final session = _gitSession(params, project);
    // A worktree session's PR targets the branch it was created from unless
    // the caller overrides it; only with neither does gh pick the default.
    final explicitBase = rawBase is String && rawBase.isNotEmpty
        ? rawBase
        : null;
    final url = await _pr.createPullRequest(
      session?.cwd ?? project.path,
      title: rawTitle is String && rawTitle.isNotEmpty ? rawTitle : null,
      body: rawBody is String ? rawBody : null,
      base: explicitBase ?? session?.baseBranch,
      draft: rawDraft is bool ? rawDraft : false,
    );
    return <String, Object?>{'url': url};
  }

  Future<Object?> _gitMergeToBase(Map<String, Object?> params) async {
    final project = _requireProject(_requiredString(params, 'projectId'));
    final session = _gitSession(params, project);
    if (session == null) {
      throw DaemonError(
        _kErrInvalidParams,
        'git.mergeToBase requires a sessionId',
      );
    }
    final baseBranch = session.baseBranch;
    if (baseBranch == null) {
      throw DaemonError(
        _kErrInvalidParams,
        'session ${session.id} has no base branch '
        '(not created with baseBranch)',
      );
    }
    final merge = await _git.mergeIntoBase(
      projectPath: project.path,
      worktreePath: session.cwd,
      baseBranch: baseBranch,
    );
    return <String, Object?>{'merge': merge.toJson()};
  }

  Future<Object?> _gitRebaseOntoBase(Map<String, Object?> params) async {
    final project = _requireProject(_requiredString(params, 'projectId'));
    final session = _gitSession(params, project);
    if (session == null) {
      throw DaemonError(
        _kErrInvalidParams,
        'git.rebaseOntoBase requires a sessionId',
      );
    }
    final baseBranch = session.baseBranch;
    if (baseBranch == null) {
      throw DaemonError(
        _kErrInvalidParams,
        'session ${session.id} has no base branch '
        '(not created with baseBranch)',
      );
    }
    final rebase = await _git.rebaseOntoBase(
      projectPath: project.path,
      worktreePath: session.cwd,
      baseBranch: baseBranch,
    );
    return <String, Object?>{'rebase': rebase.toJson()};
  }

  /// One [SessionGitSummary] per non-archived session of the project, for
  /// the left-rail badges. All sessions are probed concurrently; per-session
  /// failures degrade to null fields inside [GitService.sessionSummary].
  Future<Object?> _gitSessionSummaries(Map<String, Object?> params) async {
    final project = _requireProject(_requiredString(params, 'projectId'));
    final List<Session> sessions = _store.listSessions(projectId: project.id);
    final List<SessionGitSummary> summaries = await _git.sessionSummaries(
      sessions,
    );
    return <String, Object?>{
      'summaries': summaries
          .map((summary) => summary.toJson())
          .toList(growable: false),
    };
  }

  // -------------------------------------------------------------------------
  // Param helpers
  // -------------------------------------------------------------------------

  String _requiredString(Map<String, Object?> params, String key) {
    final value = params[key];
    if (value is String && value.isNotEmpty) return value;
    throw DaemonError(_kErrInvalidParams, 'Missing or invalid parameter: $key');
  }

  SessionMode _parseMode(Object? raw) {
    if (raw is! String) {
      throw DaemonError(
        _kErrInvalidParams,
        'Missing or invalid parameter: mode',
      );
    }
    try {
      return SessionMode.parse(raw);
    } on FormatException {
      throw DaemonError(_kErrInvalidParams, 'Invalid mode: $raw');
    }
  }
}
