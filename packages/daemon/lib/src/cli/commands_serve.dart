/// `serve` and `token` commands: run the daemon and inspect its auth token.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;
import 'package:speeddial_daemon/src/client.dart';
import 'package:speeddial_daemon/src/engine/session_engine.dart';
import 'package:speeddial_daemon/src/git/git_service.dart';
import 'package:speeddial_daemon/src/git/pr_service.dart';
import 'package:speeddial_daemon/src/providers/provider_registry.dart';
import 'package:speeddial_daemon/src/server/ws_server.dart';
import 'package:speeddial_daemon/src/store/daemon_store.dart';

import 'cli_runner.dart';

/// `speeddial serve` — runs the daemon until SIGINT/SIGTERM.
class ServeCommand extends Command<int> {
  ServeCommand() {
    argParser
      ..addOption('port',
          defaultsTo: '7331',
          help: 'Port to listen on (default: 7331; 0 picks a free port).')
      ..addOption('host',
          defaultsTo: '127.0.0.1',
          help: 'Interface to bind (default: 127.0.0.1).')
      ..addOption('token',
          help: 'Auth token; overrides \$SPEEDIAL_TOKEN. A crypto-random token '
              'is generated and printed when binding non-loopback without one.')
      ..addOption('db',
          help: 'SQLite database path (default: ~/.speeddial/speeddial.db, '
              'overridable with \$SPEEDIAL_DB).');
  }

  @override
  final String name = 'serve';

  @override
  final String description = 'Run the SpeedDial daemon.';

  @override
  bool get takesArguments => false;

  @override
  Future<int> run() async {
    final host = argResults!['host'] as String;
    final portRaw = argResults!['port'] as String;
    final port = int.tryParse(portRaw);
    if (port == null) {
      throw UsageException('Invalid --port value: "$portRaw".', '');
    }
    final dbPath = argResults!['db'] as String? ??
        Platform.environment['SPEEDIAL_DB'] ??
        p.join(speeddialHomeDir(), 'speeddial.db');
    Directory(p.dirname(dbPath)).createSync(recursive: true);

    final store = DaemonStore(dbPath);
    final providers = ProviderRegistry();
    final engine = SessionEngine(store: store, providers: providers);
    final git = GitService();
    final pr = PrService();
    await engine.restore();

    final nonLoopback = !_isLoopbackHost(host);
    final token = argResults!['token'] as String? ??
        Platform.environment['SPEEDIAL_TOKEN'];
    final String? authToken;
    final bool generated;
    if (token == null && nonLoopback) {
      authToken = _generateToken();
      generated = true;
    } else {
      authToken = token;
      generated = false;
    }
    if (generated) {
      stdout.writeln('Auth token: $authToken');
    }

    final SpeedDialServer server;
    try {
      server = await SpeedDialServer.bind(
        host: host,
        port: port,
        engine: engine,
        store: store,
        providers: providers,
        authToken: authToken,
        git: git,
        pr: pr,
      );
    } on Object {
      // Do not leak the engine/store when binding fails.
      await engine.dispose();
      store.dispose();
      rethrow;
    }

    await _writeDiscoveryFile(
      host: host,
      port: server.port,
      token: authToken,
      pid: _currentPid(),
    );
    stdout
        .writeln('speeddial daemon listening on ws://$host:${server.port}$kWsPath');

    final done = Completer<void>();
    Future<void> shutdown() async {
      if (done.isCompleted) return;
      await engine.dispose();
      await server.close();
      store.dispose();
      _deleteDiscoveryFile();
      stdout.writeln('speeddial daemon stopped');
      done.complete();
    }

    final subscriptions = <StreamSubscription<ProcessSignal>>[
      for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm])
        signal.watch().listen((_) => shutdown()),
    ];
    await done.future;
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    return Exit.ok;
  }
}

/// `speeddial token` — prints the auth token of the running daemon (read from
/// the discovery file; does not connect).
class TokenCommand extends Command<int> {
  @override
  final String name = 'token';

  @override
  final String description = 'Print the auth token of the running daemon.';

  @override
  bool get takesArguments => false;

  @override
  Future<int> run() async {
    final discovery = readDiscoveryFile();
    if (discovery == null) {
      stderr.writeln('speeddial: no discovery file at '
          '${p.join(speeddialHomeDir(), 'daemon.json')} — is the daemon running?');
      return Exit.unreachable;
    }
    final token = discovery['token'];
    if (token is! String || token.isEmpty) {
      stderr.writeln('speeddial: the running daemon has no auth token '
          '(loopback-only daemon).');
      return Exit.unreachable;
    }
    stdout.writeln(token);
    return Exit.ok;
  }
}

bool _isLoopbackHost(String host) =>
    host == '127.0.0.1' || host == '::1' || host == 'localhost';

/// A crypto-secure random token: 12 random bytes hex-encoded (24 chars).
String _generateToken() {
  final random = Random.secure();
  final buffer = StringBuffer();
  for (var i = 0; i < 12; i++) {
    buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

/// The current process id, best-effort (reads `/proc/self/stat` on Linux);
/// null when unavailable.
int? _currentPid() {
  try {
    final stat = File('/proc/self/stat').readAsStringSync();
    final end = stat.indexOf(' ');
    if (end > 0) return int.tryParse(stat.substring(0, end));
  } on Object {
    // Non-Linux platform: omit pid from the discovery file.
  }
  return null;
}

/// Atomically writes `~/.speeddial/daemon.json` (temp file + rename),
/// restricted to the owner (0600) because it carries the auth token.
Future<void> _writeDiscoveryFile({
  required String host,
  required int port,
  required String? token,
  required int? pid,
}) async {
  final dir = Directory(speeddialHomeDir());
  dir.createSync(recursive: true);
  final data = <String, Object?>{
    'port': port,
    'host': host,
    'token': ?token,
    'pid': ?pid,
  };
  final target = p.join(dir.path, 'daemon.json');
  final tmp = File(p.join(dir.path, 'daemon.json.tmp'));
  tmp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(data));
  tmp.renameSync(target);
  await _chmod0600(target);
}

/// Best-effort `chmod 0600` on [path]. `dart:io` has no chmod, so the
/// external `chmod` binary is used on POSIX platforms; elsewhere the file is
/// left as created.
Future<void> _chmod0600(String path) async {
  if (!Platform.isLinux && !Platform.isMacOS) return;
  try {
    await Process.run('chmod', ['0600', path]);
  } on ProcessException {
    // Best-effort: the discovery file was still written.
  }
}

/// Removes the discovery file on shutdown (best-effort).
void _deleteDiscoveryFile() {
  try {
    final file = File(p.join(speeddialHomeDir(), 'daemon.json'));
    if (file.existsSync()) file.deleteSync();
  } on FileSystemException {
    // Nothing useful to do if cleanup fails.
  }
}
