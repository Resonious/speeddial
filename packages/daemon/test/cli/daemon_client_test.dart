/// End-to-end [DaemonClient] tests against a REAL [SpeedDialServer] bound on
/// `127.0.0.1:0` with a temp-dir [DaemonStore] - no mocks anywhere on the
/// wire.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_daemon/src/client.dart';
import 'package:speeddial_daemon/src/engine/session_engine.dart';
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

/// A registry whose only provider is the fake ACP fixture.
ProviderRegistry fakeProviders() =>
    ProviderRegistry(configOverrides: <String, Object?>{
      'providers': <String, Object?>{
        'fake': <String, Object?>{
          'name': 'Fake Agent',
          'command': <String>[Platform.resolvedExecutable, resolveFixture()],
        },
      },
    });

void main() {
  const token = 'test-token';
  late Directory tempDir;
  late DaemonStore store;
  late SessionEngine engine;
  late SpeedDialServer server;
  late String url;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('daemon_client_test');
    store = DaemonStore(p.join(tempDir.path, 'speeddial.db'));
    final providers = fakeProviders();
    engine = SessionEngine(store: store, providers: providers);
    await engine.restore();
    server = await SpeedDialServer.bind(
      host: '127.0.0.1',
      port: 0,
      engine: engine,
      store: store,
      providers: providers,
      authToken: token,
    );
    url = 'ws://127.0.0.1:${server.port}$kWsPath';
  });

  tearDown(() async {
    await server.close();
    await engine.dispose();
    store.dispose();
    try {
      await tempDir.delete(recursive: true);
    } on Object {
      // Best-effort cleanup; not a test failure.
    }
  });

  test('connect authenticates; info reports the daemon identity', () async {
    final client = await DaemonClient.connect(url, token: token);
    final info = await client.info();
    expect(info.protocolVersion, 1);
    expect(info.authRequired, isTrue);
    expect(info.providers.map((provider) => provider.id), contains('fake'));
    expect(client.daemonInfo, isNotNull);
    await client.close();
  });

  test('connect without a token fails unauthenticated', () async {
    await expectLater(
      DaemonClient.connect(url),
      throwsA(
        isA<DaemonError>().having((e) => e.code, 'code', kErrUnauthenticated),
      ),
    );
  });

  test('connect with a wrong token fails', () async {
    await expectLater(
      DaemonClient.connect(url, token: 'wrong-token'),
      throwsA(isA<DaemonError>()),
    );
  });

  test('listProjects/addProject roundtrip', () async {
    final client = await DaemonClient.connect(url, token: token);
    expect(await client.listProjects(), isEmpty);

    final added = await client.addProject(tempDir.path);
    expect(added.path, tempDir.path);
    expect(added.name, isNotEmpty);

    final projects = await client.listProjects();
    expect(projects.map((project) => project.id), contains(added.id));

    await client.removeProject(added.id);
    expect(await client.listProjects(), isEmpty);
    await client.close();
  });

  test('notifications receive session.created and session.updated broadcasts',
      () async {
    final client = await DaemonClient.connect(url, token: token);
    final project = await client.addProject(tempDir.path);

    final created = Completer<Session>();
    final updated = Completer<Session>();
    final subscription = client.notifications.listen((notification) {
      if (notification.method == 'session.created') {
        created.complete(
          Session.fromJson(
            (notification.params['session']! as Map).cast<String, Object?>(),
          ),
        );
      } else if (notification.method == 'session.updated') {
        // The engine also publishes `session.updated` at create time; only the
        // rename's broadcast has the new title.
        final session = Session.fromJson(
          (notification.params['session']! as Map).cast<String, Object?>(),
        );
        if (session.title == 'Renamed' && !updated.isCompleted) {
          updated.complete(session);
        }
      }
    });

    final session = await client.createSession(
      projectId: project.id,
      providerId: 'fake',
    );
    final createdSession = await created.future.timeout(
      const Duration(seconds: 5),
    );
    expect(createdSession.id, session.id);
    expect(createdSession.status, SessionStatus.idle);

    await client.renameSession(session.id, 'Renamed');
    final updatedSession = await updated.future.timeout(
      const Duration(seconds: 5),
    );
    expect(updatedSession.title, 'Renamed');

    await subscription.cancel();
    await client.close();
  });
}
