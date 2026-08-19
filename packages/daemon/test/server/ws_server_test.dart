@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_daemon/src/engine/session_engine.dart';
import 'package:speeddial_daemon/src/git/git_service.dart';
import 'package:speeddial_daemon/src/providers/provider_registry.dart';
import 'package:speeddial_daemon/src/server/ws_server.dart';
import 'package:speeddial_daemon/src/store/daemon_store.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:test/test.dart';

/// Resolves the fake ACP agent fixture whether the runner's cwd is the
/// package dir (`dart test` in packages/daemon) or the repo root
/// (`dart test packages/daemon`).
String resolveFixture() => <String>[
      p.join(Directory.current.path, 'test', 'fixtures', 'fake_acp_agent.dart'),
      p.join(
          Directory.current.path, 'packages', 'daemon', 'test', 'fixtures',
          'fake_acp_agent.dart'),
    ].firstWhere((path) => File(path).existsSync());

/// A registry whose only provider is the fake ACP fixture, spawned through
/// the current Dart VM. The fake declares static models; the built-in `omp`
/// probe is stubbed out so tests never touch real agent CLIs.
ProviderRegistry fakeProviders() => ProviderRegistry(
      configOverrides: <String, Object?>{
        'providers': <String, Object?>{
          'fake': <String, Object?>{
            'name': 'Fake Agent',
            'command': <String>[Platform.resolvedExecutable, resolveFixture()],
            'models': <String>['fake-fast', 'fake-smart'],
          },
        },
      },
      modelsProbe: (command) async => const <String>[],
    );

/// A test client: its own [RpcPeer] over a real WebSocket.
class WsClient {
  WsClient(this.socket) {
    peer = RpcPeer(
      incoming: _incoming.stream,
      send: (message) => socket.add(jsonEncode(message)),
    );
    _notificationsSub = peer.notifications.listen(notifications.add);
  }

  final WebSocket socket;
  final StreamController<Object?> _incoming =
      StreamController<Object?>(sync: true);
  final List<RpcNotification> notifications = <RpcNotification>[];
  late final RpcPeer peer;
  late final StreamSubscription<RpcNotification> _notificationsSub;

  /// Attaches the socket listener; called before any request is issued.
  void start() {
    socket.listen((data) {
      if (data is! String) return; // Binary frames carry no JSON-RPC.
      Object? decoded;
      try {
        decoded = jsonDecode(data);
      } on FormatException {
        return; // Malformed frame: ignore.
      }
      _incoming.add(decoded);
    });
  }

  List<RpcNotification> of(String method) =>
      notifications.where((n) => n.method == method).toList();

  Future<void> close() async {
    await _notificationsSub.cancel();
    peer.close();
    if (!_incoming.isClosed) await _incoming.close();
    try {
      await socket.close();
    } on Object {
      // Already closed by the peer.
    }
  }
}

Future<WsClient> connect(int port) async {
  final socket = await WebSocket.connect('ws://127.0.0.1:$port/ws');
  final client = WsClient(socket);
  client.start();
  return client;
}

/// Coerces a JSON-RPC result into a parameter map.
Map<String, Object?> j(Object? result) =>
    (result! as Map).cast<String, Object?>();

/// Completes with the params of the first `session.event` notification whose
/// event satisfies [predicate]; designed to be awaited *after* the turn that
/// produces it is requested. Listens on the client's peer directly so no
/// notification is lost between the request and the await.
Future<Map<String, Object?>> waitForEvent(
  WsClient client,
  bool Function(SessionEvent event) predicate,
) {
  final done = Completer<Map<String, Object?>>();
  final sub = client.peer.notifications.listen((notification) {
    if (notification.method != 'session.event' || done.isCompleted) return;
    final raw = notification.params['event'];
    if (raw is! Map) return;
    final event = SessionEvent.fromJson(raw.cast<String, Object?>());
    if (predicate(event)) done.complete(notification.params);
  });
  return done.future.whenComplete(sub.cancel);
}

/// Polls the client's always-on recorder until [count] notifications of
/// [method] have been captured; safe for events already emitted.
Future<void> untilRecorded(WsClient client, String method, int count) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (client.of(method).length < count) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('expected $count x $method', const Duration(seconds: 10));
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<Directory> _initRepo() async {
  final dir = await Directory.systemTemp.createTemp('sd_ws_git_');
  for (final args in <List<String>>[
    <String>['init', '-b', 'main'],
    <String>['config', 'user.email', 'test@example.com'],
    <String>['config', 'user.name', 'Test User'],
  ]) {
    final result =
        await Process.run('git', args, workingDirectory: dir.path);
    if (result.exitCode != 0) {
      throw StateError('git ${args.first} failed: ${result.stderr}');
    }
  }
  return dir;
}

Future<void> _write(Directory repo, String name, String content) async {
  await File(p.join(repo.path, name)).writeAsString(content);
}

