@TestOn('vm')
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_daemon/speeddial_daemon.dart';
import 'package:speeddial_daemon/src/client.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:test/test.dart';

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

  test('any-interface bind reports a loopback URL and serves the token', () async {
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
  });

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

  test('stop is idempotent', () async {
    final LocalDaemon daemon = await LocalDaemon.start(dbPath: db('f.db'));
    await daemon.stop();
    await daemon.stop();
  });
}

