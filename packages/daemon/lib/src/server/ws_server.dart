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
import '../providers/provider_registry.dart';
import '../store/daemon_store.dart';
import 'fs_service.dart';

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
  'projects.list',
  'projects.add',
  'projects.remove',
  'projects.rename',
  'sessions.list',
  'sessions.create',
  'sessions.send',
  'sessions.cancel',
  'sessions.rename',
  'sessions.archive',
  'sessions.delete',
  'sessions.setMode',
  'sessions.setModel',
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
];

/// One connected client: its peer, socket, and authentication state.
class _Client {
  _Client({required this.peer, required this.socket, required this.authenticated});

  final RpcPeer peer;
  final WebSocket socket;
  bool authenticated;
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
  })  : _engine = engine, // ignore: prefer_initializing_formals — public API name
        _store = store, // ignore: prefer_initializing_formals — public API name
        _providers = providers, // ignore: prefer_initializing_formals — public API name
        _authToken = authToken, // ignore: prefer_initializing_formals — public API name
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
  }) async {
    final server = SpeedDialServer(
      engine: engine,
      store: store,
      providers: providers,
      authToken: authToken,
      git: git,
      pr: pr,
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

  HttpServer? _httpServer;
  final List<_Client> _clients = <_Client>[];
  late final StreamSubscription<({String sessionId, int seq, SessionEvent event})>
      _eventsSub;
  late final StreamSubscription<Session> _changesSub;
  late final StreamSubscription<String> _removalsSub;
  bool _closed = false;

  /// The bound port (meaningful after [bind]).
  int get port => _httpServer?.port ?? 0;

  /// Shuts the server down: closes every client connection, cancels the
  /// engine subscriptions, and releases the [HttpServer]. Idempotent.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _eventsSub.cancel();
    await _changesSub.cancel();
    await _removalsSub.cancel();
    for (final client in _clients.toList()) {
      client.peer.close();
      unawaited(client.socket
          .close(WebSocketStatus.normalClosure, 'daemon closing')
          .catchError((Object _) {}));
    }
    _clients.clear();
    await _httpServer?.close(force: true);
  }

  // -------------------------------------------------------------------------
  // Startup wiring
  // -------------------------------------------------------------------------

  void _init() {
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
      _broadcast('session.updated', <String, Object?>{'session': session.toJson()});
    });
    _removalsSub = _engine.sessionRemovals.listen((sessionId) {
      _broadcast('session.removed', <String, Object?>{'sessionId': sessionId});
    });
  }

  Future<void> _bind(String host, int port) async {
    _httpServer = await HttpServer.bind(host, port);
    _httpServer!.listen(_handleRequest);
  }

  // -------------------------------------------------------------------------
  // Connection handling
  // -------------------------------------------------------------------------

  Future<void> _handleRequest(HttpRequest request) async {
    if (request.uri.path == '/ws' &&
        WebSocketTransformer.isUpgradeRequest(request)) {
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

  /// Yields to the event loop so notification frames already queued on every
  /// authenticated client's socket are flushed and delivered before a method
  /// response is written.
  ///
  /// A broadcast made inside a request handler and a response to that request
  /// are otherwise written in the same synchronous burst; the caller then
  /// processes its response (completing its call) before a peer's socket has
  /// delivered its copy of the notification, so the peer observes the
  /// broadcast late. dart:io's [WebSocket] exposes no `flush`, so this drains
  /// pending socket writes by ceding a full event-loop turn, guaranteeing the
  /// queued notifications reach every client before the response is sent.
  Future<void> _flushBroadcasts() => Future<void>.delayed(Duration.zero);

  // -------------------------------------------------------------------------
  // Method dispatch
  // -------------------------------------------------------------------------

  FutureOr<Object?> _dispatch(
    _Client client,
    String method,
    Map<String, Object?> params,
  ) {
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
      'projects.list' => _projectsList(),
      'projects.add' => _projectsAdd(params),
      'projects.remove' => _projectsRemove(params),
      'projects.rename' => _projectsRename(params),
      'sessions.list' => _sessionsList(params),
      'sessions.create' => _sessionsCreate(params),
      'sessions.send' => _sessionsSend(params),
      'sessions.cancel' => _sessionsCancel(params),
      'sessions.rename' => _sessionsRename(params),
      'sessions.archive' => _sessionsArchive(params),
      'sessions.delete' => _sessionsDelete(params),
      'sessions.setMode' => _sessionsSetMode(params),
      'sessions.setModel' => _sessionsSetModel(params),
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
      _ => throw DaemonError(
          _kErrInvalidParams,
          'Unknown method: $method', // Unreachable: the peer answers -32601.
        ),
    };
  }

  // -------------------------------------------------------------------------
  // daemon.* / providers.* / auth
  // -------------------------------------------------------------------------

  Object? _authenticate(_Client client, Map<String, Object?> params) {
    if (!client.authenticated && params['token'] != _authToken) {
      throw DaemonError(kErrUnauthenticated, 'invalid token');
    }
    client.authenticated = true;
    return <String, Object?>{'ok': true, 'daemon': _daemonInfo()};
  }

  Map<String, Object?> _daemonInfo() => DaemonInfo(
        version: kDaemonVersion,
        protocolVersion: _kProtocolVersion,
        authRequired: _authToken != null,
        providers: _providers.list(),
      ).toJson();

  Object? _providersList() => <String, Object?>{
        'providers':
            _providers.list().map((info) => info.toJson()).toList(growable: false),
      };

  // -------------------------------------------------------------------------
  // projects.*
  // -------------------------------------------------------------------------

  Object? _projectsList() => <String, Object?>{
        'projects':
            _store.listProjects().map((project) => project.toJson()).toList(growable: false),
      };

  Future<Object?> _projectsAdd(Map<String, Object?> params) async {
    final path = _requiredString(params, 'path');
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
    await _flushBroadcasts();
    return <String, Object?>{'project': project.toJson()};
  }

  Future<Object?> _projectsRemove(Map<String, Object?> params) async {
    final id = _requiredString(params, 'id');
    if (_store.getProject(id) == null) {
      throw DaemonError(kErrNotFound, 'Unknown project: $id');
    }
    _store.removeProject(id);
    _broadcast('projects.changed', <String, Object?>{});
    await _flushBroadcasts();
    return <String, Object?>{};
  }

  Future<Object?> _projectsRename(Map<String, Object?> params) async {
    final id = _requiredString(params, 'id');
    final name = _requiredString(params, 'name');
    final project = _store.renameProject(id, name);
    _broadcast('projects.changed', <String, Object?>{});
    await _flushBroadcasts();
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
      'sessions':
          sessions.map((session) => session.toJson()).toList(growable: false),
    };
  }

  Future<Object?> _sessionsCreate(Map<String, Object?> params) async {
    final projectId = _requiredString(params, 'projectId');
    final providerId = _requiredString(params, 'providerId');
    final rawModel = params['model'];
    final rawMode = params['mode'];
    final rawTitle = params['title'];
    final rawCwd = params['cwd'];
    final session = await _engine.createSession(
      projectId: projectId,
      providerId: providerId,
      model: rawModel is String && rawModel.isNotEmpty ? rawModel : null,
      mode: rawMode == null ? null : _parseMode(rawMode),
      title: rawTitle is String && rawTitle.isNotEmpty ? rawTitle : null,
      cwd: rawCwd is String && rawCwd.isNotEmpty ? rawCwd : null,
    );
    // The engine already published `session.updated`; PROTOCOL.md wants an
    // explicit `session.created` for new sessions.
    _broadcast('session.created', <String, Object?>{'session': session.toJson()});
    // Flush the broadcast to every client before responding: the response is
    // written on the requesting socket, so without this the caller would
    // complete its call before a peer has observed `session.created`.
    await _flushBroadcasts();
    return <String, Object?>{'session': session.toJson()};
  }

  Future<Object?> _sessionsSend(Map<String, Object?> params) async {
    final sessionId = _requiredString(params, 'sessionId');
    final text = _requiredString(params, 'text');
    await _engine.sendMessage(sessionId, text);
    return <String, Object?>{};
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
      throw DaemonError(_kErrInvalidParams, 'Missing or invalid parameter: archived');
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
    final page = _store.listEvents(sessionId, limit: limit, beforeSeq: beforeSeq);
    return <String, Object?>{
      'events': page.events.map((event) => event.toJson()).toList(growable: false),
      'hasMore': page.hasMore,
    };
  }

  Future<Object?> _sessionsRespondPermission(Map<String, Object?> params) async {
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

  Future<Object?> _gitStatus(Map<String, Object?> params) async {
    final project = _requireProject(_requiredString(params, 'projectId'));
    final status = await _git.status(project.path);
    return <String, Object?>{'status': status.toJson()};
  }

  Future<Object?> _gitDiff(Map<String, Object?> params) async {
    final project = _requireProject(_requiredString(params, 'projectId'));
    final rawPath = params['path'];
    final rawStaged = params['staged'];
    final diffs = await _git.diff(
      project.path,
      path: rawPath is String && rawPath.isNotEmpty ? rawPath : null,
      staged: rawStaged is bool ? rawStaged : false,
    );
    return <String, Object?>{
      'diffs': diffs.map((diff) => diff.toJson()).toList(growable: false),
    };
  }

  Future<Object?> _gitBranches(Map<String, Object?> params) async {
    final project = _requireProject(_requiredString(params, 'projectId'));
    final branches = await _git.branches(project.path);
    return <String, Object?>{
      'branches': branches.map((branch) => branch.toJson()).toList(growable: false),
    };
  }

  Future<Object?> _gitCheckout(Map<String, Object?> params) async {
    final project = _requireProject(_requiredString(params, 'projectId'));
    await _git.checkout(project.path, _requiredString(params, 'branch'));
    return <String, Object?>{};
  }

  Future<Object?> _gitCreateBranch(Map<String, Object?> params) async {
    final project = _requireProject(_requiredString(params, 'projectId'));
    final rawCheckout = params['checkout'];
    await _git.createBranch(
      project.path,
      _requiredString(params, 'name'),
      checkout: rawCheckout is bool ? rawCheckout : true,
    );
    return <String, Object?>{};
  }

  Future<Object?> _gitCommit(Map<String, Object?> params) async {
    final project = _requireProject(_requiredString(params, 'projectId'));
    final rawStageAll = params['stageAll'];
    final commitHash = await _git.commit(
      project.path,
      _requiredString(params, 'message'),
      stageAll: rawStageAll is bool ? rawStageAll : false,
    );
    return <String, Object?>{'commitHash': commitHash};
  }

  Future<Object?> _gitPush(Map<String, Object?> params) async {
    final project = _requireProject(_requiredString(params, 'projectId'));
    final rawSetUpstream = params['setUpstream'];
    await _git.push(
      project.path,
      setUpstream: rawSetUpstream is bool ? rawSetUpstream : false,
    );
    return <String, Object?>{};
  }

  Future<Object?> _gitCreatePullRequest(Map<String, Object?> params) async {
    final project = _requireProject(_requiredString(params, 'projectId'));
    final rawTitle = params['title'];
    final rawBody = params['body'];
    final rawBase = params['base'];
    final rawDraft = params['draft'];
    final url = await _pr.createPullRequest(
      project.path,
      title: rawTitle is String && rawTitle.isNotEmpty ? rawTitle : null,
      body: rawBody is String ? rawBody : null,
      base: rawBase is String ? rawBase : null,
      draft: rawDraft is bool ? rawDraft : false,
    );
    return <String, Object?>{'url': url};
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
      throw DaemonError(_kErrInvalidParams, 'Missing or invalid parameter: mode');
    }
    try {
      return SessionMode.parse(raw);
    } on FormatException {
      throw DaemonError(_kErrInvalidParams, 'Invalid mode: $raw');
    }
  }
}
