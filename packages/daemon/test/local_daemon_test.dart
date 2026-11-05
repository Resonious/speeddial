@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_daemon/speeddial_daemon.dart';
import 'package:speeddial_daemon/src/client.dart';
import 'package:speeddial_daemon/src/store/daemon_store.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:test/test.dart';

typedef _BusySession = ({Session session, SessionEvent event});

List<_BusySession> _seedBusySessions(String path, String cwd) {
  final DaemonStore store = DaemonStore(path);
  try {
    final DateTime now = DateTime.now().toUtc();
    store.insertProject(
      Project(
        id: 'active-project',
        name: 'Active project',
        path: cwd,
        addedAt: now,
        lastActiveAt: now,
      ),
    );
    final List<_BusySession> seeded = <_BusySession>[];
    for (final (String id, SessionStatus status, bool preparing)
        in <(String, SessionStatus, bool)>[
          ('running', SessionStatus.running, false),
          ('waiting', SessionStatus.waitingPermission, false),
          ('preparing', SessionStatus.idle, true),
        ]) {
      final Session session = Session(
        id: id,
        projectId: 'active-project',
        providerId: 'fake',
        title: 'Active $id',
        status: status,
        model: null,
        cwd: cwd,
        baseBranch: null,
        yolo: false,
        preparing: preparing,
        archived: false,
        createdAt: now,
        updatedAt: now,
      );
      store.insertSession(session);
      final SessionEvent event = store.appendEvent(
        id,
        store.nextSeq(id),
        UserMessageEvent(text: 'Keep $id untouched'),
      );
      seeded.add((session: session, event: event));
    }
    return seeded;
  } finally {
    store.dispose();
  }
}

Future<void> _expectBusySessionsUnchanged(
  String path,
  DaemonClient client,
  List<_BusySession> seeded,
) async {
  final DaemonStore store = DaemonStore(path);
  try {
    final Map<String, Session> served = <String, Session>{
      for (final Session session in await client.listSessions())
        session.id: session,
    };
    expect(served, hasLength(seeded.length));
    for (final _BusySession entry in seeded) {
      final String id = entry.session.id;
      expect(store.getSession(id)!.toJson(), entry.session.toJson());
      expect(served[id]!.toJson(), entry.session.toJson());
      final List<Map<String, Object?>> expected = <Map<String, Object?>>[
        entry.event.toJson(),
      ];
      final persisted = store.listEvents(id);
      expect(
        persisted.events.map((SessionEvent event) => event.toJson()),
        expected,
      );
      expect(persisted.events.whereType<SessionErrorEvent>(), isEmpty);
      final history = await client.history(id);
      expect(
        history.events.map((SessionEvent event) => event.toJson()),
        expected,
      );
      expect(history.hasMore, isFalse);
    }
  } finally {
    store.dispose();
  }
}

