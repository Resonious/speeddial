/// Dart-side client for the SpeedDial wire protocol (PROTOCOL.md).
///
/// Talks to a running daemon over WebSocket text frames; JSON-RPC 2.0 framing
/// is handled by [RpcPeer] from `package:speeddial_protocol`. Every PROTOCOL.md
/// method is mirrored as a typed `Future` method, and daemon→client
/// notifications are exposed via [notifications] ([sessionEvents] gives the
/// parsed `session.event` union for streaming).
library;

import 'dart:convert';
import 'dart:io';

import 'package:speeddial_protocol/speeddial_protocol.dart';

/// The standard daemon endpoint path, as PROTOCOL.md mandates.
const String kWsPath = '/ws';

/// A live authenticated connection to a SpeedDial daemon.
class DaemonClient {
  DaemonClient._(this._socket, this._peer) {
    // Surface remote closure as error-completing calls instead of hanging
    // forever when the daemon vanishes mid-request.
    _socket.done.then((_) => _peer.close(), onError: (_) => _peer.close());
  }

  final WebSocket _socket;
  final RpcPeer _peer;

  /// Daemon identity from the `auth.authenticate` result (or the
  /// `daemon.info` probe when no token is used), set by [connect].
  DaemonInfo? daemonInfo;

  /// Connects to the daemon at [url] (`ws://host:port/ws`).
  ///
  /// When [token] is given, the first request is `auth.authenticate` (the
  /// daemon requires a token whenever it is bound non-loopback or was started
  /// with `--token`). Without a token, `daemon.info` is probed to confirm the
  /// daemon is reachable and requires no auth; a daemon that does require a
  /// token makes this call fail with [DaemonError]
  /// ([kErrUnauthenticated]) before any other method can be used.
  ///
  /// [timeout] bounds the WebSocket handshake and the auth/info round trip.
  static Future<DaemonClient> connect(
    String url, {
    String? token,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final socket = await WebSocket.connect(url).timeout(timeout);
    final peer = RpcPeer(
      incoming: socket.map(_decodeFrame),
      send: (Object? message) => socket.add(jsonEncode(message)),
    );
    final client = DaemonClient._(socket, peer);
    try {
      client.daemonInfo = token != null
          ? await _authenticate(peer, token, timeout)
          : await _probe(peer, url, timeout);
    } on Object {
      await client.close();
      rethrow;
    }
    return client;
  }

  /// Decodes a text frame; binary or malformed frames are ignored (never
  /// fatal), per the codec contract.
  static Object? _decodeFrame(Object? frame) {
    if (frame is! String) return null;
    try {
      return jsonDecode(frame);
    } on FormatException {
      return null;
    }
  }

  static Future<DaemonInfo> _authenticate(
    RpcPeer peer,
    String token,
    Duration timeout,
  ) async {
    final result = await peer
        .call('auth.authenticate', <String, Object?>{'token': token})
        .timeout(timeout);
    final map = _asMap(result, 'auth.authenticate');
    final daemonJson = map['daemon'];
    if (map['ok'] != true || daemonJson is! Map) {
      throw DaemonError(kErrUnauthenticated, 'Authentication failed');
    }
    return DaemonInfo.fromJson(Map<String, Object?>.from(daemonJson));
  }

  static Future<DaemonInfo> _probe(
    RpcPeer peer,
    String url,
    Duration timeout,
  ) async {
    DaemonInfo info;
    try {
      final result = await peer.call('daemon.info').timeout(timeout);
      info = DaemonInfo.fromJson(_asMap(result, 'daemon.info'));
    } on DaemonError catch (error) {
      if (error.code == kErrUnauthenticated) {
        throw DaemonError(
          kErrUnauthenticated,
          '$url requires authentication; provide a token (--token or '
          'SPEEDIAL_TOKEN)',
        );
      }
      rethrow;
    }
    if (info.authRequired) {
      // Daemons bound non-loopback (or started with --token) answer
      // `daemon.info` pre-auth but require a token for everything else:
      // refuse the connection up front so later calls cannot fail one by one.
      throw DaemonError(
        kErrUnauthenticated,
        '$url requires authentication; provide a token (--token or '
        'SPEEDIAL_TOKEN)',
      );
    }
    return info;
  }

  static Map<String, Object?> _asMap(Object? value, String method) {
    if (value is Map) return Map<String, Object?>.from(value);
    throw FormatException(
      'Malformed response for "$method": expected a JSON object',
    );
  }

  // ---------------------------------------------------------------------------
  // Transport
  // ---------------------------------------------------------------------------

  /// The daemon's outbound notifications (`session.created`, `session.updated`,
  /// `session.removed`, `session.event`, `projects.changed`).
  ///
  /// Single-subscription: listen at most once per connection.
  Stream<RpcNotification> get notifications => _peer.notifications;

  /// Parsed `session.event` broadcasts for streaming UIs (e.g. `attach`).
  ///
  /// Delivers `(sessionId, seq, event)`; derives from [notifications], so it
  /// shares the single-subscription constraint.
  Stream<({String sessionId, int seq, SessionEvent event})> get sessionEvents =>
      _peer.notifications
          .where((notification) => notification.method == 'session.event')
          .map(_parseSessionEvent);

  static ({String sessionId, int seq, SessionEvent event}) _parseSessionEvent(
    RpcNotification notification,
  ) {
    final params = notification.params;
    final event = params['event'];
    if (event is! Map) {
      throw const FormatException('Malformed session.event notification');
    }
    return (
      sessionId: params['sessionId']! as String,
      seq: params['seq']! as int,
      event: SessionEvent.fromJson(Map<String, Object?>.from(event)),
    );
  }

  /// Closes the WebSocket. Pending calls complete with
  /// `DaemonConnectionError(-32603, 'peer closed')`; the notification
  /// stream closes.
  Future<void> close() async {
    _peer.close();
    await _socket.close();
  }

  // ---------------------------------------------------------------------------
  // Daemon
  // ---------------------------------------------------------------------------

  /// `daemon.info` — static daemon identity.
  Future<DaemonInfo> info() async => DaemonInfo.fromJson(
    _asMap(await _peer.call('daemon.info'), 'daemon.info'),
  );

  /// `providers.list` — providers (with live availability) known to the daemon.
  Future<List<ProviderInfo>> listProviders() async {
    final map = _asMap(await _peer.call('providers.list'), 'providers.list');
    final raw = map['providers'];
    if (raw is! List) {
      throw const FormatException(
        'Malformed response for "providers.list" (missing "providers" array)',
      );
    }
    return [
      for (final item in raw)
        ProviderInfo.fromJson(_asMap(item, 'providers.list')),
    ];
  }

  // ---------------------------------------------------------------------------
  // Projects
  // ---------------------------------------------------------------------------

  /// `projects.list` — all projects, oldest added first.
  Future<List<Project>> listProjects() async {
    final map = _asMap(await _peer.call('projects.list'), 'projects.list');
    final raw = map['projects'];
    if (raw is! List) {
      throw const FormatException(
        'Malformed response for "projects.list" (missing "projects" array)',
      );
    }
    return [
      for (final item in raw) Project.fromJson(_asMap(item, 'projects.list')),
    ];
  }

  /// `projects.add` — registers [path] (an absolute local directory).
  Future<Project> addProject(String path, {String? name}) async {
    final result = await _peer.call('projects.add', <String, Object?>{
      'path': path,
      'name': ?name,
    });
    final map = _asMap(result, 'projects.add');
    return Project.fromJson(_asMap(map['project'], 'projects.add'));
  }

  /// `projects.remove` — detaches the project; its sessions are archived.
  Future<void> removeProject(String id) async {
    await _peer.call('projects.remove', <String, Object?>{'id': id});
  }

  /// `projects.rename` — renames a project.
  Future<Project> renameProject(String id, String name) async {
    final result = await _peer.call('projects.rename', <String, Object?>{
      'id': id,
      'name': name,
    });
    final map = _asMap(result, 'projects.rename');
    return Project.fromJson(_asMap(map['project'], 'projects.rename'));
  }

  // ---------------------------------------------------------------------------
  // Sessions
  // ---------------------------------------------------------------------------

  /// `sessions.list` — sessions, optionally filtered by project/archive state.
  Future<List<Session>> listSessions({
    String? projectId,
    bool includeArchived = false,
  }) async {
    final result = await _peer.call('sessions.list', <String, Object?>{
      'projectId': ?projectId,
      'includeArchived': includeArchived,
    });
    final map = _asMap(result, 'sessions.list');
    final raw = map['sessions'];
    if (raw is! List) {
      throw const FormatException(
        'Malformed response for "sessions.list" (missing "sessions" array)',
      );
    }
    return [
      for (final item in raw) Session.fromJson(_asMap(item, 'sessions.list')),
    ];
  }

  /// `sessions.create` — spawns an agent session in [projectId]. When
  /// [baseBranch] is given the daemon creates a git worktree off
  /// `origin/<baseBranch>` and uses it as the session cwd. [sandboxMode]
  /// selects provider isolation when advertised. With [yolo] the daemon
  /// auto-approves the agent's permission requests.
  Future<Session> createSession({
    required String projectId,
    required String providerId,
    String? model,
    SessionMode? mode,
    String? title,
    String? cwd,
    String? baseBranch,
    SessionSandboxMode? sandboxMode,
    bool yolo = false,
  }) async {
    final result = await _peer.call('sessions.create', <String, Object?>{
      'projectId': projectId,
      'providerId': providerId,
      'model': ?model,
      'mode': ?mode?.wire,
      'title': ?title,
      'cwd': ?cwd,
      'baseBranch': ?baseBranch,
      'sandboxMode': ?sandboxMode?.wire,
      if (yolo) 'yolo': true,
    });
    final map = _asMap(result, 'sessions.create');
    return Session.fromJson(_asMap(map['session'], 'sessions.create'));
  }

  /// `sessions.send` — starts a turn with [text] and the attached files.
  /// [attachments] travel as base64 payloads; the `attachments` parameter is
  /// omitted entirely when the message carries no files.
  Future<void> sendMessage(
    String sessionId,
    String text, {
    List<OutgoingAttachment> attachments = const <OutgoingAttachment>[],
  }) async {
    await _peer.call('sessions.send', <String, Object?>{
      'sessionId': sessionId,
      'text': text,
      if (attachments.isNotEmpty)
        'attachments': attachments
            .map((e) => e.toJson())
            .toList(growable: false),
    });
  }

  /// `sessions.cancel` — cancels the running turn of [sessionId] (no-op when
  /// idle).
  Future<void> cancel(String sessionId) async {
    await _peer.call('sessions.cancel', <String, Object?>{
      'sessionId': sessionId,
    });
  }

  /// `sessions.rename` — renames a session.
  Future<Session> renameSession(String sessionId, String title) async {
    final result = await _peer.call('sessions.rename', <String, Object?>{
      'sessionId': sessionId,
      'title': title,
    });
    final map = _asMap(result, 'sessions.rename');
    return Session.fromJson(_asMap(map['session'], 'sessions.rename'));
  }

  /// `sessions.archive` — marks a session archived (`archived: true`) or not.
  Future<Session> archiveSession(String sessionId, bool archived) async {
    final result = await _peer.call('sessions.archive', <String, Object?>{
      'sessionId': sessionId,
      'archived': archived,
    });
    final map = _asMap(result, 'sessions.archive');
    return Session.fromJson(_asMap(map['session'], 'sessions.archive'));
  }

  /// `sessions.acknowledgeCompletion` — clears an observed completed turn if
  /// [completionRevision] still identifies the latest completion.
  Future<Session> acknowledgeCompletion(
    String sessionId,
    int completionRevision,
  ) async {
    final result = await _peer.call(
      'sessions.acknowledgeCompletion',
      <String, Object?>{
        'sessionId': sessionId,
        'completionRevision': completionRevision,
      },
    );
    final map = _asMap(result, 'sessions.acknowledgeCompletion');
    return Session.fromJson(
      _asMap(map['session'], 'sessions.acknowledgeCompletion'),
    );
  }

  /// `sessions.delete` — kills the agent process, if alive, and removes the
  /// session and its events.
  Future<void> deleteSession(String sessionId) async {
    await _peer.call('sessions.delete', <String, Object?>{
      'sessionId': sessionId,
    });
  }

  /// `sessions.setMode` — switches the session mode.
  Future<Session> setMode(String sessionId, SessionMode mode) async {
    final result = await _peer.call('sessions.setMode', <String, Object?>{
      'sessionId': sessionId,
      'mode': mode.wire,
    });
    final map = _asMap(result, 'sessions.setMode');
    return Session.fromJson(_asMap(map['session'], 'sessions.setMode'));
  }

  /// `sessions.setModel` — persists the selected model.
  Future<Session> setModel(String sessionId, String model) async {
    final result = await _peer.call('sessions.setModel', <String, Object?>{
      'sessionId': sessionId,
      'model': model,
    });
    final map = _asMap(result, 'sessions.setModel');
    return Session.fromJson(_asMap(map['session'], 'sessions.setModel'));
  }

  /// `sessions.setThinkingLevel` — switches the session thinking level.
  Future<Session> setThinkingLevel(String sessionId, String level) async {
    final result = await _peer.call(
      'sessions.setThinkingLevel',
      <String, Object?>{'sessionId': sessionId, 'level': level},
    );
    final map = _asMap(result, 'sessions.setThinkingLevel');
    return Session.fromJson(
      _asMap(map['session'], 'sessions.setThinkingLevel'),
    );
  }

  /// `sessions.history` — persisted events of [sessionId] ascending by `seq`.
  ///
  /// Default [limit] is 200 (protocol cap 1000); [beforeSeq] pages further
  /// back. `hasMore` reports whether an older page exists.
  Future<({List<SessionEvent> events, bool hasMore})> history(
    String sessionId, {
    int? limit,
    int? beforeSeq,
  }) async {
    final result = await _peer.call('sessions.history', <String, Object?>{
      'sessionId': sessionId,
      'limit': ?limit,
      'beforeSeq': ?beforeSeq,
    });
    final map = _asMap(result, 'sessions.history');
    final raw = map['events'];
    if (raw is! List) {
      throw const FormatException(
        'Malformed response for "sessions.history" (missing "events" array)',
      );
    }
    return (
      events: [
        for (final item in raw)
          SessionEvent.fromJson(_asMap(item, 'sessions.history')),
      ],
      hasMore: map['hasMore'] == true,
    );
  }

  /// `sessions.respondPermission` — resolves a parked permission request.
  Future<void> respondPermission(
    String sessionId,
    String requestId,
    String optionId,
  ) async {
    await _peer.call('sessions.respondPermission', <String, Object?>{
      'sessionId': sessionId,
      'requestId': requestId,
      'optionId': optionId,
    });
  }

  // ---------------------------------------------------------------------------
  // Files
  // ---------------------------------------------------------------------------

  /// `fs.list` — directory entries under [projectId] (paths relative to the
  /// project root; default `"."`).
  Future<List<FileEntry>> listFiles(String projectId, {String? path}) async {
    final result = await _peer.call('fs.list', <String, Object?>{
      'projectId': projectId,
      'path': ?path,
    });
    final map = _asMap(result, 'fs.list');
    final raw = map['entries'];
    if (raw is! List) {
      throw const FormatException(
        'Malformed response for "fs.list" (missing "entries" array)',
      );
    }
    return [
      for (final item in raw) FileEntry.fromJson(_asMap(item, 'fs.list')),
    ];
  }

  /// `fs.read` — reads [path] within [projectId]; binary files come back with
  /// empty [FileReadResult.content] and `isBinary: true`.
  Future<FileReadResult> readFile(
    String projectId,
    String path, {
    int? maxBytes,
  }) async {
    final result = await _peer.call('fs.read', <String, Object?>{
      'projectId': projectId,
      'path': path,
      'maxBytes': ?maxBytes,
    });
    return FileReadResult.fromJson(_asMap(result, 'fs.read'));
  }

  /// `fs.download` — fetches the complete binary payload for [path], resolved
  /// against the session's working directory.
  Future<FileDownload> downloadFile(String sessionId, String path) async {
    final result = await _peer.call('fs.download', <String, Object?>{
      'sessionId': sessionId,
      'path': path,
    });
    return FileDownload.fromJson(_asMap(result, 'fs.download'));
  }

  // ---------------------------------------------------------------------------
  // Git
  // ---------------------------------------------------------------------------

  /// `git.status` — branch, divergence, and changed files.
  Future<GitStatus> gitStatus(String projectId) async {
    final result = await _peer.call('git.status', <String, Object?>{
      'projectId': projectId,
    });
    final map = _asMap(result, 'git.status');
    return GitStatus.fromJson(_asMap(map['status'], 'git.status'));
  }

  /// `git.diff` — per-file unified diffs, optionally restricted to [path]
  /// and/or the index ([staged]).
  Future<List<GitDiff>> gitDiff(
    String projectId, {
    String? path,
    bool staged = false,
  }) async {
    final result = await _peer.call('git.diff', <String, Object?>{
      'projectId': projectId,
      'path': ?path,
      'staged': staged,
    });
    final map = _asMap(result, 'git.diff');
    final raw = map['diffs'];
    if (raw is! List) {
      throw const FormatException(
        'Malformed response for "git.diff" (missing "diffs" array)',
      );
    }
    return [for (final item in raw) GitDiff.fromJson(_asMap(item, 'git.diff'))];
  }

  /// `git.branches` — local branches with upstream info.
  Future<List<Branch>> gitBranches(String projectId) async {
    final result = await _peer.call('git.branches', <String, Object?>{
      'projectId': projectId,
    });
    final map = _asMap(result, 'git.branches');
    final raw = map['branches'];
    if (raw is! List) {
      throw const FormatException(
        'Malformed response for "git.branches" (missing "branches" array)',
      );
    }
    return [
      for (final item in raw) Branch.fromJson(_asMap(item, 'git.branches')),
    ];
  }

  /// `git.checkout` — checks out an existing [branch].
  Future<void> gitCheckout(String projectId, String branch) async {
    await _peer.call('git.checkout', <String, Object?>{
      'projectId': projectId,
      'branch': branch,
    });
  }

  /// `git.createBranch` — creates [name], checking it out unless
  /// [checkout] is false.
  Future<void> gitCreateBranch(
    String projectId,
    String name, {
    bool checkout = true,
  }) async {
    await _peer.call('git.createBranch', <String, Object?>{
      'projectId': projectId,
      'name': name,
      'checkout': checkout,
    });
  }

  /// `git.commit` — commits staged changes (or all when [stageAll]) and
  /// returns the full commit hash.
  Future<String> gitCommit(
    String projectId,
    String message, {
    bool stageAll = false,
  }) async {
    final result = await _peer.call('git.commit', <String, Object?>{
      'projectId': projectId,
      'message': message,
      'stageAll': stageAll,
    });
    final map = _asMap(result, 'git.commit');
    final hash = map['commitHash'];
    if (hash is! String) {
      throw const FormatException(
        'Malformed response for "git.commit" (missing "commitHash")',
      );
    }
    return hash;
  }

  /// `git.push` — pushes the current branch.
  Future<void> gitPush(String projectId, {bool setUpstream = false}) async {
    await _peer.call('git.push', <String, Object?>{
      'projectId': projectId,
      'setUpstream': setUpstream,
    });
  }

  /// `git.createPullRequest` — opens a PR via `gh` and returns its URL.
  Future<String> gitCreatePr(
    String projectId, {
    String? title,
    String? body,
    String? base,
    bool draft = false,
  }) async {
    final result = await _peer.call('git.createPullRequest', <String, Object?>{
      'projectId': projectId,
      'title': ?title,
      'body': ?body,
      'base': ?base,
      'draft': draft,
    });
    final map = _asMap(result, 'git.createPullRequest');
    final url = map['url'];
    if (url is! String) {
      throw const FormatException(
        'Malformed response for "git.createPullRequest" (missing "url")',
      );
    }
    return url;
  }

  /// `git.mergeToBase` — merges the session's worktree branch back into the
  /// base branch the session was created from, fast-forwarding the local
  /// base to `origin/<baseBranch>` first when the remote moved ahead.
  Future<MergeResult> gitMergeToBase(String projectId, String sessionId) async {
    final result = await _peer.call('git.mergeToBase', <String, Object?>{
      'projectId': projectId,
      'sessionId': sessionId,
    });
    final map = _asMap(result, 'git.mergeToBase');
    return MergeResult.fromJson(_asMap(map['merge'], 'git.mergeToBase'));
  }
}
