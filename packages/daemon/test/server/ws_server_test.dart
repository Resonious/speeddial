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
    Directory.current.path,
    'packages',
    'daemon',
    'test',
    'fixtures',
    'fake_acp_agent.dart',
  ),
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
  final StreamController<Object?> _incoming = StreamController<Object?>(
    sync: true,
  );
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

Map<String, String> mcpEnvironment(Map<String, Object?> config) {
  final Map<String, String> environment = <String, String>{};
  for (final Object? raw in config['env']! as List<Object?>) {
    final Map<String, Object?> entry = (raw! as Map).cast<String, Object?>();
    environment[entry['name']! as String] = entry['value']! as String;
  }
  return environment;
}

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
      throw TimeoutException(
        'expected $count x $method',
        const Duration(seconds: 10),
      );
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
    final result = await Process.run('git', args, workingDirectory: dir.path);
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

  Future<SpeedDialServer> startServer({
    String? authToken,
    Duration gitPollInterval = const Duration(seconds: 15),
    Duration gitFetchInterval = const Duration(minutes: 2),
  }) async {
    engine = SessionEngine(
      store: store,
      providers: providers,
      git: GitService(),
    );
    await engine!.restore();
    server = await SpeedDialServer.bind(
      host: '127.0.0.1',
      port: 0,
      engine: engine!,
      store: store,
      providers: providers,
      authToken: authToken,
      gitPollInterval: gitPollInterval,
      gitFetchInterval: gitFetchInterval,
    );
    return server!;
  }

  group('auth', () {
    test(
      'unauthenticated requests are gated until auth.authenticate',
      () async {
        await startServer(authToken: 'secret');
        final client = await connect(server!.port);

        // Everything except auth.authenticate / daemon.info is gated.
        await expectLater(
          client.peer.call('projects.list'),
          throwsA(
            isA<DaemonError>().having(
              (e) => e.code,
              'code',
              kErrUnauthenticated,
            ),
          ),
        );
        await expectLater(
          client.peer.call('sessions.list'),
          throwsA(
            isA<DaemonError>().having(
              (e) => e.code,
              'code',
              kErrUnauthenticated,
            ),
          ),
        );

        // daemon.info is pre-auth enabled and reports authRequired.
        final info = DaemonInfo.fromJson(
          j(await client.peer.call('daemon.info')),
        );
        expect(info.authRequired, isTrue);
        expect(info.protocolVersion, 1);
        expect(info.providers.map((p) => p.id), contains('fake'));

        // A wrong token fails with the exact PROTOCOL.md message.
        await expectLater(
          client.peer.call('auth.authenticate', <String, Object?>{
            'token': 'wrong-token',
          }),
          throwsA(
            isA<DaemonError>()
                .having((e) => e.code, 'code', kErrUnauthenticated)
                .having((e) => e.message, 'message', 'invalid token'),
          ),
        );

        // The right token unlocks the API.
        final auth = j(
          await client.peer.call('auth.authenticate', <String, Object?>{
            'token': 'secret',
          }),
        );
        expect(auth['ok'], isTrue);
        expect((auth['daemon']! as Map)['authRequired'], isTrue);
        final projects = j(await client.peer.call('projects.list'));
        expect(projects['projects'], isEmpty);

        await client.close();
      },
    );

    test('daemon.info reports authRequired false without a token', () async {
      await startServer();
      final client = await connect(server!.port);

      final info = DaemonInfo.fromJson(
        j(await client.peer.call('daemon.info')),
      );
      expect(info.authRequired, isFalse);
      expect(info.providers.map((p) => p.id), contains('fake'));
      expect(info.providers.firstWhere((p) => p.id == 'fake').models, <String>[
        'fake-fast',
        'fake-smart',
      ]);

      await client.close();
    });
  });

  group('projects', () {
    test('add validates, rename round-trips, remove detaches', () async {
      await startServer();
      final client = await connect(server!.port);
      final dir = await Directory.systemTemp.createTemp('sd_proj_');

      // Add with an explicit name.
      final added = j(
        await client.peer.call('projects.add', <String, Object?>{
          'path': dir.path,
          'name': 'Demo',
        }),
      );
      final project = Project.fromJson(
        (added['project']! as Map).cast<String, Object?>(),
      );
      expect(project.name, 'Demo');
      expect(project.path, p.normalize(dir.path));

      // Non-directory and missing params are invalid.
      await expectLater(
        client.peer.call('projects.add', <String, Object?>{
          'path': p.join(dir.path, 'nope'),
        }),
        throwsA(isA<DaemonError>().having((e) => e.code, 'code', -32602)),
      );
      await expectLater(
        client.peer.call('projects.add', <String, Object?>{}),
        throwsA(isA<DaemonError>().having((e) => e.code, 'code', -32602)),
      );

      // Duplicate path conflicts.
      await expectLater(
        client.peer.call('projects.add', <String, Object?>{
          'path': dir.path,
          'name': 'Again',
        }),
        throwsA(isA<DaemonError>().having((e) => e.code, 'code', kErrConflict)),
      );

      // Rename updates the name; unknown ids are not found.
      final renamed = j(
        await client.peer.call('projects.rename', <String, Object?>{
          'id': project.id,
          'name': 'Renamed',
        }),
      );
      expect(
        Project.fromJson((renamed['project']! as Map).cast<String, Object?>())
            .name,
        'Renamed',
      );
      await expectLater(
        client.peer.call('projects.rename', <String, Object?>{
          'id': 'missing',
          'name': 'X',
        }),
        throwsA(isA<DaemonError>().having((e) => e.code, 'code', kErrNotFound)),
      );

      // List reflects the rename.
      final listed = j(await client.peer.call('projects.list'));
      final projects = (listed['projects']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(projects, hasLength(1));
      expect(projects.single['name'], 'Renamed');

      // Remove detaches the project.
      await client.peer.call('projects.remove', <String, Object?>{
        'id': project.id,
      });
      expect(
        (j(await client.peer.call('projects.list'))['projects']! as List),
        isEmpty,
      );
      await expectLater(
        client.peer.call('projects.remove', <String, Object?>{
          'id': project.id,
        }),
        throwsA(isA<DaemonError>().having((e) => e.code, 'code', kErrNotFound)),
      );

      await untilRecorded(client, 'projects.changed', 3);
      final changed = client.of('projects.changed');
      expect(
        changed,
        hasLength(greaterThanOrEqualTo(3)),
        reason: 'add, rename, and remove each announce projects.changed',
      );
      await client.close();
    });
  });

  group('sessions', () {
    test(
      'full lifecycle: create, send, ordered events, permission, history',
      () async {
        await startServer();
        final client = await connect(server!.port);
        final dir = await Directory.systemTemp.createTemp('sd_session_');
        File(p.join(dir.path, 'example.txt'))
            .writeAsStringSync('hello from file\n');
        final project = Project.fromJson(
          (j(
                    await client.peer.call('projects.add', <String, Object?>{
                      'path': dir.path,
                    }),
                  )['project']!
                  as Map)
              .cast<String, Object?>(),
        );

        // Create spawns an idle session and announces session.created.
        final created = j(
          await client.peer.call('sessions.create', <String, Object?>{
            'projectId': project.id,
            'providerId': 'fake',
            'mode': 'build',
            'title': 'Lifecycle',
          }),
        );
        final session = Session.fromJson(
          (created['session']! as Map).cast<String, Object?>(),
        );
        expect(session.status, SessionStatus.idle);
        expect(session.title, 'Lifecycle');
        expect(session.mode, SessionMode.build);
        expect(session.yolo, isFalse, reason: 'yolo defaults off');
        await untilRecorded(client, 'session.created', 1);
        expect(client.of('session.created'), hasLength(1));

        // Start a turn; it parks at the permission request until resolved.
        final permissionFuture = waitForEvent(
          client,
          (event) => event is PermissionRequestEvent,
        );
        final send = client.peer.call('sessions.send', <String, Object?>{
          'sessionId': session.id,
          'text': 'inspect',
        });
        // sessions.send resolves at turn start (PROTOCOL.md): the response
        // arrives once the userMessage is persisted and the session is
        // running, while the turn parks at the permission request.
        await send;

        final requestParams = await permissionFuture;
        final request = ((requestParams['event']! as Map)['request']! as Map)
            .cast<String, Object?>();
        expect(request['toolCallId'], 'tc1');
        expect(request['title'], 'Read example.txt');

        // The turn is parked (not yet complete) until we respond.
        expect(
          client.of('session.event').length,
          lessThan(10),
          reason: 'the turn is parked until respondPermission',
        );

        await client.peer.call('sessions.respondPermission', <String, Object?>{
          'sessionId': session.id,
          'requestId': request['requestId']! as String,
          'optionId': 'allow',
        });

        // All ten events arrived in the order the agent produced them. The
        // turn's tail (usage, turnComplete) is emitted asynchronously after the
        // response, so poll the recorder before counting.
        await untilRecorded(client, 'session.event', 10);
        final events = client
            .of('session.event')
            .map(
              (n) => SessionEvent.fromJson(
                (n.params['event']! as Map).cast<String, Object?>(),
              ),
            )
            .toList();
        expect(events.map((e) => e.runtimeType).toList(), <Type>[
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
        ]);
        for (var i = 0; i < events.length; i++) {
          expect(events[i].seq, i + 1, reason: 'seq is assigned 1..N');
        }
        expect((events.last as TurnCompleteEvent).stopReason, 'end_turn');
        final resolved = events[7] as PermissionResolvedEvent;
        expect(resolved.requestId, request['requestId']);
        expect(resolved.optionId, 'allow');

        // History replays the same events; paging honours limit/beforeSeq.
        final history = j(
          await client.peer.call('sessions.history', <String, Object?>{
            'sessionId': session.id,
          }),
        );
        final replayed = (history['events']! as List<Object?>)
            .map(
              (e) => SessionEvent.fromJson((e! as Map).cast<String, Object?>()),
            )
            .toList();
        expect(replayed, hasLength(events.length));
        expect(replayed.map((e) => e.seq), events.map((e) => e.seq));
        expect(history['hasMore'], isFalse);
        final page = j(
          await client.peer.call('sessions.history', <String, Object?>{
            'sessionId': session.id,
            'limit': 4,
            'beforeSeq': 10,
          }),
        );
        expect(
          (page['events']! as List<Object?>).map((e) => (e! as Map)['seq']),
          <Object?>[6, 7, 8, 9],
        );
        expect(page['hasMore'], isTrue);
        await expectLater(
          client.peer.call('sessions.history', <String, Object?>{
            'sessionId': 'nope',
          }),
          throwsA(
            isA<DaemonError>().having((e) => e.code, 'code', kErrNotFound),
          ),
        );

        // Metadata changes persist and broadcast session.updated.
        final renamed = j(
          await client.peer.call('sessions.rename', <String, Object?>{
            'sessionId': session.id,
            'title': 'Renamed',
          }),
        );
        expect(
          Session.fromJson((renamed['session']! as Map).cast<String, Object?>())
              .title,
          'Renamed',
        );
        await untilRecorded(client, 'session.updated', 1);
        expect(client.of('session.updated'), isNotEmpty);

        final modeChanged = j(
          await client.peer.call('sessions.setMode', <String, Object?>{
            'sessionId': session.id,
            'mode': 'plan',
          }),
        );
        expect(
          Session.fromJson(
            (modeChanged['session']! as Map).cast<String, Object?>(),
          ).mode,
          SessionMode.plan,
        );
        await expectLater(
          client.peer.call('sessions.setMode', <String, Object?>{
            'sessionId': session.id,
            'mode': 'bogus',
          }),
          throwsA(isA<DaemonError>().having((e) => e.code, 'code', -32602)),
        );

        final thinkingChanged = j(
          await client.peer.call('sessions.setThinkingLevel', <String, Object?>{
            'sessionId': session.id,
            'level': 'high',
          }),
        );
        expect(
          Session.fromJson(
            (thinkingChanged['session']! as Map).cast<String, Object?>(),
          ).thinkingLevel,
          'high',
        );
        await expectLater(
          client.peer.call('sessions.setThinkingLevel', <String, Object?>{
            'sessionId': session.id,
            'level': 'bogus',
          }),
          throwsA(isA<DaemonError>().having((e) => e.code, 'code', -32602)),
        );

        // Archiving hides the session from the default list.
        expect(
          (j(
                await client.peer.call('sessions.list', <String, Object?>{}),
              )['sessions']!
              as List),
          hasLength(1),
        );
        await client.peer.call('sessions.archive', <String, Object?>{
          'sessionId': session.id,
          'archived': true,
        });
        expect(
          (j(
                await client.peer.call('sessions.list', <String, Object?>{}),
              )['sessions']!
              as List),
          isEmpty,
        );
        final withArchived = j(
          await client.peer.call('sessions.list', <String, Object?>{
            'includeArchived': true,
          }),
        );
        final archived =
            ((withArchived['sessions']! as List<Object?>).single! as Map)
                .cast<String, Object?>();
        expect(archived['archived'], isTrue);

        // Delete removes the session and announces session.removed.
        await client.peer.call('sessions.delete', <String, Object?>{
          'sessionId': session.id,
        });
        await untilRecorded(client, 'session.removed', 1);
        expect(client.of('session.removed'), hasLength(1));
        await expectLater(
          client.peer.call('sessions.delete', <String, Object?>{
            'sessionId': session.id,
          }),
          throwsA(
            isA<DaemonError>().having((e) => e.code, 'code', kErrNotFound),
          ),
        );

        await client.close();
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test('sessions.fork returns and announces a copied session', () async {
      await startServer();
      final client = await connect(server!.port);
      final dir = await Directory.systemTemp.createTemp('sd_fork_');
      File(p.join(dir.path, 'example.txt')).writeAsStringSync('hello\n');
      final project = Project.fromJson(
        (j(
                  await client.peer.call('projects.add', <String, Object?>{
                    'path': dir.path,
                  }),
                )['project']!
                as Map)
            .cast<String, Object?>(),
      );
      final source = Session.fromJson(
        (j(
                  await client.peer.call('sessions.create', <String, Object?>{
                    'projectId': project.id,
                    'providerId': 'fake',
                    'title': 'Source',
                  }),
                )['session']!
                as Map)
            .cast<String, Object?>(),
      );
      store.appendEvent(
        source.id,
        1,
        const UserMessageEvent(text: 'Fork here'),
      );
      store.appendEvent(
        source.id,
        2,
        const AgentMessageChunkEvent(text: 'Not included'),
      );

      final result = j(
        await client.peer.call('sessions.fork', <String, Object?>{
          'sessionId': source.id,
          'seq': 1,
        }),
      );
      final fork = Session.fromJson(
        (result['session']! as Map).cast<String, Object?>(),
      );
      expect(fork.id, isNot(source.id));
      expect(fork.title, 'Fork of Source');
      await untilRecorded(client, 'session.created', 2);

      final history = j(
        await client.peer.call('sessions.history', <String, Object?>{
          'sessionId': fork.id,
        }),
      );
      final events = (history['events']! as List<Object?>)
          .map(
            (Object? raw) =>
                SessionEvent.fromJson((raw! as Map).cast<String, Object?>()),
          )
          .toList(growable: false);
      expect(events, hasLength(1));
      expect(
        events.single,
        isA<UserMessageEvent>().having(
          (UserMessageEvent event) => event.text,
          'text',
          'Fork here',
        ),
      );

      await expectLater(
        client.peer.call('sessions.fork', <String, Object?>{
          'sessionId': source.id,
          'seq': 3,
        }),
        throwsA(
          isA<DaemonError>().having(
            (DaemonError error) => error.code,
            'code',
            -32602,
          ),
        ),
      );
      await client.close();
    });

    test('MCP profiles are redacted and injected into new sessions', () async {
      await startServer();
      final WsClient client = await connect(server!.port);
      final Map<String, Object?> created = j(
        await client.peer.call('mcp.create', <String, Object?>{
          'name': 'filesystem',
          'transport': 'stdio',
          'enabled': true,
          'command': '/bin/filesystem-mcp',
          'args': <String>['--stdio'],
          'secrets': <String, String>{'API_TOKEN': 'top-secret'},
        }),
      );
      final String profileId = (created['server']! as Map)['id']! as String;
      final Map<String, Object?> listing = j(
        await client.peer.call('mcp.list'),
      );
      expect(listing.toString(), isNot(contains('top-secret')));
      expect(
        (((listing['servers']! as List).single as Map)['secretNames'] as List),
        const <String>['API_TOKEN'],
      );

      final Directory dir = Directory(p.join(tempDir.path, 'managed-mcp'))
        ..createSync();
      File(p.join(dir.path, 'agent.capture_mcp')).writeAsStringSync('');
      final Map<String, Object?> project = j(
        await client.peer.call('projects.add', <String, Object?>{
          'path': dir.path,
          'name': 'Managed MCP',
        }),
      );
      final String projectId = (project['project']! as Map)['id']! as String;
      await client.peer.call('sessions.create', <String, Object?>{
        'projectId': projectId,
        'providerId': 'fake',
      });
      final List<Object?> configs = jsonDecode(
        File(p.join(dir.path, 'agent.mcp_servers')).readAsStringSync(),
      ) as List<Object?>;
      final Map<String, Object?> managed = configs
          .whereType<Map>()
          .map((Map config) => config.cast<String, Object?>())
          .singleWhere(
            (Map<String, Object?> config) => config['name'] == 'filesystem',
          );
      expect(managed['command'], '/bin/filesystem-mcp');
      expect(managed['args'], const <String>['--stdio']);
      expect(mcpEnvironment(managed)['API_TOKEN'], 'top-secret');

      await client.peer.call('mcp.update', <String, Object?>{
        'id': profileId,
        'name': 'filesystem',
        'transport': 'stdio',
        'enabled': false,
        'command': '/bin/filesystem-mcp',
        'args': <String>['--stdio'],
        'removeSecretNames': <String>['API_TOKEN'],
      });
      final Map<String, Object?> updated = j(
        await client.peer.call('mcp.list'),
      );
      expect(
        ((updated['servers']! as List).single as Map)['secretNames'],
        isEmpty,
      );
      await client.peer.call('mcp.delete', <String, Object?>{'id': profileId});
      expect(
        (j(await client.peer.call('mcp.list'))['servers']! as List),
        isEmpty,
      );
      await client.close();
    });

    test('built-in MCP bridge is session-bound and displays images', () async {
      await startServer();
      final WsClient client = await connect(server!.port);
      final Directory dir = Directory(p.join(tempDir.path, 'mcp-project'))
        ..createSync();
      File(p.join(dir.path, 'agent.capture_mcp')).writeAsStringSync('');
      final Project project = Project.fromJson(
        (j(
                  await client.peer.call('projects.add', <String, Object?>{
                    'path': dir.path,
                    'name': 'MCP Project',
                  }),
                )['project']!
                as Map)
            .cast<String, Object?>(),
      );
      final Session owner = Session.fromJson(
        (j(
                  await client.peer.call('sessions.create', <String, Object?>{
                    'projectId': project.id,
                    'providerId': 'fake',
                    'title': 'Owning session',
                  }),
                )['session']!
                as Map)
            .cast<String, Object?>(),
      );
      final List<Object?> configs = jsonDecode(
        File(p.join(dir.path, 'agent.mcp_servers')).readAsStringSync(),
      ) as List<Object?>;
      final Map<String, Object?> config = (configs.single! as Map)
          .cast<String, Object?>();
      final Map<String, String> environment = mcpEnvironment(config);

      final Session other = Session.fromJson(
        (j(
                  await client.peer.call('sessions.create', <String, Object?>{
                    'projectId': project.id,
                    'providerId': 'fake',
                    'title': 'Searchable release notes',
                  }),
                )['session']!
                as Map)
            .cast<String, Object?>(),
      );
      final List<Object?> otherConfigs = jsonDecode(
        File(p.join(dir.path, 'agent.mcp_servers')).readAsStringSync(),
      ) as List<Object?>;
      final Map<String, String> otherEnvironment = mcpEnvironment(
        (otherConfigs.single! as Map).cast<String, Object?>(),
      );
      expect(
        otherEnvironment['SPEEDDIAL_MCP_SECRET'],
        isNot(environment['SPEEDDIAL_MCP_SECRET']),
      );
      final WsClient mcp = await connect(server!.port);
      final Map<String, Object?> authenticated = j(
        await mcp.peer.call('internal.mcpAuthenticate', <String, Object?>{
          'secret': environment['SPEEDDIAL_MCP_SECRET'],
          'sessionId': owner.id,
        }),
      );
      expect(authenticated['ok'], isTrue);
      final WsClient crossSession = await connect(server!.port);
      await expectLater(
        crossSession.peer.call('internal.mcpAuthenticate', <String, Object?>{
          'secret': environment['SPEEDDIAL_MCP_SECRET'],
          'sessionId': other.id,
        }),
        throwsA(
          isA<DaemonError>().having(
            (DaemonError error) => error.code,
            'code',
            kErrUnauthenticated,
          ),
        ),
      );
      await crossSession.close();
      await expectLater(
        mcp.peer.call('projects.list'),
        throwsA(
          isA<DaemonError>().having(
            (DaemonError error) => error.code,
            'code',
            kErrUnauthenticated,
          ),
        ),
      );

      final Map<String, Object?> projects = j(
        await mcp.peer.call('internal.mcpSearchProjects', <String, Object?>{
          'query': 'mcp',
        }),
      );
      expect(projects['projects'], hasLength(1));
      final Map<String, Object?> sessions = j(
        await mcp.peer.call('internal.mcpSearchSessions', <String, Object?>{
          'query': 'release',
          'limit': 20,
        }),
      );
      final List<Object?> matches = sessions['sessions']! as List<Object?>;
      expect(matches, hasLength(1));
      expect((matches.single! as Map)['title'], 'Searchable release notes');

      const String imageData =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';
      await mcp.peer.call('internal.mcpDisplayImage', <String, Object?>{
        'name': 'result.png',
        'mimeType': 'image/png',
        'data': imageData,
      });
      await untilRecorded(client, 'session.event', 1);
      final Map<String, Object?> history = j(
        await client.peer.call('sessions.history', <String, Object?>{
          'sessionId': owner.id,
        }),
      );
      final ImageEvent image = SessionEvent.fromJson(
        ((history['events']! as List<Object?>).single! as Map)
            .cast<String, Object?>(),
      ) as ImageEvent;
      expect(image.attachment.name, 'result.png');
      final Map<String, Object?> attachment = j(
        await client.peer.call('attachments.read', <String, Object?>{
          'sessionId': owner.id,
          'attachmentId': image.attachment.id,
        }),
      );
      expect((attachment['attachment']! as Map)['data'], imageData);

      await mcp.close();
      await client.close();
    });

    test(
      'built-in MCP stdio subprocess serves tools through the daemon',
      () async {
        await startServer();
        final WsClient client = await connect(server!.port);
        final Directory dir = Directory(p.join(tempDir.path, 'mcp-smoke'))
          ..createSync();
        File(p.join(dir.path, 'agent.capture_mcp')).writeAsStringSync('');
        final Project project = Project.fromJson(
          (j(
                    await client.peer.call('projects.add', <String, Object?>{
                      'path': dir.path,
                      'name': 'Subprocess Project',
                    }),
                  )['project']!
                  as Map)
              .cast<String, Object?>(),
        );
        await client.peer.call('sessions.create', <String, Object?>{
          'projectId': project.id,
          'providerId': 'fake',
        });
        final List<Object?> configs = jsonDecode(
          File(p.join(dir.path, 'agent.mcp_servers')).readAsStringSync(),
        ) as List<Object?>;
        final Map<String, Object?> config = (configs.single! as Map)
            .cast<String, Object?>();
        final Map<String, String> environment = mcpEnvironment(config);
        final String packageRoot = p.dirname(
          p.dirname(p.dirname(resolveFixture())),
        );
        final Process process = await Process.start(
          Platform.resolvedExecutable,
          const <String>['run', 'bin/speeddial.dart', '_internal-mcp'],
          workingDirectory: packageRoot,
          environment: <String, String>{
            ...Platform.environment,
            ...environment,
          },
        );
        final StreamIterator<String> output = StreamIterator<String>(
          process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter()),
        );
        final Future<String> stderrOutput = process.stderr
            .transform(utf8.decoder)
            .join();

        Future<Map<String, Object?>> request(
          int id,
          String method,
          Map<String, Object?> params,
        ) async {
          process.stdin.writeln(
            jsonEncode(<String, Object?>{
              'jsonrpc': '2.0',
              'id': id,
              'method': method,
              'params': params,
            }),
          );
          expect(
            await output.moveNext().timeout(const Duration(seconds: 10)),
            isTrue,
          );
          return (jsonDecode(output.current) as Map).cast<String, Object?>();
        }

        final Map<String, Object?> initialized = await request(
          1,
          'initialize',
          <String, Object?>{'protocolVersion': '2025-11-25'},
        );
        expect(
          (initialized['result']! as Map)['protocolVersion'],
          '2025-11-25',
        );
        final Map<String, Object?> listed = await request(
          2,
          'tools/list',
          const <String, Object?>{},
        );
        expect((listed['result']! as Map)['tools'], hasLength(3));
        final Map<String, Object?> searched = await request(
          3,
          'tools/call',
          <String, Object?>{
            'name': 'search_projects',
            'arguments': <String, Object?>{'query': 'subprocess'},
          },
        );
        expect(jsonEncode(searched['result']), contains('Subprocess Project'));

        await process.stdin.close();
        expect(
          await process.exitCode.timeout(const Duration(seconds: 10)),
          0,
          reason: await stderrOutput,
        );
        await output.cancel();
        await client.close();
      },
    );

    test(
      'sessions.create with yolo auto-approves permission requests',
      () async {
        await startServer();
        final client = await connect(server!.port);
        final dir = await Directory.systemTemp.createTemp('sd_yolo_');
        File(p.join(dir.path, 'example.txt'))
            .writeAsStringSync('hello from file\n');
        final project = Project.fromJson(
          (j(
                    await client.peer.call('projects.add', <String, Object?>{
                      'path': dir.path,
                    }),
                  )['project']!
                  as Map)
              .cast<String, Object?>(),
        );

        final created = j(
          await client.peer.call('sessions.create', <String, Object?>{
            'projectId': project.id,
            'providerId': 'fake',
            'yolo': true,
          }),
        );
        final session = Session.fromJson(
          (created['session']! as Map).cast<String, Object?>(),
        );
        expect(session.yolo, isTrue);

        // The turn runs to completion with no respondPermission: the request
        // and its resolution arrive back-to-back and the session never parks.
        await client.peer.call('sessions.send', <String, Object?>{
          'sessionId': session.id,
          'text': 'inspect',
        });
        await untilRecorded(client, 'session.event', 10);
        final events = client
            .of('session.event')
            .map(
              (n) => SessionEvent.fromJson(
                (n.params['event']! as Map).cast<String, Object?>(),
              ),
            )
            .toList();
        final request = events.whereType<PermissionRequestEvent>().single;
        final resolved = events.whereType<PermissionResolvedEvent>().single;
        expect(resolved.requestId, request.request.requestId);
        expect(resolved.optionId, 'allow');
        expect(events.last, isA<TurnCompleteEvent>());
        final updates = client
            .of('session.updated')
            .map(
              (n) => Session.fromJson(
                (n.params['session']! as Map).cast<String, Object?>(),
              ),
            )
            .toList();
        expect(
          updates.map((s) => s.status),
          isNot(contains(SessionStatus.waitingPermission)),
          reason: 'a yolo session never enters waitingPermission',
        );
      },
    );

    test(
      'sessions.create with baseBranch runs the session in a worktree',
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

        final project = Project.fromJson(
          (j(
                    await client.peer.call('projects.add', <String, Object?>{
                      'path': repoPath,
                    }),
                  )['project']!
                  as Map)
              .cast<String, Object?>(),
        );

        final created = j(
          await client.peer.call('sessions.create', <String, Object?>{
            'projectId': project.id,
            'providerId': 'fake',
            'title': 'Worktree session',
            'baseBranch': 'main',
          }),
        );
        final session = Session.fromJson(
          (created['session']! as Map).cast<String, Object?>(),
        );
        expect(session.cwd, contains('.speeddial-worktrees'));
        expect(Directory(session.cwd).existsSync(), isTrue);
        final branch = await Process.run('git', [
          'branch',
          '--show-current',
        ], workingDirectory: session.cwd);
        expect(
          (branch.stdout as String).trim(),
          startsWith('speeddial/worktree-session-'),
        );

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
      },
    );

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

      final project = Project.fromJson(
        (j(
                  await client.peer.call('projects.add', <String, Object?>{
                    'path': repoPath,
                  }),
                )['project']!
                as Map)
            .cast<String, Object?>(),
      );
      final session = Session.fromJson(
        (j(
                  await client.peer.call('sessions.create', <String, Object?>{
                    'projectId': project.id,
                    'providerId': 'fake',
                    'title': 'Worktree git',
                    'baseBranch': 'main',
                  }),
                )['session']!
                as Map)
            .cast<String, Object?>(),
      );

      // A change in the worktree is invisible at the project path…
      File(p.join(session.cwd, 'a.txt')).writeAsStringSync('v2\n');
      final projectStatus = GitStatus.fromJson(
        (j(
                  await client.peer.call('git.status', <String, Object?>{
                    'projectId': project.id,
                  }),
                )['status']!
                as Map)
            .cast<String, Object?>(),
      );
      expect(projectStatus.branch, 'main');
      expect(projectStatus.files, isEmpty);

      // …and fully visible through the session.
      final sessionStatus = GitStatus.fromJson(
        (j(
                  await client.peer.call('git.status', <String, Object?>{
                    'projectId': project.id,
                    'sessionId': session.id,
                  }),
                )['status']!
                as Map)
            .cast<String, Object?>(),
      );
      expect(sessionStatus.branch, startsWith('speeddial/worktree-git-'));
      expect(sessionStatus.files.single.path, 'a.txt');
      expect(sessionStatus.files.single.worktreeStatus, 'M');

      final diffs =
          (j(
                await client.peer.call('git.diff', <String, Object?>{
                  'projectId': project.id,
                  'sessionId': session.id,
                  'path': 'a.txt',
                }),
              )['diffs']!
              as List);
      expect(diffs, hasLength(1));
      expect((diffs.single! as Map)['patch'], contains('+v2'));

      // Commits land on the worktree branch, not the main checkout.
      final committed = j(
        await client.peer.call('git.commit', <String, Object?>{
          'projectId': project.id,
          'sessionId': session.id,
          'message': 'work in the worktree',
          'stageAll': true,
        }),
      );
      expect(committed['commitHash'], isA<String>());
      expect(
        await Process.run(
          'git',
          ['log', '-1', '--format=%s'],
          workingDirectory: session.cwd,
        ).then((r) => (r.stdout as String).trim()),
        'work in the worktree',
      );
      expect(
        await Process.run('git', [
          'log',
          '-1',
          '--format=%s',
        ], workingDirectory: repoPath).then((r) => (r.stdout as String).trim()),
        'init',
      );

      // Validation: unknown session, and a session from another project.
      await expectLater(
        client.peer.call('git.status', <String, Object?>{
          'projectId': project.id,
          'sessionId': 'nope',
        }),
        throwsA(isA<DaemonError>().having((e) => e.code, 'code', kErrNotFound)),
      );
      final otherDir = p.join(parent.path, 'other');
      await git(parent.path, ['clone', originDir, otherDir]);
      final otherProject = Project.fromJson(
        (j(
                  await client.peer.call('projects.add', <String, Object?>{
                    'path': otherDir,
                  }),
                )['project']!
                as Map)
            .cast<String, Object?>(),
      );
      final otherSession = Session.fromJson(
        (j(
                  await client.peer.call('sessions.create', <String, Object?>{
                    'projectId': otherProject.id,
                    'providerId': 'fake',
                  }),
                )['session']!
                as Map)
            .cast<String, Object?>(),
      );
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

      final project = Project.fromJson(
        (j(
                  await client.peer.call('projects.add', <String, Object?>{
                    'path': repoPath,
                  }),
                )['project']!
                as Map)
            .cast<String, Object?>(),
      );
      final session = Session.fromJson(
        (j(
                  await client.peer.call('sessions.create', <String, Object?>{
                    'projectId': project.id,
                    'providerId': 'fake',
                    'title': 'Merge me',
                    'baseBranch': 'main',
                  }),
                )['session']!
                as Map)
            .cast<String, Object?>(),
      );
      expect(
        session.baseBranch,
        'main',
        reason: 'the wire Session must carry the base branch',
      );

      // Committing in the worktree, then merging, lands on main.
      File(p.join(session.cwd, 'feat.txt')).writeAsStringSync('f\n');
      await client.peer.call('git.commit', <String, Object?>{
        'projectId': project.id,
        'sessionId': session.id,
        'message': 'session work',
        'stageAll': true,
      });
      final merged = j(
        await client.peer.call('git.mergeToBase', <String, Object?>{
          'projectId': project.id,
          'sessionId': session.id,
        }),
      );
      final merge = MergeResult.fromJson(
        (merged['merge']! as Map).cast<String, Object?>(),
      );
      expect(merge.baseBranch, 'main');
      expect(merge.sessionBranch, startsWith('speeddial/merge-me-'));
      expect(merge.alreadyUpToDate, isFalse);
      expect(merge.fastForward, isTrue);
      expect(merge.baseFastForwarded, isFalse);
      expect(
        await Process.run('git', [
          'log',
          '-1',
          '--format=%s',
        ], workingDirectory: repoPath).then((r) => (r.stdout as String).trim()),
        'session work',
      );
      expect(File(p.join(repoPath, 'feat.txt')).existsSync(), isTrue);

      // A second merge is a no-op.
      final again = MergeResult.fromJson(
        (j(
                  await client.peer.call('git.mergeToBase', <String, Object?>{
                    'projectId': project.id,
                    'sessionId': session.id,
                  }),
                )['merge']!
                as Map)
            .cast<String, Object?>(),
      );
      expect(again.alreadyUpToDate, isTrue);

      // A dirty worktree is a conflict, and a session without a base branch
      // is invalid params.
      File(p.join(session.cwd, 'dirty.txt')).writeAsStringSync('x\n');
      await expectLater(
        client.peer.call('git.mergeToBase', <String, Object?>{
          'projectId': project.id,
          'sessionId': session.id,
        }),
        throwsA(isA<DaemonError>().having((e) => e.code, 'code', kErrConflict)),
      );
      final plain = Session.fromJson(
        (j(
                  await client.peer.call('sessions.create', <String, Object?>{
                    'projectId': project.id,
                    'providerId': 'fake',
                  }),
                )['session']!
                as Map)
            .cast<String, Object?>(),
      );
      expect(plain.baseBranch, isNull);
      await expectLater(
        client.peer.call('git.mergeToBase', <String, Object?>{
          'projectId': project.id,
          'sessionId': plain.id,
        }),
        throwsA(isA<DaemonError>().having((e) => e.code, 'code', -32602)),
      );
      await expectLater(
        client.peer.call('git.mergeToBase', <String, Object?>{
          'projectId': project.id,
        }),
        throwsA(isA<DaemonError>().having((e) => e.code, 'code', -32602)),
      );
      await client.close();
    });

    test(
      'git.sessionSummaries reports dirty/ahead/merged per session',
      () async {
        await startServer();
        final client = await connect(server!.port);

        final parent = await Directory.systemTemp.createTemp(
          'sd_ws_summaries_',
        );
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

        final project = Project.fromJson(
          (j(
                    await client.peer.call('projects.add', <String, Object?>{
                      'path': repoPath,
                    }),
                  )['project']!
                  as Map)
              .cast<String, Object?>(),
        );
        final worktree = Session.fromJson(
          (j(
                    await client.peer.call('sessions.create', <String, Object?>{
                      'projectId': project.id,
                      'providerId': 'fake',
                      'title': 'Worktree session',
                      'baseBranch': 'main',
                    }),
                  )['session']!
                  as Map)
              .cast<String, Object?>(),
        );
        final plain = Session.fromJson(
          (j(
                    await client.peer.call('sessions.create', <String, Object?>{
                      'projectId': project.id,
                      'providerId': 'fake',
                      'title': 'Plain session',
                    }),
                  )['session']!
                  as Map)
              .cast<String, Object?>(),
        );

        Future<Map<String, SessionGitSummary>> summaries() async {
          final result = j(
            await client.peer.call('git.sessionSummaries', <String, Object?>{
              'projectId': project.id,
            }),
          );
          final list = (result['summaries']! as List)
              .map(
                (e) => SessionGitSummary.fromJson(
                  (e! as Map).cast<String, Object?>(),
                ),
              )
              .toList();
          return <String, SessionGitSummary>{
            for (final s in list) s.sessionId: s,
          };
        }

        // Fresh: worktree session is clean/ahead 0/behind 0/not merged; the
        // plain session only carries dirty (it has no base branch).
        var map = await summaries();
        expect(map, hasLength(2));
        expect(map[worktree.id]!.dirty, isFalse);
        expect(map[worktree.id]!.aheadOfBase, 0);
        expect(map[worktree.id]!.behindBase, 0);
        expect(map[worktree.id]!.mergedIntoBase, isFalse);
        expect(map[plain.id]!.dirty, isFalse);
        expect(map[plain.id]!.aheadOfBase, isNull);
        expect(map[plain.id]!.behindBase, isNull);
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
        expect(map[worktree.id]!.behindBase, 0);
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
        expect(map[worktree.id]!.behindBase, 0);
        expect(map[worktree.id]!.mergedIntoBase, isTrue);
        expect(map[worktree.id]!.dirty, isFalse);

        // A commit landing on the base branch itself (local side is enough —
        // behindBase counts both base refs) leaves the session behind.
        File(p.join(repoPath, 'base2.txt')).writeAsStringSync('b\n');
        await git(repoPath, ['add', '-A']);
        await git(repoPath, ['commit', '-m', 'base moves on']);
        map = await summaries();
        expect(map[worktree.id]!.aheadOfBase, 0);
        expect(map[worktree.id]!.behindBase, 1);
        expect(map[worktree.id]!.mergedIntoBase, isTrue);

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
          client.peer.call('git.sessionSummaries', <String, Object?>{
            'projectId': 'nope',
          }),
          throwsA(
            isA<DaemonError>().having((e) => e.code, 'code', kErrNotFound),
          ),
        );
        await client.close();
      },
    );

    test(
      'a merge into the base marks sibling worktree sessions behind',
      () async {
        await startServer();
        final client = await connect(server!.port);

        final parent = await Directory.systemTemp.createTemp('sd_ws_siblings_');
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

        final project = Project.fromJson(
          (j(
                    await client.peer.call('projects.add', <String, Object?>{
                      'path': repoPath,
                    }),
                  )['project']!
                  as Map)
              .cast<String, Object?>(),
        );
        Future<Session> mkWorktree(String title) async => Session.fromJson(
          (j(
                    await client.peer.call('sessions.create', <String, Object?>{
                      'projectId': project.id,
                      'providerId': 'fake',
                      'title': title,
                      'baseBranch': 'main',
                    }),
                  )['session']!
                  as Map)
              .cast<String, Object?>(),
        );
        final Session first = await mkWorktree('First');
        final Session second = await mkWorktree('Second');

        // `first` gains a commit (future-dated so the merged-into-base check
        // is not same-second racy, like the summaries test) and is merged.
        File(p.join(first.cwd, 'feat.txt')).writeAsStringSync('f\n');
        await git(first.cwd, ['add', '-A']);
        final future =
            '@${(DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3600} +0000';
        await Process.run(
          'git',
          ['commit', '-m', 'first session work'],
          workingDirectory: first.cwd,
          environment: <String, String>{'GIT_COMMITTER_DATE': future},
        );
        await client.peer.call('git.mergeToBase', <String, Object?>{
          'projectId': project.id,
          'sessionId': first.id,
        });

        final result = j(
          await client.peer.call('git.sessionSummaries', <String, Object?>{
            'projectId': project.id,
          }),
        );
        final Map<String, SessionGitSummary> map = <String, SessionGitSummary>{
          for (final entry in (result['summaries']! as List))
            (entry! as Map)['sessionId']! as String: SessionGitSummary.fromJson(
              entry.cast<String, Object?>(),
            ),
        };

        // The merged session: its work landed on the base.
        expect(map[first.id]!.aheadOfBase, 0);
        expect(map[first.id]!.behindBase, 0);
        expect(map[first.id]!.mergedIntoBase, isTrue);
        // The sibling: the merge advanced the LOCAL base ref — no fetch, no
        // remote movement involved — so it reads one behind immediately.
        expect(map[second.id]!.aheadOfBase, 0);
        expect(map[second.id]!.behindBase, 1);
        expect(map[second.id]!.mergedIntoBase, isFalse);
        await client.close();
      },
    );

    test(
      'git.changed notifies when the watcher notices summaries move',
      () async {
        await startServer(
          gitPollInterval: const Duration(milliseconds: 150),
          gitFetchInterval: const Duration(milliseconds: 300),
        );
        final client = await connect(server!.port);

        final parent = await Directory.systemTemp.createTemp('sd_ws_watch_');
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

        final project = Project.fromJson(
          (j(
                    await client.peer.call('projects.add', <String, Object?>{
                      'path': repoPath,
                    }),
                  )['project']!
                  as Map)
              .cast<String, Object?>(),
        );
        final worktree = Session.fromJson(
          (j(
                    await client.peer.call('sessions.create', <String, Object?>{
                      'projectId': project.id,
                      'providerId': 'fake',
                      'title': 'Worktree session',
                      'baseBranch': 'main',
                    }),
                  )['session']!
                  as Map)
              .cast<String, Object?>(),
        );

        Future<SessionGitSummary> summary() async {
          final result = j(
            await client.peer.call('git.sessionSummaries', <String, Object?>{
              'projectId': project.id,
            }),
          );
          return SessionGitSummary.fromJson(
            ((result['summaries']! as List).single! as Map)
                .cast<String, Object?>(),
          );
        }

        /// Waits for the watcher to settle its baseline, then asserts a quiet
        /// window produces no notification: events mean movement, not passes.
        Future<void> quietFor(int ms) async {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          final int count = client.of('git.changed').length;
          await Future<void>.delayed(Duration(milliseconds: ms));
          expect(
            client.of('git.changed').length,
            count,
            reason: 'nothing moved, so no git.changed was due',
          );
        }

        await quietFor(600);

        // A commit in the session worktree — what an agent does mid-turn,
        // with no session.updated to piggyback on — must surface on its own.
        // The wait is relative to the pre-commit count: baseline settling can
        // legitimately emit earlier notifications (e.g. the session appearing
        // between passes), so absolute counts would be racy.
        final int beforeCommit = client.of('git.changed').length;
        File(p.join(worktree.cwd, 'feat.txt')).writeAsStringSync('f\n');
        await git(worktree.cwd, ['add', '-A']);
        await git(worktree.cwd, ['commit', '-m', 'session work']);
        await untilRecorded(client, 'git.changed', beforeCommit + 1);
        expect(client.of('git.changed').last.params['projectId'], project.id);
        expect((await summary()).aheadOfBase, 1);
        await quietFor(600);

        // The base moving on the remote must surface too: the watcher's
        // periodic fetch advances origin/main and flips behindBase to 1. The
        // notification is emitted after the summaries moved, so by the time it
        // arrives the RPC must observe the new counts.
        final int beforePush = client.of('git.changed').length;
        final otherPath = p.join(parent.path, 'other');
        await git(parent.path, ['clone', originDir, otherPath]);
        await git(otherPath, ['config', 'user.email', 'test@example.com']);
        await git(otherPath, ['config', 'user.name', 'Test User']);
        File(p.join(otherPath, 'remote.txt')).writeAsStringSync('r\n');
        await git(otherPath, ['add', '-A']);
        await git(otherPath, ['commit', '-m', 'remote moves base']);
        await git(otherPath, ['push', 'origin', 'main']);
        await untilRecorded(client, 'git.changed', beforePush + 1);
        final SessionGitSummary moved = await summary();
        expect(moved.aheadOfBase, 1);
        expect(moved.behindBase, 1);
        await client.close();
      },
    );

    test(
      'git.rebaseOntoBase rebases the worktree branch onto the base',
      () async {
        await startServer();
        final client = await connect(server!.port);

        final parent = await Directory.systemTemp.createTemp('sd_ws_rebase_');
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

        final project = Project.fromJson(
          (j(
                    await client.peer.call('projects.add', <String, Object?>{
                      'path': repoPath,
                    }),
                  )['project']!
                  as Map)
              .cast<String, Object?>(),
        );
        final session = Session.fromJson(
          (j(
                    await client.peer.call('sessions.create', <String, Object?>{
                      'projectId': project.id,
                      'providerId': 'fake',
                      'title': 'Rebase me',
                      'baseBranch': 'main',
                    }),
                  )['session']!
                  as Map)
              .cast<String, Object?>(),
        );

        // The session branch and the base both move since the branch point.
        File(p.join(session.cwd, 'feat.txt')).writeAsStringSync('f\n');
        await client.peer.call('git.commit', <String, Object?>{
          'projectId': project.id,
          'sessionId': session.id,
          'message': 'session work',
          'stageAll': true,
        });
        File(p.join(repoPath, 'base.txt')).writeAsStringSync('b\n');
        await git(repoPath, ['add', '-A']);
        await git(repoPath, ['commit', '-m', 'base work']);
        final baseTip = await Process.run('git', [
          'rev-parse',
          'main',
        ], workingDirectory: repoPath).then((r) => (r.stdout as String).trim());

        final result = j(
          await client.peer.call('git.rebaseOntoBase', <String, Object?>{
            'projectId': project.id,
            'sessionId': session.id,
          }),
        );
        final rebase = RebaseResult.fromJson(
          (result['rebase']! as Map).cast<String, Object?>(),
        );
        expect(rebase.baseBranch, 'main');
        expect(rebase.sessionBranch, startsWith('speeddial/rebase-me-'));
        expect(rebase.alreadyUpToDate, isFalse);
        expect(rebase.baseFastForwarded, isFalse);
        // Linear history: the base tip is the parent of the replayed commit.
        expect(
          await Process.run(
            'git',
            ['rev-parse', 'HEAD^'],
            workingDirectory: session.cwd,
          ).then((r) => (r.stdout as String).trim()),
          baseTip,
        );
        expect(
          await Process.run(
            'git',
            ['rev-parse', 'HEAD'],
            workingDirectory: session.cwd,
          ).then((r) => (r.stdout as String).trim()),
          rebase.commit,
        );
        expect(File(p.join(session.cwd, 'base.txt')).existsSync(), isTrue);
        expect(File(p.join(session.cwd, 'feat.txt')).existsSync(), isTrue);

        // A second rebase is a no-op.
        final again = RebaseResult.fromJson(
          (j(
                    await client.peer.call(
                      'git.rebaseOntoBase',
                      <String, Object?>{
                        'projectId': project.id,
                        'sessionId': session.id,
                      },
                    ),
                  )['rebase']!
                  as Map)
              .cast<String, Object?>(),
        );
        expect(again.alreadyUpToDate, isTrue);
        expect(again.commit, rebase.commit);

        // A dirty worktree is a conflict, and a session without a base branch
        // is invalid params.
        File(p.join(session.cwd, 'dirty.txt')).writeAsStringSync('x\n');
        await expectLater(
          client.peer.call('git.rebaseOntoBase', <String, Object?>{
            'projectId': project.id,
            'sessionId': session.id,
          }),
          throwsA(
            isA<DaemonError>().having((e) => e.code, 'code', kErrConflict),
          ),
        );
        final plain = Session.fromJson(
          (j(
                    await client.peer.call('sessions.create', <String, Object?>{
                      'projectId': project.id,
                      'providerId': 'fake',
                    }),
                  )['session']!
                  as Map)
              .cast<String, Object?>(),
        );
        await expectLater(
          client.peer.call('git.rebaseOntoBase', <String, Object?>{
            'projectId': project.id,
            'sessionId': plain.id,
          }),
          throwsA(isA<DaemonError>().having((e) => e.code, 'code', -32602)),
        );
        await expectLater(
          client.peer.call('git.rebaseOntoBase', <String, Object?>{
            'projectId': project.id,
          }),
          throwsA(isA<DaemonError>().having((e) => e.code, 'code', -32602)),
        );
        await client.close();
      },
    );
  });

  group('attachments', () {
    test(
      'sessions.send with image + text attachments maps to ACP blocks, '
      'events carry metadata, and attachments.read returns payloads',
      () async {
        await startServer();
        final client = await connect(server!.port);
        final dir = await Directory.systemTemp.createTemp('sd_attach_');
        File(p.join(dir.path, 'example.txt'))
            .writeAsStringSync('hello from file\n');
        final project = Project.fromJson(
          (j(
                    await client.peer.call('projects.add', <String, Object?>{
                      'path': dir.path,
                    }),
                  )['project']!
                  as Map)
              .cast<String, Object?>(),
        );
        final created = j(
          await client.peer.call('sessions.create', <String, Object?>{
            'projectId': project.id,
            'providerId': 'fake',
          }),
        );
        final session = Session.fromJson(
          (created['session']! as Map).cast<String, Object?>(),
        );

        // An image-ish payload plus a text payload.
        final imageBytes = <int>[
          0x89,
          0x50,
          0x4E,
          0x47,
          0x0D,
          0x0A,
          0x1A,
          0x0A,
        ];
        final imageData = base64Encode(imageBytes);
        const notesText = 'line 1\nline 2';
        final notesData = base64Encode(utf8.encode(notesText));
        const text = 'Inspect these files';

        final permission = waitForEvent(
          client,
          (event) => event is PermissionRequestEvent,
        );
        final send = client.peer.call('sessions.send', <String, Object?>{
          'sessionId': session.id,
          'text': text,
          'attachments': <Object?>[
            <String, Object?>{
              'name': 'diagram.png',
              'mimeType': 'image/png',
              'data': imageData,
            },
            <String, Object?>{
              'name': 'notes.md',
              'mimeType': 'text/markdown',
              'data': notesData,
            },
          ],
        });
        final requestParams = await permission;
        final request = ((requestParams['event']! as Map)['request']! as Map)
            .cast<String, Object?>();
        await client.peer.call('sessions.respondPermission', <String, Object?>{
          'sessionId': session.id,
          'requestId': request['requestId']! as String,
          'optionId': 'allow',
        });
        await send;

        // The agent received the mapped prompt blocks (text first, then image,
        // then the inline-text resource).
        final lastPrompt = jsonDecode(
          File(p.join(dir.path, 'agent.last_prompt.json')).readAsStringSync(),
        ) as List<Object?>;
        expect(lastPrompt, hasLength(3));
        final textBlock = lastPrompt[0]! as Map;
        expect(textBlock['type'], 'text');
        expect(textBlock['text'], text);
        final imageBlock = lastPrompt[1]! as Map;
        expect(imageBlock['type'], 'image');
        expect(imageBlock['data'], imageData);
        expect(imageBlock['mimeType'], 'image/png');
        final resourceBlock = lastPrompt[2]! as Map;
        expect(resourceBlock['type'], 'resource');
        final resource = resourceBlock['resource']! as Map;
        expect(resource['uri'], startsWith('speeddial-attachment:///'));
        expect(resource['uri']!.endsWith('/notes.md'), isTrue);
        expect(resource['mimeType'], 'text/markdown');
        expect(resource['text'], notesText);
        expect(resource.containsKey('blob'), isFalse);

        // The persisted userMessage event carries metadata only (no payload).
        final history = j(
          await client.peer.call('sessions.history', <String, Object?>{
            'sessionId': session.id,
          }),
        );
        final events = (history['events']! as List<Object?>)
            .map(
              (e) => SessionEvent.fromJson((e! as Map).cast<String, Object?>()),
            )
            .toList();
        final userMessage = events.first as UserMessageEvent;
        expect(userMessage.attachments, hasLength(2));
        final imageMeta = userMessage.attachments[0];
        expect(imageMeta.name, 'diagram.png');
        expect(imageMeta.mimeType, 'image/png');
        expect(imageMeta.size, imageBytes.length);
        expect(imageMeta.id, isNotEmpty);
        final notesMeta = userMessage.attachments[1];
        expect(notesMeta.name, 'notes.md');
        expect(notesMeta.mimeType, 'text/markdown');
        expect(notesMeta.size, utf8.encode(notesText).length);
        expect(notesMeta.id, isNotEmpty);
        expect(
          imageMeta.id == notesMeta.id,
          isFalse,
          reason: 'each attachment gets its own id',
        );
        final metaJson =
            ((userMessage.toJson()['attachments']! as List).first! as Map);
        expect(
          metaJson.containsKey('data'),
          isFalse,
          reason: 'metadata never carries the payload',
        );

        // attachments.read returns the payloads.
        final read = j(
          await client.peer.call('attachments.read', <String, Object?>{
            'sessionId': session.id,
            'attachmentId': imageMeta.id,
          }),
        );
        final attachmentJson = (read['attachment']! as Map)
            .cast<String, Object?>();
        expect(attachmentJson['id'], imageMeta.id);
        expect(attachmentJson['name'], 'diagram.png');
        expect(attachmentJson['mimeType'], 'image/png');
        expect(attachmentJson['size'], imageBytes.length);
        expect(attachmentJson['data'], imageData);
        final readNotes = j(
          await client.peer.call('attachments.read', <String, Object?>{
            'sessionId': session.id,
            'attachmentId': notesMeta.id,
          }),
        );
        expect((readNotes['attachment']! as Map)['data'], notesData);

        // Unknown ids / sessions → -32002.
        await expectLater(
          client.peer.call('attachments.read', <String, Object?>{
            'sessionId': session.id,
            'attachmentId': 'no-such-id',
          }),
          throwsA(
            isA<DaemonError>().having((e) => e.code, 'code', kErrNotFound),
          ),
        );
        await expectLater(
          client.peer.call('attachments.read', <String, Object?>{
            'sessionId': 'no-such-session',
            'attachmentId': imageMeta.id,
          }),
          throwsA(
            isA<DaemonError>().having((e) => e.code, 'code', kErrNotFound),
          ),
        );

        // Deleting the session removes its attachments too (cascade).
        await client.peer.call('sessions.delete', <String, Object?>{
          'sessionId': session.id,
        });
        await expectLater(
          client.peer.call('attachments.read', <String, Object?>{
            'sessionId': session.id,
            'attachmentId': imageMeta.id,
          }),
          throwsA(
            isA<DaemonError>().having((e) => e.code, 'code', kErrNotFound),
          ),
        );

        await client.close();
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'sessions.send attachment validation rejects caps violations',
      () async {
        await startServer();
        final client = await connect(server!.port);
        final dir = await Directory.systemTemp.createTemp('sd_attach_val_');
        File(p.join(dir.path, 'example.txt')).writeAsStringSync('hello\n');
        final project = Project.fromJson(
          (j(
                    await client.peer.call('projects.add', <String, Object?>{
                      'path': dir.path,
                    }),
                  )['project']!
                  as Map)
              .cast<String, Object?>(),
        );
        final created = j(
          await client.peer.call('sessions.create', <String, Object?>{
            'projectId': project.id,
            'providerId': 'fake',
          }),
        );
        final sessionId = (created['session']! as Map)['id']! as String;

        // Empty text with no attachments → -32602.
        await expectLater(
          client.peer.call('sessions.send', <String, Object?>{
            'sessionId': sessionId,
            'text': '',
          }),
          throwsA(isA<DaemonError>().having((e) => e.code, 'code', -32602)),
        );
        await expectLater(
          client.peer.call('sessions.send', <String, Object?>{
            'sessionId': sessionId,
          }),
          throwsA(isA<DaemonError>().having((e) => e.code, 'code', -32602)),
        );

        Map<String, Object?> attachment(int i) => <String, Object?>{
          'name': 'f$i.bin',
          'mimeType': 'application/octet-stream',
          'data': base64Encode(<int>[i]),
        };

        // More than 8 attachments → -32602.
        await expectLater(
          client.peer.call('sessions.send', <String, Object?>{
            'sessionId': sessionId,
            'text': 'too many',
            'attachments': <Object?>[for (var i = 0; i < 9; i++) attachment(i)],
          }),
          throwsA(isA<DaemonError>().having((e) => e.code, 'code', -32602)),
        );

        // Non-object / missing-field / malformed-base64 entries → -32602.
        await expectLater(
          client.peer.call('sessions.send', <String, Object?>{
            'sessionId': sessionId,
            'text': 'bad',
            'attachments': <Object?>['nope'],
          }),
          throwsA(isA<DaemonError>().having((e) => e.code, 'code', -32602)),
        );
        await expectLater(
          client.peer.call('sessions.send', <String, Object?>{
            'sessionId': sessionId,
            'text': 'bad',
            'attachments': <Object?>[
              <String, Object?>{
                'name': 'f1.bin',
                'mimeType': 'application/octet-stream',
              },
            ],
          }),
          throwsA(isA<DaemonError>().having((e) => e.code, 'code', -32602)),
        );
        await expectLater(
          client.peer.call('sessions.send', <String, Object?>{
            'sessionId': sessionId,
            'text': 'bad',
            'attachments': <Object?>[
              <String, Object?>{
                'name': 'f1.bin',
                'mimeType': 'application/octet-stream',
                'data': '!!!!',
              },
            ],
          }),
          throwsA(isA<DaemonError>().having((e) => e.code, 'code', -32602)),
        );

        // A single attachment over 8 MiB → -32602.
        await expectLater(
          client.peer.call('sessions.send', <String, Object?>{
            'sessionId': sessionId,
            'text': 'too big',
            'attachments': <Object?>[
              <String, Object?>{
                'name': 'big.bin',
                'mimeType': 'application/octet-stream',
                'data': base64Encode(
                  List<int>.filled(kMaxAttachmentBytes + 1, 0),
                ),
              },
            ],
          }),
          throwsA(isA<DaemonError>().having((e) => e.code, 'code', -32602)),
        );

        // Attachments whose combined size exceeds 16 MiB → -32602.
        await expectLater(
          client.peer.call('sessions.send', <String, Object?>{
            'sessionId': sessionId,
            'text': 'too big together',
            'attachments': <Object?>[
              for (var i = 0; i < 3; i++)
                <String, Object?>{
                  'name': 'part$i.bin',
                  'mimeType': 'application/octet-stream',
                  'data': base64Encode(List<int>.filled(6 * 1024 * 1024, 0)),
                },
            ],
          }),
          throwsA(isA<DaemonError>().having((e) => e.code, 'code', -32602)),
        );

        await client.close();
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'sessions.send allows an empty text when attachments are present',
      () async {
        await startServer();
        final client = await connect(server!.port);
        final dir = await Directory.systemTemp.createTemp('sd_attach_empty_');
        File(p.join(dir.path, 'example.txt')).writeAsStringSync('hello\n');
        final project = Project.fromJson(
          (j(
                    await client.peer.call('projects.add', <String, Object?>{
                      'path': dir.path,
                    }),
                  )['project']!
                  as Map)
              .cast<String, Object?>(),
        );
        final created = j(
          await client.peer.call('sessions.create', <String, Object?>{
            'projectId': project.id,
            'providerId': 'fake',
          }),
        );
        final session = Session.fromJson(
          (created['session']! as Map).cast<String, Object?>(),
        );

        final permission = waitForEvent(
          client,
          (event) => event is PermissionRequestEvent,
        );
        final send = client.peer.call('sessions.send', <String, Object?>{
          'sessionId': session.id,
          'attachments': <Object?>[
            <String, Object?>{
              'name': 'data.json',
              'mimeType': 'application/json',
              'data': base64Encode(utf8.encode('{"a":1}')),
            },
          ],
        });
        final requestParams = await permission;
        final request = ((requestParams['event']! as Map)['request']! as Map)
            .cast<String, Object?>();
        await client.peer.call('sessions.respondPermission', <String, Object?>{
          'sessionId': session.id,
          'requestId': request['requestId']! as String,
          'optionId': 'allow',
        });
        await send;

        // No text block: only the resource block (application/json is a text
        // mime type, so the payload is inlined as decoded text).
        final lastPrompt = jsonDecode(
          File(p.join(dir.path, 'agent.last_prompt.json')).readAsStringSync(),
        ) as List<Object?>;
        expect(lastPrompt, hasLength(1));
        final block = lastPrompt.single! as Map;
        expect(block['type'], 'resource');
        expect((block['resource']! as Map)['text'], '{"a":1}');

        await client.close();
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });

  group('fs', () {
    test(
      'fs.list / fs.read: confinement, binary detection, truncation',
      () async {
        await startServer();
        final client = await connect(server!.port);
        final dir = await Directory.systemTemp.createTemp('sd_fs_');
        Directory(p.join(dir.path, 'sub')).createSync();
        Directory(p.join(dir.path, '.git')).createSync();
        File(p.join(dir.path, 'alpha.txt')).writeAsStringSync('alpha');
        File(p.join(dir.path, 'zebra.txt')).writeAsStringSync('zebra');
        File(p.join(dir.path, 'sub', 'inner.txt')).writeAsStringSync('inner');
        final project = Project.fromJson(
          (j(
                    await client.peer.call('projects.add', <String, Object?>{
                      'path': dir.path,
                    }),
                  )['project']!
                  as Map)
              .cast<String, Object?>(),
        );

        // Root listing: docs first, names ascending, .git skipped.
        final listing = j(
          await client.peer.call('fs.list', <String, Object?>{
            'projectId': project.id,
          }),
        );
        final entries = (listing['entries']! as List<Object?>)
            .map((e) => FileEntry.fromJson((e! as Map).cast<String, Object?>()))
            .toList();
        expect(entries.map((e) => e.name).toList(), <String>[
          'sub',
          'alpha.txt',
          'zebra.txt',
        ]);
        expect(entries.first.isDir, isTrue);
        expect(entries.first.path, 'sub');

        // Nested listing reports root-relative paths.
        final nested = j(
          await client.peer.call('fs.list', <String, Object?>{
            'projectId': project.id,
            'path': 'sub',
          }),
        );
        final inner = FileEntry.fromJson(
          (((nested['entries']! as List<Object?>).single! as Map)
              .cast<String, Object?>()),
        );
        expect(inner.name, 'inner.txt');
        expect(inner.path, 'sub/inner.txt');
        expect(inner.isDir, isFalse);
        expect(inner.size, 5);

        // Escapes and absolute paths are invalid params.
        for (final path in <String>['..', '../outside.txt', '/etc/hostname']) {
          await expectLater(
            client.peer.call('fs.list', <String, Object?>{
              'projectId': project.id,
              'path': path,
            }),
            throwsA(isA<DaemonError>().having((e) => e.code, 'code', -32602)),
            reason: 'expected -32602 for $path',
          );
        }

        // Read a small file verbatim.
        final read = j(
          await client.peer.call('fs.read', <String, Object?>{
            'projectId': project.id,
            'path': 'alpha.txt',
          }),
        );
        expect(read['content'], 'alpha');
        expect(read['truncated'], isFalse);
        expect(read['isBinary'], isFalse);

        // Binary detection via a NUL byte in the probe window.
        File(p.join(dir.path, 'bin.dat'))
            .writeAsBytesSync(<int>[0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]);
        final binary = j(
          await client.peer.call('fs.read', <String, Object?>{
            'projectId': project.id,
            'path': 'bin.dat',
          }),
        );
        expect(binary['content'], '');
        expect(binary['isBinary'], isTrue);
        expect(binary['truncated'], isFalse);

        // Truncation at the default 512 KiB cap.
        File(p.join(dir.path, 'big.txt')).writeAsStringSync('x' * (600 * 1024));
        final big = j(
          await client.peer.call('fs.read', <String, Object?>{
            'projectId': project.id,
            'path': 'big.txt',
          }),
        );
        expect((big['content']! as String), hasLength(512 * 1024));
        expect(big['truncated'], isTrue);
        expect(big['isBinary'], isFalse);

        // The 4 MiB hard cap clamps an over-large maxBytes request.
        File(p.join(dir.path, 'huge.txt'))
            .writeAsStringSync('y' * (5 * 1024 * 1024));
        final huge = j(
          await client.peer.call('fs.read', <String, Object?>{
            'projectId': project.id,
            'path': 'huge.txt',
            'maxBytes': 8 * 1024 * 1024,
          }),
        );
        expect((huge['content']! as String), hasLength(4 * 1024 * 1024));
        expect(huge['truncated'], isTrue);

        // Missing files/dirs are invalid params.
        await expectLater(
          client.peer.call('fs.read', <String, Object?>{
            'projectId': project.id,
            'path': 'missing.txt',
          }),
          throwsA(isA<DaemonError>().having((e) => e.code, 'code', -32602)),
        );
        await expectLater(
          client.peer.call('fs.read', <String, Object?>{
            'projectId': project.id,
            'path': '.',
          }),
          throwsA(isA<DaemonError>().having((e) => e.code, 'code', -32602)),
        );

        // Unknown projects are not found.
        await expectLater(
          client.peer.call('fs.list', <String, Object?>{
            'projectId': 'missing-project',
          }),
          throwsA(
            isA<DaemonError>().having((e) => e.code, 'code', kErrNotFound),
          ),
        );

        await client.close();
      },
    );
  });

  group('git', () {
    test('status/commit work against a temp repo behind the wire', () async {
      await startServer();
      final client = await connect(server!.port);
      final repo = await _initRepo();
      await _write(repo, 'file.txt', 'hello');

      await client.peer.call('projects.add', <String, Object?>{
        'path': repo.path,
      });
      final projectId =
          ((j(await client.peer.call('projects.list'))['projects']!
                          as List<Object?>)
                      .single!
                  as Map)['id']!
              as String;

      final status = j(
        await client.peer.call('git.status', <String, Object?>{
          'projectId': projectId,
        }),
      );
      final parsed = GitStatus.fromJson(
        (status['status']! as Map).cast<String, Object?>(),
      );
      expect(parsed.branch, 'main');
      expect(parsed.files, hasLength(1));
      expect(parsed.files.first.path, 'file.txt');

      final commit = j(
        await client.peer.call('git.commit', <String, Object?>{
          'projectId': projectId,
          'message': 'initial',
          'stageAll': true,
        }),
      );
      expect(commit['commitHash']! as String, isNotEmpty);

      final clean = j(
        await client.peer.call('git.status', <String, Object?>{
          'projectId': projectId,
        }),
      );
      expect(
        GitStatus.fromJson((clean['status']! as Map).cast<String, Object?>())
            .files,
        isEmpty,
      );

      // Unknown project → kErrNotFound.
      await expectLater(
        client.peer.call('git.status', <String, Object?>{'projectId': 'nope'}),
        throwsA(isA<DaemonError>().having((e) => e.code, 'code', kErrNotFound)),
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
        throwsA(isA<DaemonError>().having((e) => e.code, 'code', -32601)),
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
      final loopback = await WebSocket.connect(
        'ws://127.0.0.1:$port/ws',
        headers: {'origin': 'http://localhost:7331'},
      );
      await loopback.close();

      // Non-loopback Origin: rejected with 403 before the upgrade.
      final client = HttpClient();
      try {
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:$port/ws'),
        );
        request.headers.set(HttpHeaders.connectionHeader, 'Upgrade');
        request.headers.set(HttpHeaders.upgradeHeader, 'websocket');
        request.headers.set('sec-websocket-key', 'dGhlIHNhbXBsZSBub25jZQ==');
        request.headers.set('sec-websocket-version', '13');
        request.headers.set('origin', 'http://evil.example');
        final response = await request.close();
        expect(
          response.statusCode,
          HttpStatus.forbidden,
          reason: 'cross-origin WebSocket upgrades must be refused with 403',
        );
        await response.drain<void>();
      } finally {
        client.close(force: true);
      }

      // An opaque origin ("null", e.g. sandboxed iframes) is not loopback.
      final nullOrigin = HttpClient();
      try {
        final request = await nullOrigin.getUrl(
          Uri.parse('http://127.0.0.1:$port/ws'),
        );
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
    test(
      'session lifecycle events fan out to every authenticated client',
      () async {
        await startServer();
        final a = await connect(server!.port);
        final b = await connect(server!.port);
        final dir = await Directory.systemTemp.createTemp('sd_fanout_');
        File(p.join(dir.path, 'example.txt'))
            .writeAsStringSync('hello from file\n');
        final project = Project.fromJson(
          (j(
                    await a.peer.call('projects.add', <String, Object?>{
                      'path': dir.path,
                    }),
                  )['project']!
                  as Map)
              .cast<String, Object?>(),
        );

        final created = j(
          await a.peer.call('sessions.create', <String, Object?>{
            'projectId': project.id,
            'providerId': 'fake',
          }),
        );
        final sessionId = (created['session']! as Map)['id']! as String;
        await untilRecorded(a, 'session.created', 1);
        await untilRecorded(b, 'session.created', 1);
        expect(a.of('session.created'), hasLength(1));
        expect(
          b.of('session.created'),
          hasLength(1),
          reason: 'creation announces to all clients',
        );

        // Both clients observe the full turn, parking at the permission.
        final bPermission = waitForEvent(
          b,
          (event) => event is PermissionRequestEvent,
        );
        final aPermission = waitForEvent(
          a,
          (event) => event is PermissionRequestEvent,
        );
        final send = a.peer.call('sessions.send', <String, Object?>{
          'sessionId': sessionId,
          'text': 'inspect',
        });

        final requestId = (SessionEvent.fromJson(
          ((await bPermission)['event']! as Map).cast<String, Object?>(),
        ) as PermissionRequestEvent).request.requestId;
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
        await a.peer.call('sessions.archive', <String, Object?>{
          'sessionId': sessionId,
          'archived': true,
        });
        await untilRecorded(a, 'session.updated', 1);
        await untilRecorded(b, 'session.updated', 1);
        expect(a.of('session.updated'), isNotEmpty);
        expect(b.of('session.updated'), isNotEmpty);

        await a.peer.call('sessions.delete', <String, Object?>{
          'sessionId': sessionId,
        });
        await untilRecorded(a, 'session.removed', 1);
        await untilRecorded(b, 'session.removed', 1);
        expect(a.of('session.removed'), hasLength(1));
        expect(b.of('session.removed'), hasLength(1));

        await a.close();
        await b.close();
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test('a fresh observer sees session.created before any session.updated '
        'for a new session', () async {
      await startServer();
      final a = await connect(server!.port);
      final fresh = await connect(server!.port);
      final dir = await Directory.systemTemp.createTemp('sd_created_first_');
      final project = Project.fromJson(
        (j(
                  await a.peer.call('projects.add', <String, Object?>{
                    'path': dir.path,
                  }),
                )['project']!
                as Map)
            .cast<String, Object?>(),
      );

      final created = j(
        await a.peer.call('sessions.create', <String, Object?>{
          'projectId': project.id,
          'providerId': 'fake',
        }),
      );
      final sessionId = (created['session']! as Map)['id']! as String;

      // Wait for created to arrive on the fresh observer, then trigger a
      // session.updated (rename) and confirm the ordering holds.
      await untilRecorded(fresh, 'session.created', 1);
      await a.peer.call('sessions.rename', <String, Object?>{
        'sessionId': sessionId,
        'title': 'Renamed',
      });
      await untilRecorded(fresh, 'session.updated', 1);

      final order = fresh.notifications
          .where(
            (n) =>
                (n.method == 'session.created' ||
                    n.method == 'session.updated') &&
                n.params['session'] is Map &&
                (n.params['session']! as Map)['id'] == sessionId,
          )
          .map((n) => n.method)
          .toList();
      expect(order, isNotEmpty);
      expect(
        order,
        contains('session.updated'),
        reason: 'the rename update must arrive at all',
      );
      expect(
        order.first,
        'session.created',
        reason:
            'the relay must not emit session.updated for a session '
            'before its session.created has been broadcast',
      );

      await a.close();
      await fresh.close();
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