void main() {
  late Directory tmpDir;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('speeddial_local_daemon');
  });

  tearDown(() {
    if (tmpDir.existsSync()) {
      tmpDir.deleteSync(recursive: true);
    }
  });

  String db(String name) => p.join(tmpDir.path, name);

  test('default start binds loopback on a free port without auth', () async {
    final LocalDaemon daemon = await LocalDaemon.start(dbPath: db('a.db'));
    addTearDown(daemon.stop);

    expect(daemon.host, '127.0.0.1');
    expect(daemon.url, startsWith('ws://127.0.0.1:'));
    expect(daemon.url, endsWith('/ws'));

    final DaemonClient client = await DaemonClient.connect(daemon.url);
    addTearDown(client.close);
    expect(client.daemonInfo!.authRequired, isFalse);
  });

  test('fixed port and token authenticate clients', () async {
    // Grab a free port, then release it for the daemon to bind.
    final ServerSocket probe = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final int port = probe.port;
    await probe.close();

    final LocalDaemon daemon = await LocalDaemon.start(
      port: port,
      authToken: 'sekret',
      dbPath: db('b.db'),
    );
    addTearDown(daemon.stop);

    expect(daemon.url, 'ws://127.0.0.1:$port/ws');

    // Without the token the client refuses the connection up front.
    await expectLater(
      DaemonClient.connect(daemon.url),
      throwsA(
        isA<DaemonError>().having(
          (DaemonError e) => e.code,
          'code',
          kErrUnauthenticated,
        ),
      ),
    );
    final DaemonClient client = await DaemonClient.connect(
      daemon.url,
      token: 'sekret',
    );
    addTearDown(client.close);
    expect(client.daemonInfo!.authRequired, isTrue);
  });

  test('non-loopback bind without a token is rejected', () async {
    await expectLater(
      LocalDaemon.start(host: '0.0.0.0', dbPath: db('c.db')),
      throwsA(isA<ArgumentError>()),
    );
  });

  test(
    'any-interface bind reports a loopback URL and serves the token',
    () async {
      final LocalDaemon daemon = await LocalDaemon.start(
        host: '0.0.0.0',
        authToken: 'net-token',
        dbPath: db('d.db'),
      );
      addTearDown(daemon.stop);

      expect(daemon.host, '0.0.0.0');
      expect(daemon.url, startsWith('ws://127.0.0.1:'));
      expect(daemon.url, endsWith('/ws'));

      final DaemonClient client = await DaemonClient.connect(
        daemon.url,
        token: 'net-token',
      );
      addTearDown(client.close);
    },
  );

  test('IPv6 any-interface bind reports a bracketed loopback URL', () async {
    final LocalDaemon? daemon;
    try {
      daemon = await LocalDaemon.start(
        host: '::',
        authToken: 'v6-token',
        dbPath: db('e.db'),
      );
    } on SocketException {
      // No IPv6 stack in this environment; nothing to verify.
      return;
    }
    addTearDown(daemon.stop);

    expect(daemon.url, startsWith('ws://[::1]:'));
    expect(daemon.url, endsWith('/ws'));

    final DaemonClient client = await DaemonClient.connect(
      daemon.url,
      token: 'v6-token',
    );
    addTearDown(client.close);
  });

  for (final bool samePort in <bool>[false, true]) {
    test('duplicate database on ${samePort ? 'the same' : 'a free'} port '
        'is refused before restoring active sessions', () async {
      final String path = db('duplicate.db');
      final LocalDaemon first = await LocalDaemon.start(dbPath: path);
      addTearDown(first.stop);
      // Seed after the first restore, without launching an agent. Close the
      // ordinary connection so only the daemon's ownership remains in play.
      final List<_BusySession> seeded = _seedBusySessions(path, tmpDir.path);
      final DaemonClient client = await DaemonClient.connect(first.url);
      addTearDown(client.close);

      await expectLater(
        LocalDaemon.start(dbPath: path, port: samePort ? first.port : 0).then((
          LocalDaemon duplicate,
        ) {
          addTearDown(duplicate.stop);
          return duplicate;
        }),
        throwsA(
          isA<DaemonError>()
              .having((DaemonError e) => e.code, 'code', kErrConflict)
              .having(
                (DaemonError e) => e.message.toLowerCase(),
                'message',
                allOf(contains('already'), contains('database')),
              ),
        ),
      );

      await _expectBusySessionsUnchanged(path, client, seeded);
      // Existing and new connections must both still reach the first daemon.
      final DaemonClient reconnected = await DaemonClient.connect(first.url);
      addTearDown(reconnected.close);
      expect(await reconnected.listProjects(), hasLength(1));
    });
  }

  test('CLI serve cannot restore a database owned by LocalDaemon', () async {
    final String path = db('cli-duplicate.db');
    final LocalDaemon first = await LocalDaemon.start(dbPath: path);
    addTearDown(first.stop);
    final List<_BusySession> seeded = _seedBusySessions(path, tmpDir.path);
    final DaemonClient client = await DaemonClient.connect(first.url);
    addTearDown(client.close);

    final String packageDir = File('bin/speeddial.dart').existsSync()
        ? Directory.current.path
        : p.join(Directory.current.path, 'packages', 'daemon');
    final String home = p.join(tmpDir.path, 'home');
    Directory(home).createSync();
    final Map<String, String> environment =
        Map<String, String>.from(Platform.environment)
          ..remove('SPEEDIAL_TOKEN')
          ..remove('SPEEDIAL_DB')
          ..['HOME'] = home
          ..['USERPROFILE'] = home;
    final Process process = await Process.start(
      Platform.resolvedExecutable,
      <String>[
        p.join(packageDir, 'bin', 'speeddial.dart'),
        'serve',
        '--db',
        path,
        '--port',
        '0',
      ],
      workingDirectory: tmpDir.path,
      environment: environment,
      includeParentEnvironment: false,
    );
    addTearDown(() async {
      process.kill();
      await process.exitCode;
    });
    final Future<String> output = process.stdout.transform(utf8.decoder).join();
    final Future<String> errors = process.stderr.transform(utf8.decoder).join();
    final int exitCode = await process.exitCode.timeout(
      const Duration(seconds: 20),
    );
    final String diagnostic = '${await output}\n${await errors}'.toLowerCase();
    expect(exitCode, 3, reason: diagnostic);
    expect(diagnostic, contains('$kErrConflict'));
    expect(diagnostic, allOf(contains('already'), contains('database')));
    await _expectBusySessionsUnchanged(path, client, seeded);
  });

  test('stopping releases database ownership for a new daemon', () async {
    final String path = db('restart.db');
    final LocalDaemon first = await LocalDaemon.start(dbPath: path);
    addTearDown(first.stop);
    await first.stop();

    final LocalDaemon second = await LocalDaemon.start(dbPath: path);
    addTearDown(second.stop);
    final DaemonClient client = await DaemonClient.connect(second.url);
    addTearDown(client.close);
    expect(await client.listProjects(), isEmpty);
  });

  test('bind failure releases database ownership for a retry', () async {
    final String path = db('bind-failure.db');
    final ServerSocket occupied = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(occupied.close);
    final int port = occupied.port;

    await expectLater(
      LocalDaemon.start(dbPath: path, port: port).then((LocalDaemon daemon) {
        addTearDown(daemon.stop);
        return daemon;
      }),
      throwsA(isA<SocketException>()),
    );
    await occupied.close();

    final LocalDaemon retry = await LocalDaemon.start(dbPath: path, port: port);
    addTearDown(retry.stop);
    final DaemonClient client = await DaemonClient.connect(retry.url);
    addTearDown(client.close);
    expect(await client.listProjects(), isEmpty);
  });

  test('stop is idempotent', () async {
    final LocalDaemon daemon = await LocalDaemon.start(dbPath: db('f.db'));
    await daemon.stop();
    await daemon.stop();
  });
}
