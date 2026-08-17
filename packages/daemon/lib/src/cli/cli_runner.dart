/// `speeddial` CLI: argument parsing, daemon discovery/connection resolution,
/// dispatch, and exit-code mapping.
///
/// Exit codes: 0 ok, 1 usage error, 2 daemon unreachable, 3 [DaemonError].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart' show ArgResults;
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;
import 'package:speeddial_daemon/src/client.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import 'commands_git.dart';
import 'commands_projects.dart';
import 'commands_serve.dart';
import 'commands_sessions.dart';

/// Process exit codes for the `speeddial` CLI.
abstract final class Exit {
  static const int ok = 0;
  static const int usage = 1;
  static const int unreachable = 2;
  static const int daemonError = 3;
}

/// Runs [args] through the CLI to completion and returns the process exit
/// code. [err] captures usage/error output (defaults to stderr).
Future<int> runCli(List<String> args, {StringSink? err}) async {
  final errorSink = err ?? stderr;
  final runner = _runner();
  try {
    final result = await runner.run(args);
    // null only for `--help` / bare invocation (usage printed).
    return result ?? Exit.ok;
  } on UsageException catch (e) {
    errorSink.writeln(e.message);
    errorSink.writeln();
    errorSink.writeln(e.usage.trimRight());
    return Exit.usage;
  } on DaemonError catch (e) {
    errorSink.writeln('speeddial: error (${e.code}): ${e.message}');
    return Exit.daemonError;
  } on WebSocketException catch (e) {
    errorSink.writeln('speeddial: cannot reach daemon: ${e.message}');
    return Exit.unreachable;
  } on SocketException catch (e) {
    errorSink.writeln('speeddial: cannot reach daemon: ${e.message}');
    return Exit.unreachable;
  } on TimeoutException catch (e) {
    errorSink.writeln('speeddial: cannot reach daemon: $e');
    return Exit.unreachable;
  } on Object catch (e) {
    errorSink.writeln('speeddial: internal error: $e');
    return Exit.usage;
  }
}

CommandRunner<int> _runner() {
  final runner = CommandRunner<int>(
    'speeddial',
    'SpeedDial daemon and project bookkeeping CLI.\n\n'
    'Run "speeddial serve" to start the daemon; every other command talks to '
    'a running daemon, discovered from ~/.speeddial/daemon.json unless '
    '--host/--port are given.',
  )
    ..addCommand(ServeCommand())
    ..addCommand(TokenCommand())
    ..addCommand(ProjectsCommand())
    ..addCommand(SessionsCommand())
    ..addCommand(GitCommand());
  runner.argParser
    ..addFlag('json',
        negatable: false, help: 'Print raw JSON instead of human-readable tables.')
    ..addOption('host',
        abbr: 'H',
        help: 'Daemon host (defaults to the discovery file, then 127.0.0.1).')
    ..addOption('port',
        abbr: 'P',
        help: 'Daemon port (defaults to the discovery file, then 7331).')
    ..addOption('token',
        help: 'Auth token (overrides \$SPEEDIAL_TOKEN and the discovery file).');
  return runner;
}

/// `~/.speeddial` — the daemon's data directory.
String speeddialHomeDir() {
  final home = Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      Directory.current.path;
  return p.join(home, '.speeddial');
}

/// Loads `~/.speeddial/daemon.json` ({port, host, token, pid}); null when the
/// file is missing or malformed.
Map<String, Object?>? readDiscoveryFile() {
  final file = File(p.join(speeddialHomeDir(), 'daemon.json'));
  if (!file.existsSync()) return null;
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    return decoded is Map ? Map<String, Object?>.from(decoded) : null;
  } on FormatException {
    return null;
  }
}

/// Connection parameters for bookkeeping commands.
///
/// Host/port come from `--host`/`--port` when given, else from the discovery
/// file, else the PROTOCOL.md defaults (`127.0.0.1:7331`). The token ranks
/// `--token` > `$SPEEDIAL_TOKEN` > the discovery file.
({String url, String? token, bool json}) resolveConnection(ArgResults global) {
  final hostFlag = global['host'] as String?;
  final portFlag = global['port'] as String?;
  if (portFlag != null && int.tryParse(portFlag) == null) {
    throw UsageException('Invalid --port value: "$portFlag".', '');
  }

  final discovery =
      hostFlag == null && portFlag == null ? readDiscoveryFile() : null;
  final discoveryHost = discovery?['host'];
  final discoveryPort = discovery?['port'];
  final host = hostFlag ?? (discoveryHost is String ? discoveryHost : '127.0.0.1');
  final port = portFlag ??
      (discoveryPort is int
          ? '$discoveryPort'
          : discoveryPort is String
              ? discoveryPort
              : '7331');
  final discoveryToken = discovery?['token'];
  final token = global['token'] as String? ??
      Platform.environment['SPEEDIAL_TOKEN'] ??
      (discoveryToken is String ? discoveryToken : null);
  return (url: 'ws://$host:$port$kWsPath', token: token, json: global.flag('json'));
}

/// Connects to the daemon resolved for [conn] and runs [body] with the live
/// client, always closing it afterwards.
Future<T> withDaemon<T>(
  ({String url, String? token, bool json}) conn,
  Future<T> Function(DaemonClient client) body,
) async {
  final client = await DaemonClient.connect(conn.url, token: conn.token);
  try {
    return await body(client);
  } finally {
    await client.close();
  }
}