void main() {
  late Directory tempDir;
  late DaemonStore store;
  late ProviderRegistry providers;
  late SessionEngine? engine;
  late SpeedDialServer? server;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ws_server_test_');
    store = DaemonStore(p.join(tempDir.path, 'speeddial.db'));
    providers = fakeProviders();
    engine = null;
    server = null;
  });

  tearDown(() async {
    final s = server;
    if (s != null) await s.close();
    final e = engine;
    if (e != null) await e.dispose();
    store.dispose();
    try {
      await tempDir.delete(recursive: true);
    } on Object {
      // Cleanup failure is not a test failure.
    }
  });

  Future<SpeedDialServer> startServer({String? authToken}) async {
    engine = SessionEngine(store: store, providers: providers,
        git: GitService());
    await engine!.restore();
    server = await SpeedDialServer.bind(
      host: '127.0.0.1',
      port: 0,
      engine: engine!,
      store: store,
      providers: providers,
      authToken: authToken,
    );
    return server!;
  }

  group('auth', () {
    test('unauthenticated requests are gated until auth.authenticate',
        () async {
      await startServer(authToken: 'secret');
      final client = await connect(server!.port);

      // Everything except auth.authenticate / daemon.info is gated.
      await expectLater(
        client.peer.call('projects.list'),
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', kErrUnauthenticated)),
      );
      await expectLater(
        client.peer.call('sessions.list'),
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', kErrUnauthenticated)),
      );

      // daemon.info is pre-auth enabled and reports authRequired.
      final info =
          DaemonInfo.fromJson(j(await client.peer.call('daemon.info')));
      expect(info.authRequired, isTrue);
      expect(info.protocolVersion, 1);
      expect(info.providers.map((p) => p.id), contains('fake'));

      // A wrong token fails with the exact PROTOCOL.md message.
      await expectLater(
        client.peer.call('auth.authenticate', <String, Object?>{
          'token': 'wrong-token',
        }),
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', kErrUnauthenticated)
            .having((e) => e.message, 'message', 'invalid token')),
      );

      // The right token unlocks the API.
      final auth = j(await client.peer
          .call('auth.authenticate', <String, Object?>{'token': 'secret'}));
      expect(auth['ok'], isTrue);
      expect((auth['daemon']! as Map)['authRequired'], isTrue);
      final projects = j(await client.peer.call('projects.list'));
      expect(projects['projects'], isEmpty);

      await client.close();
    });

    test('daemon.info reports authRequired false without a token', () async {
      await startServer();
      final client = await connect(server!.port);

      final info =
          DaemonInfo.fromJson(j(await client.peer.call('daemon.info')));
      expect(info.authRequired, isFalse);
      expect(info.providers.map((p) => p.id), contains('fake'));
      expect(
        info.providers.firstWhere((p) => p.id == 'fake').models,
        <String>['fake-fast', 'fake-smart'],
      );

      await client.close();
    });
  });

  group('projects', () {
    test('add validates, rename round-trips, remove detaches', () async {
      await startServer();
      final client = await connect(server!.port);
      final dir = await Directory.systemTemp.createTemp('sd_proj_');

      // Add with an explicit name.
      final added = j(await client.peer.call('projects.add',
          <String, Object?>{'path': dir.path, 'name': 'Demo'}));
      final project =
          Project.fromJson((added['project']! as Map).cast<String, Object?>());
      expect(project.name, 'Demo');
      expect(project.path, p.normalize(dir.path));

      // Non-directory and missing params are invalid.
      await expectLater(
        client.peer.call('projects.add',
            <String, Object?>{'path': p.join(dir.path, 'nope')}),
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', -32602)),
      );
      await expectLater(
        client.peer.call('projects.add', <String, Object?>{}),
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', -32602)),
      );

      // Duplicate path conflicts.
      await expectLater(
        client.peer.call('projects.add',
            <String, Object?>{'path': dir.path, 'name': 'Again'}),
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', kErrConflict)),
      );

      // Rename updates the name; unknown ids are not found.
      final renamed = j(await client.peer.call('projects.rename',
          <String, Object?>{'id': project.id, 'name': 'Renamed'}));
      expect(
        Project.fromJson((renamed['project']! as Map).cast<String, Object?>())
            .name,
        'Renamed',
      );
      await expectLater(
        client.peer.call('projects.rename',
            <String, Object?>{'id': 'missing', 'name': 'X'}),
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', kErrNotFound)),
      );

      // List reflects the rename.
      final listed = j(await client.peer.call('projects.list'));
      final projects = (listed['projects']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(projects, hasLength(1));
      expect(projects.single['name'], 'Renamed');

      // Remove detaches the project.
      await client.peer
          .call('projects.remove', <String, Object?>{'id': project.id});
      expect(
        (j(await client.peer.call('projects.list'))['projects']! as List),
        isEmpty,
      );
      await expectLater(
        client.peer.call('projects.remove',
            <String, Object?>{'id': project.id}),
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', kErrNotFound)),
      );

      await untilRecorded(client, 'projects.changed', 3);
      final changed = client.of('projects.changed');
      expect(changed, hasLength(greaterThanOrEqualTo(3)),
          reason: 'add, rename, and remove each announce projects.changed');
      await client.close();
    });
  });

  group('sessions', () {
    test('full lifecycle: create, send, ordered events, permission, history',
        () async {
      await startServer();
      final client = await connect(server!.port);
      final dir = await Directory.systemTemp.createTemp('sd_session_');
      File(p.join(dir.path, 'example.txt'))
          .writeAsStringSync('hello from file\n');
      final project = Project.fromJson((j(await client.peer
              .call('projects.add', <String, Object?>{'path': dir.path}))[
                  'project']! as Map)
          .cast<String, Object?>());

      // Create spawns an idle session and announces session.created.
      final created = j(await client.peer.call('sessions.create',
          <String, Object?>{
            'projectId': project.id,
            'providerId': 'fake',
            'mode': 'build',
            'title': 'Lifecycle',
          }));
      final session = Session.fromJson(
          (created['session']! as Map).cast<String, Object?>());
      expect(session.status, SessionStatus.idle);
      expect(session.title, 'Lifecycle');
      expect(session.mode, SessionMode.build);
      await untilRecorded(client, 'session.created', 1);
      expect(client.of('session.created'), hasLength(1));

      // Start a turn; it parks at the permission request until resolved.
      final permissionFuture =
          waitForEvent(client, (event) => event is PermissionRequestEvent);
      final send = client.peer.call('sessions.send',
          <String, Object?>{'sessionId': session.id, 'text': 'inspect'});
      var sendDone = false;
      unawaited(send.then((_) {
        sendDone = true;
      }));

      final requestParams = await permissionFuture;
      final request = ((requestParams['event']! as Map)['request']! as Map)
          .cast<String, Object?>();
      expect(request['toolCallId'], 'tc1');
      expect(request['title'], 'Read example.txt');

      await Future<void>.delayed(Duration.zero);
      expect(sendDone, isFalse,
          reason: 'the turn is parked until respondPermission');

      await client.peer.call('sessions.respondPermission', <String, Object?>{
        'sessionId': session.id,
        'requestId': request['requestId']! as String,
        'optionId': 'allow',
      });
      await send;
      expect(sendDone, isTrue);

      // All ten events arrived in the order the agent produced them. The
      // turn's tail (usage, turnComplete) is emitted asynchronously after the
      // response, so poll the recorder before counting.
      await untilRecorded(client, 'session.event', 10);
      final events = client
          .of('session.event')
          .map((n) => SessionEvent.fromJson(
              (n.params['event']! as Map).cast<String, Object?>()))
          .toList();
      expect(
        events.map((e) => e.runtimeType).toList(),
        <Type>[
          UserMessageEvent,
          AgentMessageChunkEvent,
          AgentMessageChunkEvent,
          ToolCallEvent, // created
          ToolCallEvent, // completed (merged)
          PlanEvent,
          PermissionRequestEvent,
          PermissionResolvedEvent,
          UsageEvent,
          TurnCompleteEvent,
        ],
      );
      for (var i = 0; i < events.length; i++) {
        expect(events[i].seq, i + 1, reason: 'seq is assigned 1..N');
      }
      expect((events.last as TurnCompleteEvent).stopReason, 'end_turn');
      final resolved = events[7] as PermissionResolvedEvent;
      expect(resolved.requestId, request['requestId']);
      expect(resolved.optionId, 'allow');

      // History replays the same events; paging honours limit/beforeSeq.
      final history = j(await client.peer
          .call('sessions.history', <String, Object?>{'sessionId': session.id}));
      final replayed = (history['events']! as List<Object?>)
          .map((e) =>
              SessionEvent.fromJson((e! as Map).cast<String, Object?>()))
          .toList();
      expect(replayed, hasLength(events.length));
      expect(replayed.map((e) => e.seq), events.map((e) => e.seq));
      expect(history['hasMore'], isFalse);
      final page = j(await client.peer.call('sessions.history',
          <String, Object?>{
            'sessionId': session.id,
            'limit': 4,
            'beforeSeq': 10,
          }));
      expect(
        (page['events']! as List<Object?>).map((e) => (e! as Map)['seq']),
        <Object?>[6, 7, 8, 9],
      );
      expect(page['hasMore'], isTrue);
      await expectLater(
        client.peer.call('sessions.history',
            <String, Object?>{'sessionId': 'nope'}),
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', kErrNotFound)),
      );

      // Metadata changes persist and broadcast session.updated.
      final renamed = j(await client.peer.call('sessions.rename',
          <String, Object?>{'sessionId': session.id, 'title': 'Renamed'}));
      expect(
        Session.fromJson((renamed['session']! as Map).cast<String, Object?>())
            .title,
        'Renamed',
      );
      await untilRecorded(client, 'session.updated', 1);
      expect(client.of('session.updated'), isNotEmpty);

      final modeChanged = j(await client.peer.call('sessions.setMode',
          <String, Object?>{'sessionId': session.id, 'mode': 'plan'}));
      expect(
        Session.fromJson(
                (modeChanged['session']! as Map).cast<String, Object?>())
            .mode,
        SessionMode.plan,
      );
      await expectLater(
        client.peer.call('sessions.setMode',
            <String, Object?>{'sessionId': session.id, 'mode': 'bogus'}),
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', -32602)),
      );

      // Archiving hides the session from the default list.
      expect(
        (j(await client.peer
                .call('sessions.list', <String, Object?>{}))['sessions']!
            as List),
        hasLength(1),
      );
      await client.peer.call('sessions.archive',
          <String, Object?>{'sessionId': session.id, 'archived': true});
      expect(
        (j(await client.peer
                .call('sessions.list', <String, Object?>{}))['sessions']!
            as List),
        isEmpty,
      );
      final withArchived = j(await client.peer.call('sessions.list',
          <String, Object?>{'includeArchived': true}));
      final archived = ((withArchived['sessions']! as List<Object?>).single!
              as Map)
          .cast<String, Object?>();
      expect(archived['archived'], isTrue);

      // Delete removes the session and announces session.removed.
      await client.peer
          .call('sessions.delete', <String, Object?>{'sessionId': session.id});
      await untilRecorded(client, 'session.removed', 1);
      expect(client.of('session.removed'), hasLength(1));
      await expectLater(
        client.peer.call('sessions.delete',
            <String, Object?>{'sessionId': session.id}),
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', kErrNotFound)),
      );

      await client.close();
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('sessions.create with baseBranch runs the session in a worktree',
        () async {
      await startServer();
      final client = await connect(server!.port);

      // Project repo cloned from a local bare origin (filesystem-only
      // remote; no network), so fetch has an origin/main to refresh.
      final parent = await Directory.systemTemp.createTemp('sd_ws_wt_');
      addTearDown(() async {
        try {
          await parent.delete(recursive: true);
        } on Object {
          // Cleanup failure is not a test failure.
        }
      });
      Future<void> git(String cwd, List<String> args) async {
        final result =
            await Process.run('git', args, workingDirectory: cwd);
        if (result.exitCode != 0) {
          throw StateError('git ${args.join(' ')} failed: ${result.stderr}');
        }
      }

      final originDir = p.join(parent.path, 'origin.git');
      await git(parent.path, ['init', '--bare', '-b', 'main', originDir]);
      final repoPath = p.join(parent.path, 'repo');
      await git(parent.path, ['clone', originDir, repoPath]);
      await git(repoPath, ['config', 'user.email', 'test@example.com']);
      await git(repoPath, ['config', 'user.name', 'Test User']);
      File(p.join(repoPath, 'a.txt')).writeAsStringSync('v1\n');
      await git(repoPath, ['add', '-A']);
      await git(repoPath, ['commit', '-m', 'init']);
      await git(repoPath, ['push', '-u', 'origin', 'main']);

      final project = Project.fromJson((j(await client.peer
              .call('projects.add', <String, Object?>{'path': repoPath}))[
                  'project']! as Map)
          .cast<String, Object?>());

      final created = j(await client.peer
          .call('sessions.create', <String, Object?>{
        'projectId': project.id,
        'providerId': 'fake',
        'title': 'Worktree session',
        'baseBranch': 'main',
      }));
      final session = Session.fromJson(
          (created['session']! as Map).cast<String, Object?>());
      expect(session.cwd, contains('.speeddial-worktrees'));
      expect(Directory(session.cwd).existsSync(), isTrue);
      final branch = await Process.run(
          'git', ['branch', '--show-current'],
          workingDirectory: session.cwd);
      expect((branch.stdout as String).trim(),
          startsWith('speeddial/worktree-session-'));

      // baseBranch and cwd conflict over the wire too.
      await expectLater(
        client.peer.call('sessions.create', <String, Object?>{
          'projectId': project.id,
          'providerId': 'fake',
          'cwd': repoPath,
          'baseBranch': 'main',
        }),
        throwsA(isA<DaemonError>().having((e) => e.code, 'code', -32602)),
      );
      await client.close();
    });

    test('git.* with sessionId operate on the session worktree', () async {
      await startServer();
      final client = await connect(server!.port);

      final parent = await Directory.systemTemp.createTemp('sd_ws_gitwt_');
      addTearDown(() async {
        try {
          await parent.delete(recursive: true);
        } on Object {
          // Cleanup failure is not a test failure.
        }
      });
      Future<void> git(String cwd, List<String> args) async {
        final result = await Process.run('git', args, workingDirectory: cwd);
        if (result.exitCode != 0) {
          throw StateError('git ${args.join(' ')} failed: ${result.stderr}');
        }
      }

      final originDir = p.join(parent.path, 'origin.git');
      await git(parent.path, ['init', '--bare', '-b', 'main', originDir]);
      final repoPath = p.join(parent.path, 'repo');
      await git(parent.path, ['clone', originDir, repoPath]);
      await git(repoPath, ['config', 'user.email', 'test@example.com']);
      await git(repoPath, ['config', 'user.name', 'Test User']);
      File(p.join(repoPath, 'a.txt')).writeAsStringSync('v1\n');
      await git(repoPath, ['add', '-A']);
      await git(repoPath, ['commit', '-m', 'init']);
      await git(repoPath, ['push', '-u', 'origin', 'main']);

      final project = Project.fromJson((j(await client.peer
              .call('projects.add', <String, Object?>{'path': repoPath}))[
                  'project']! as Map)
          .cast<String, Object?>());
      final session = Session.fromJson((j(await client.peer
              .call('sessions.create', <String, Object?>{
            'projectId': project.id,
            'providerId': 'fake',
            'title': 'Worktree git',
            'baseBranch': 'main',
          }))['session']! as Map)
          .cast<String, Object?>());

      // A change in the worktree is invisible at the project path…
      File(p.join(session.cwd, 'a.txt')).writeAsStringSync('v2\n');
      final projectStatus = GitStatus.fromJson((j(await client.peer
              .call('git.status', <String, Object?>{'projectId': project.id}))[
                  'status']! as Map)
          .cast<String, Object?>());
      expect(projectStatus.branch, 'main');
      expect(projectStatus.files, isEmpty);

      // …and fully visible through the session.
      final sessionStatus = GitStatus.fromJson((j(await client.peer.call(
              'git.status',
              <String, Object?>{
                'projectId': project.id,
                'sessionId': session.id,
              }))['status']! as Map)
          .cast<String, Object?>());
      expect(sessionStatus.branch, startsWith('speeddial/worktree-git-'));
      expect(sessionStatus.files.single.path, 'a.txt');
      expect(sessionStatus.files.single.worktreeStatus, 'M');

      final diffs = (j(await client.peer.call('git.diff', <String, Object?>{
        'projectId': project.id,
        'sessionId': session.id,
        'path': 'a.txt',
      }))['diffs']! as List);
      expect(diffs, hasLength(1));
      expect((diffs.single! as Map)['patch'], contains('+v2'));

      // Commits land on the worktree branch, not the main checkout.
      final committed = j(await client.peer.call('git.commit',
          <String, Object?>{
            'projectId': project.id,
            'sessionId': session.id,
            'message': 'work in the worktree',
            'stageAll': true,
          }));
      expect(committed['commitHash'], isA<String>());
      expect(
        await Process.run('git', ['log', '-1', '--format=%s'],
                workingDirectory: session.cwd)
            .then((r) => (r.stdout as String).trim()),
        'work in the worktree',
      );
      expect(
        await Process.run('git', ['log', '-1', '--format=%s'],
                workingDirectory: repoPath)
            .then((r) => (r.stdout as String).trim()),
        'init',
      );

      // Validation: unknown session, and a session from another project.
      await expectLater(
        client.peer.call('git.status', <String, Object?>{
          'projectId': project.id,
          'sessionId': 'nope',
        }),
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', kErrNotFound)),
      );
      final otherDir = p.join(parent.path, 'other');
      await git(parent.path, ['clone', originDir, otherDir]);
      final otherProject = Project.fromJson((j(await client.peer.call(
              'projects.add', <String, Object?>{'path': otherDir}))['project']!
              as Map)
          .cast<String, Object?>());
      final otherSession = Session.fromJson((j(await client.peer.call(
              'sessions.create', <String, Object?>{
            'projectId': otherProject.id,
            'providerId': 'fake',
          }))['session']! as Map)
          .cast<String, Object?>());
      await expectLater(
        client.peer.call('git.status', <String, Object?>{
          'projectId': project.id,
          'sessionId': otherSession.id,
        }),
        throwsA(isA<DaemonError>().having((e) => e.code, 'code', -32602)),
      );
      await client.close();
    });

    test('git.mergeToBase merges the worktree branch into the base', () async {
      await startServer();
      final client = await connect(server!.port);

      final parent = await Directory.systemTemp.createTemp('sd_ws_merge_');
      addTearDown(() async {
        try {
          await parent.delete(recursive: true);
        } on Object {
          // Cleanup failure is not a test failure.
        }
      });
      Future<void> git(String cwd, List<String> args) async {
        final result = await Process.run('git', args, workingDirectory: cwd);
        if (result.exitCode != 0) {
          throw StateError('git ${args.join(' ')} failed: ${result.stderr}');
        }
      }

      final originDir = p.join(parent.path, 'origin.git');
      await git(parent.path, ['init', '--bare', '-b', 'main', originDir]);
      final repoPath = p.join(parent.path, 'repo');
      await git(parent.path, ['clone', originDir, repoPath]);
      await git(repoPath, ['config', 'user.email', 'test@example.com']);
      await git(repoPath, ['config', 'user.name', 'Test User']);
      File(p.join(repoPath, 'a.txt')).writeAsStringSync('v1\n');
      await git(repoPath, ['add', '-A']);
      await git(repoPath, ['commit', '-m', 'init']);
      await git(repoPath, ['push', '-u', 'origin', 'main']);

      final project = Project.fromJson((j(await client.peer
              .call('projects.add', <String, Object?>{'path': repoPath}))[
                  'project']! as Map)
          .cast<String, Object?>());
      final session = Session.fromJson((j(await client.peer
              .call('sessions.create', <String, Object?>{
            'projectId': project.id,
            'providerId': 'fake',
            'title': 'Merge me',
            'baseBranch': 'main',
          }))['session']! as Map)
          .cast<String, Object?>());
      expect(session.baseBranch, 'main',
          reason: 'the wire Session must carry the base branch');

      // Committing in the worktree, then merging, lands on main.
      File(p.join(session.cwd, 'feat.txt')).writeAsStringSync('f\n');
      await client.peer.call('git.commit', <String, Object?>{
        'projectId': project.id,
        'sessionId': session.id,
        'message': 'session work',
        'stageAll': true,
      });
      final merged = j(await client.peer.call('git.mergeToBase',
          <String, Object?>{'projectId': project.id, 'sessionId': session.id}));
      final merge =
          MergeResult.fromJson((merged['merge']! as Map).cast<String, Object?>());
      expect(merge.baseBranch, 'main');
      expect(merge.sessionBranch, startsWith('speeddial/merge-me-'));
      expect(merge.alreadyUpToDate, isFalse);
      expect(merge.fastForward, isTrue);
      expect(merge.baseFastForwarded, isFalse);
      expect(
        await Process.run('git', ['log', '-1', '--format=%s'],
                workingDirectory: repoPath)
            .then((r) => (r.stdout as String).trim()),
        'session work',
      );
      expect(File(p.join(repoPath, 'feat.txt')).existsSync(), isTrue);

      // A second merge is a no-op.
      final again = MergeResult.fromJson((j(await client.peer.call(
              'git.mergeToBase',
              <String, Object?>{
                'projectId': project.id,
                'sessionId': session.id,
              }))['merge']! as Map)
          .cast<String, Object?>());
      expect(again.alreadyUpToDate, isTrue);

      // A dirty worktree is a conflict, and a session without a base branch
      // is invalid params.
      File(p.join(session.cwd, 'dirty.txt')).writeAsStringSync('x\n');
      await expectLater(
        client.peer.call('git.mergeToBase', <String, Object?>{
          'projectId': project.id,
          'sessionId': session.id,
        }),
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', kErrConflict)),
      );
      final plain = Session.fromJson((j(await client.peer.call(
              'sessions.create', <String, Object?>{
            'projectId': project.id,
            'providerId': 'fake',
          }))['session']! as Map)
          .cast<String, Object?>());
      expect(plain.baseBranch, isNull);
      await expectLater(
        client.peer.call('git.mergeToBase', <String, Object?>{
          'projectId': project.id,
          'sessionId': plain.id,
        }),
        throwsA(isA<DaemonError>().having((e) => e.code, 'code', -32602)),
      );
      await expectLater(
        client.peer.call('git.mergeToBase',
            <String, Object?>{'projectId': project.id}),
        throwsA(isA<DaemonError>().having((e) => e.code, 'code', -32602)),
      );
      await client.close();
    });

    test('git.sessionSummaries reports dirty/ahead/merged per session',
        () async {
      await startServer();
      final client = await connect(server!.port);

      final parent = await Directory.systemTemp.createTemp('sd_ws_summaries_');
      addTearDown(() async {
        try {
          await parent.delete(recursive: true);
        } on Object {
          // Cleanup failure is not a test failure.
        }
      });
      Future<void> git(String cwd, List<String> args) async {
        final result = await Process.run('git', args, workingDirectory: cwd);
        if (result.exitCode != 0) {
          throw StateError('git ${args.join(' ')} failed: ${result.stderr}');
        }
      }

      final originDir = p.join(parent.path, 'origin.git');
      await git(parent.path, ['init', '--bare', '-b', 'main', originDir]);
      final repoPath = p.join(parent.path, 'repo');
      await git(parent.path, ['clone', originDir, repoPath]);
      await git(repoPath, ['config', 'user.email', 'test@example.com']);
      await git(repoPath, ['config', 'user.name', 'Test User']);
      File(p.join(repoPath, 'a.txt')).writeAsStringSync('v1\n');
      await git(repoPath, ['add', '-A']);
      await git(repoPath, ['commit', '-m', 'init']);
      await git(repoPath, ['push', '-u', 'origin', 'main']);

      final project = Project.fromJson((j(await client.peer
              .call('projects.add', <String, Object?>{'path': repoPath}))[
                  'project']! as Map)
          .cast<String, Object?>());
      final worktree = Session.fromJson((j(await client.peer
              .call('sessions.create', <String, Object?>{
            'projectId': project.id,
            'providerId': 'fake',
            'title': 'Worktree session',
            'baseBranch': 'main',
          }))['session']! as Map)
          .cast<String, Object?>());
      final plain = Session.fromJson((j(await client.peer.call(
              'sessions.create', <String, Object?>{
            'projectId': project.id,
            'providerId': 'fake',
            'title': 'Plain session',
          }))['session']! as Map)
          .cast<String, Object?>());

      Future<Map<String, SessionGitSummary>> summaries() async {
        final result = j(await client.peer.call('git.sessionSummaries',
            <String, Object?>{'projectId': project.id}));
        final list = (result['summaries']! as List)
            .map((e) => SessionGitSummary.fromJson(
                (e! as Map).cast<String, Object?>()))
            .toList();
        return <String, SessionGitSummary>{
          for (final s in list) s.sessionId: s,
        };
      }

      // Fresh: worktree session is clean/ahead 0/not merged; the plain
      // session only carries dirty (it has no base branch).
      var map = await summaries();
      expect(map, hasLength(2));
      expect(map[worktree.id]!.dirty, isFalse);
      expect(map[worktree.id]!.aheadOfBase, 0);
      expect(map[worktree.id]!.mergedIntoBase, isFalse);
      expect(map[plain.id]!.dirty, isFalse);
      expect(map[plain.id]!.aheadOfBase, isNull);
      expect(map[plain.id]!.mergedIntoBase, isNull);

      // A commit in the worktree reads as ahead-of-base; an edit in the
      // project checkout flags the plain session dirty. The commit is made
      // directly (not via git.commit) with a future committer date: the
      // merged check compares the tip's committer time against the session's
      // createdAt, and both would otherwise land in the same wall-clock
      // second, making the merged assertion racy.
      File(p.join(worktree.cwd, 'feat.txt')).writeAsStringSync('f\n');
      await git(worktree.cwd, ['add', '-A']);
      final future =
          '@${(DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3600} +0000';
      await Process.run(
        'git',
        ['commit', '-m', 'session work'],
        workingDirectory: worktree.cwd,
        environment: <String, String>{'GIT_COMMITTER_DATE': future},
      );
      File(p.join(worktree.cwd, 'wip.txt')).writeAsStringSync('x\n');
      File(p.join(repoPath, 'wip.txt')).writeAsStringSync('x\n');

      map = await summaries();
      expect(map[worktree.id]!.aheadOfBase, 1);
      expect(map[worktree.id]!.mergedIntoBase, isFalse);
      expect(map[worktree.id]!.dirty, isTrue);
      expect(map[plain.id]!.dirty, isTrue);

      // Undo the worktree edit, merge, and the session reads merged.
      File(p.join(worktree.cwd, 'wip.txt')).deleteSync();
      await client.peer.call('git.mergeToBase', <String, Object?>{
        'projectId': project.id,
        'sessionId': worktree.id,
      });

      map = await summaries();
      expect(map[worktree.id]!.aheadOfBase, 0);
      expect(map[worktree.id]!.mergedIntoBase, isTrue);
      expect(map[worktree.id]!.dirty, isFalse);

      // Archived sessions drop out of the batch.
      await client.peer.call('sessions.archive', <String, Object?>{
        'sessionId': plain.id,
        'archived': true,
      });
      map = await summaries();
      expect(map, hasLength(1));
      expect(map.containsKey(worktree.id), isTrue);

      // Unknown project → kErrNotFound.
      await expectLater(
        client.peer.call(
            'git.sessionSummaries', <String, Object?>{'projectId': 'nope'}),
        throwsA(
            isA<DaemonError>().having((e) => e.code, 'code', kErrNotFound)),
      );
      await client.close();
    });
  });

  group('fs', () {
    test('fs.list / fs.read: confinement, binary detection, truncation',
        () async {
      await startServer();
      final client = await connect(server!.port);
      final dir = await Directory.systemTemp.createTemp('sd_fs_');
      Directory(p.join(dir.path, 'sub')).createSync();
      Directory(p.join(dir.path, '.git')).createSync();
      File(p.join(dir.path, 'alpha.txt')).writeAsStringSync('alpha');
      File(p.join(dir.path, 'zebra.txt')).writeAsStringSync('zebra');
      File(p.join(dir.path, 'sub', 'inner.txt')).writeAsStringSync('inner');
      final project = Project.fromJson((j(await client.peer
                  .call('projects.add', <String, Object?>{'path': dir.path}))[
              'project']! as Map)
          .cast<String, Object?>());

      // Root listing: docs first, names ascending, .git skipped.
      final listing = j(await client.peer
          .call('fs.list', <String, Object?>{'projectId': project.id}));
      final entries = (listing['entries']! as List<Object?>)
          .map((e) => FileEntry.fromJson((e! as Map).cast<String, Object?>()))
          .toList();
      expect(
        entries.map((e) => e.name).toList(),
        <String>['sub', 'alpha.txt', 'zebra.txt'],
      );
      expect(entries.first.isDir, isTrue);
      expect(entries.first.path, 'sub');

      // Nested listing reports root-relative paths.
      final nested = j(await client.peer.call('fs.list',
          <String, Object?>{'projectId': project.id, 'path': 'sub'}));
      final inner = FileEntry.fromJson(
          (((nested['entries']! as List<Object?>).single! as Map)
              .cast<String, Object?>()));
      expect(inner.name, 'inner.txt');
      expect(inner.path, 'sub/inner.txt');
      expect(inner.isDir, isFalse);
      expect(inner.size, 5);

      // Escapes and absolute paths are invalid params.
      for (final path in <String>['..', '../outside.txt', '/etc/hostname']) {
        await expectLater(
          client.peer.call('fs.list',
              <String, Object?>{'projectId': project.id, 'path': path}),
          throwsA(isA<DaemonError>()
              .having((e) => e.code, 'code', -32602)),
          reason: 'expected -32602 for $path',
        );
      }

      // Read a small file verbatim.
      final read = j(await client.peer.call('fs.read',
          <String, Object?>{'projectId': project.id, 'path': 'alpha.txt'}));
      expect(read['content'], 'alpha');
      expect(read['truncated'], isFalse);
      expect(read['isBinary'], isFalse);

      // Binary detection via a NUL byte in the probe window.
      File(p.join(dir.path, 'bin.dat'))
          .writeAsBytesSync(<int>[0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]);
      final binary = j(await client.peer.call('fs.read',
          <String, Object?>{'projectId': project.id, 'path': 'bin.dat'}));
      expect(binary['content'], '');
      expect(binary['isBinary'], isTrue);
      expect(binary['truncated'], isFalse);

      // Truncation at the default 512 KiB cap.
      File(p.join(dir.path, 'big.txt')).writeAsStringSync('x' * (600 * 1024));
      final big = j(await client.peer.call('fs.read',
          <String, Object?>{'projectId': project.id, 'path': 'big.txt'}));
      expect((big['content']! as String), hasLength(512 * 1024));
      expect(big['truncated'], isTrue);
      expect(big['isBinary'], isFalse);

      // The 4 MiB hard cap clamps an over-large maxBytes request.
      File(p.join(dir.path, 'huge.txt'))
          .writeAsStringSync('y' * (5 * 1024 * 1024));
      final huge = j(await client.peer.call('fs.read', <String, Object?>{
        'projectId': project.id,
        'path': 'huge.txt',
        'maxBytes': 8 * 1024 * 1024,
      }));
      expect((huge['content']! as String), hasLength(4 * 1024 * 1024));
      expect(huge['truncated'], isTrue);

      // Missing files/dirs are invalid params.
      await expectLater(
        client.peer.call('fs.read',
            <String, Object?>{'projectId': project.id, 'path': 'missing.txt'}),
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', -32602)),
      );
      await expectLater(
        client.peer.call('fs.read',
            <String, Object?>{'projectId': project.id, 'path': '.'}),
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', -32602)),
      );

      // Unknown projects are not found.
      await expectLater(
        client.peer.call('fs.list',
            <String, Object?>{'projectId': 'missing-project'}),
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', kErrNotFound)),
      );

      await client.close();
    });
  });

  group('git', () {
    test('status/commit work against a temp repo behind the wire', () async {
      await startServer();
      final client = await connect(server!.port);
      final repo = await _initRepo();
      await _write(repo, 'file.txt', 'hello');

      await client.peer
          .call('projects.add', <String, Object?>{'path': repo.path});
      final projectId = ((j(await client.peer.call('projects.list'))[
                  'projects']! as List<Object?>)
              .single! as Map)['id']! as String;

      final status = j(await client.peer
          .call('git.status', <String, Object?>{'projectId': projectId}));
      final parsed =
          GitStatus.fromJson((status['status']! as Map).cast<String, Object?>());
      expect(parsed.branch, 'main');
      expect(parsed.files, hasLength(1));
      expect(parsed.files.first.path, 'file.txt');

      final commit = j(await client.peer.call('git.commit', <String, Object?>{
        'projectId': projectId,
        'message': 'initial',
        'stageAll': true,
      }));
      expect(commit['commitHash']! as String, isNotEmpty);

      final clean = j(await client.peer
          .call('git.status', <String, Object?>{'projectId': projectId}));
      expect(
        GitStatus.fromJson(
                (clean['status']! as Map).cast<String, Object?>())
            .files,
        isEmpty,
      );

      // Unknown project → kErrNotFound.
      await expectLater(
        client.peer.call('git.status', <String, Object?>{'projectId': 'nope'}),
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', kErrNotFound)),
      );

      await client.close();
    });
  });

  group('wire', () {
    test('unknown method → -32601', () async {
      await startServer();
      final client = await connect(server!.port);

      await expectLater(
        client.peer.call('bogus.method'),
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', -32601)),
      );

      await client.close();
    });
  });

  group('origin', () {
    test('rejects cross-origin upgrades with 403; loopback and absent '
        'origins pass', () async {
      await startServer();
      final port = server!.port;

      // No Origin header (non-browser CLI-style client): allowed.
      final plain = await WebSocket.connect('ws://127.0.0.1:$port/ws');
      await plain.close();

      // Loopback Origin: allowed.
      final loopback = await WebSocket.connect('ws://127.0.0.1:$port/ws',
          headers: {'origin': 'http://localhost:7331'});
      await loopback.close();

      // Non-loopback Origin: rejected with 403 before the upgrade.
      final client = HttpClient();
      try {
        final request = await client.getUrl(
            Uri.parse('http://127.0.0.1:$port/ws'));
        request.headers.set(HttpHeaders.connectionHeader, 'Upgrade');
        request.headers.set(HttpHeaders.upgradeHeader, 'websocket');
        request.headers.set('sec-websocket-key', 'dGhlIHNhbXBsZSBub25jZQ==');
        request.headers.set('sec-websocket-version', '13');
        request.headers.set('origin', 'http://evil.example');
        final response = await request.close();
        expect(response.statusCode, HttpStatus.forbidden,
            reason: 'cross-origin WebSocket upgrades must be refused with 403');
        await response.drain<void>();
      } finally {
        client.close(force: true);
      }

      // An opaque origin ("null", e.g. sandboxed iframes) is not loopback.
      final nullOrigin = HttpClient();
      try {
        final request = await nullOrigin.getUrl(
            Uri.parse('http://127.0.0.1:$port/ws'));
        request.headers.set(HttpHeaders.connectionHeader, 'Upgrade');
        request.headers.set(HttpHeaders.upgradeHeader, 'websocket');
        request.headers.set('sec-websocket-key', 'dGhlIHNhbXBsZSBub25jZQ==');
        request.headers.set('sec-websocket-version', '13');
        request.headers.set('origin', 'null');
        final response = await request.close();
        expect(response.statusCode, HttpStatus.forbidden);
        await response.drain<void>();
      } finally {
        nullOrigin.close(force: true);
      }
    });
  });

  group('notifications', () {
    test('session lifecycle events fan out to every authenticated client',
        () async {
      await startServer();
      final a = await connect(server!.port);
      final b = await connect(server!.port);
      final dir = await Directory.systemTemp.createTemp('sd_fanout_');
      File(p.join(dir.path, 'example.txt'))
          .writeAsStringSync('hello from file\n');
      final project = Project.fromJson((j(await a.peer
                  .call('projects.add', <String, Object?>{'path': dir.path}))[
              'project']! as Map)
          .cast<String, Object?>());

      final created = j(await a.peer.call('sessions.create',
          <String, Object?>{
            'projectId': project.id,
            'providerId': 'fake',
          }));
      final sessionId = (created['session']! as Map)['id']! as String;
      await untilRecorded(a, 'session.created', 1);
      await untilRecorded(b, 'session.created', 1);
      expect(a.of('session.created'), hasLength(1));
      expect(b.of('session.created'), hasLength(1),
          reason: 'creation announces to all clients');

      // Both clients observe the full turn, parking at the permission.
      final bPermission =
          waitForEvent(b, (event) => event is PermissionRequestEvent);
      final aPermission =
          waitForEvent(a, (event) => event is PermissionRequestEvent);
      final send = a.peer.call('sessions.send',
          <String, Object?>{'sessionId': sessionId, 'text': 'inspect'});

      final requestId = (SessionEvent.fromJson(((await bPermission)[
                      'event']! as Map)
                  .cast<String, Object?>())
              as PermissionRequestEvent)
          .request
          .requestId;
      await aPermission;
      await a.peer.call('sessions.respondPermission', <String, Object?>{
        'sessionId': sessionId,
        'requestId': requestId,
        'optionId': 'allow',
      });
      await send;

      // The turn's tail (usage, turnComplete) is emitted asynchronously after
      // the sessions.send response; wait for both clients' recorders to have
      // all 10 events before counting.
      await untilRecorded(a, 'session.event', 10);
      await untilRecorded(b, 'session.event', 10);

      expect(a.of('session.event'), hasLength(10));
      expect(b.of('session.event'), hasLength(10));

      // Metadata updates and removals propagate to both as well. These are
      // engine-stream broadcasts (not request-handler writes), so poll the
      // recorders rather than assuming the response implies delivery.
      await a.peer.call('sessions.archive',
          <String, Object?>{'sessionId': sessionId, 'archived': true});
      await untilRecorded(a, 'session.updated', 1);
      await untilRecorded(b, 'session.updated', 1);
      expect(a.of('session.updated'), isNotEmpty);
      expect(b.of('session.updated'), isNotEmpty);

      await a.peer
          .call('sessions.delete', <String, Object?>{'sessionId': sessionId});
      await untilRecorded(a, 'session.removed', 1);
      await untilRecorded(b, 'session.removed', 1);
      expect(a.of('session.removed'), hasLength(1));
      expect(b.of('session.removed'), hasLength(1));

      await a.close();
      await b.close();
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('a fresh observer sees session.created before any session.updated '
        'for a new session', () async {
      await startServer();
      final a = await connect(server!.port);
      final fresh = await connect(server!.port);
      final dir = await Directory.systemTemp.createTemp('sd_created_first_');
      final project = Project.fromJson((j(await a.peer.call('projects.add',
                  <String, Object?>{'path': dir.path}))['project']! as Map)
          .cast<String, Object?>());

      final created = j(await a.peer.call('sessions.create',
          <String, Object?>{
            'projectId': project.id,
            'providerId': 'fake',
          }));
      final sessionId = (created['session']! as Map)['id']! as String;

      // Wait for created to arrive on the fresh observer, then trigger a
      // session.updated (rename) and confirm the ordering holds.
      await untilRecorded(fresh, 'session.created', 1);
      await a.peer.call('sessions.rename',
          <String, Object?>{'sessionId': sessionId, 'title': 'Renamed'});
      await untilRecorded(fresh, 'session.updated', 1);

      final order = fresh.notifications
          .where((n) =>
              (n.method == 'session.created' ||
                  n.method == 'session.updated') &&
              n.params['session'] is Map &&
              (n.params['session']! as Map)['id'] == sessionId)
          .map((n) => n.method)
          .toList();
      expect(order, isNotEmpty);
      expect(order, contains('session.updated'),
          reason: 'the rename update must arrive at all');
      expect(order.first, 'session.created',
          reason: 'the relay must not emit session.updated for a session '
              'before its session.created has been broadcast');

      await a.close();
      await fresh.close();
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
