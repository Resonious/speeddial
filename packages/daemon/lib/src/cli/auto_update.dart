import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

typedef UpdateGit = Future<String> Function(List<String> arguments);

/// Repository checks and idle update policy, independent of process lifecycle.
class DaemonAutoUpdate {
  DaemonAutoUpdate({
    required this.git,
    required this.isIdle,
    required this.restart,
    required this.log,
    required this.isSpeedDial,
  });

  final UpdateGit git;
  final bool Function() isIdle;
  final Future<void> Function() restart;
  final void Function(String) log;
  final bool Function(String root) isSpeedDial;
  String? initialCommit;
  bool _checking = false;
  bool _stopped = false;
  bool _changed = false;

  Future<void> initialize() async {
    try {
      final candidate = await git(['rev-parse', '--show-toplevel']);
      if (!isSpeedDial(candidate) ||
          await git(['branch', '--show-current']) != 'main') {
        return;
      }
      initialCommit = await git(['rev-parse', 'HEAD']);
      log('Auto-update enabled at $initialCommit');
    } on Object catch (error) {
      log('Auto-update unavailable: $error');
    }
  }

  void stop() => _stopped = true;

  Future<void> check() async {
    if (_stopped || _checking || initialCommit == null || !isIdle()) return;
    _checking = true;
    try {
      if (await git(['branch', '--show-current']) != 'main') return;
      if (_stopped || !isIdle()) return;
      if (!_changed) {
        // Never create an unattended merge commit or prompt for credentials.
        await git(['pull', '--ff-only']);
        _changed = await git(['rev-parse', 'HEAD']) != initialCommit;
      }
      if (await git(['branch', '--show-current']) != 'main') return;
      // A turn may have started while Git was running. Defer the restart.
      if (_changed && !_stopped && isIdle()) {
        _stopped = true;
        log('Auto-update changed HEAD; restarting daemon');
        await restart();
      }
    } on Object catch (error) {
      log('Auto-update failed: $error');
    } finally {
      _checking = false;
    }
  }
}

bool isSpeedDialRepository(String root) {
  final manifest = File(p.join(root, 'pubspec.yaml'));
  return manifest.existsSync() &&
      RegExp(
        r'^name:\s*speeddial_workspace\s*$',
        multiLine: true,
      ).hasMatch(manifest.readAsStringSync()) &&
      File(p.join(root, 'packages/daemon/bin/speeddial.dart')).existsSync();
}

Future<String> runUpdateGit(String cwd, List<String> arguments) async {
  final process = await Process.start(
    'git',
    arguments,
    workingDirectory: cwd,
    environment: {
      'GIT_TERMINAL_PROMPT': '0',
      'GIT_SSH_COMMAND': 'ssh -oBatchMode=yes',
    },
  );
  final output = process.stdout.transform(systemEncoding.decoder).join();
  final errors = process.stderr.transform(systemEncoding.decoder).join();
  final timeout = Timer(
    const Duration(minutes: 2),
    () => process.kill(ProcessSignal.sigkill),
  );
  try {
    final code = await process.exitCode;
    final results = await Future.wait([output, errors]);
    if (code != 0) throw ProcessException('git', arguments, results[1], code);
    return results[0].trim();
  } finally {
    timeout.cancel();
  }
}

const daemonRestartExitCode = 75;
const daemonWorkerEnvironment = 'SPEEDDIAL_DAEMON_WORKER';

/// Keep one supervisor alive across updates (including under service managers).
Future<int> superviseDaemon(List<String> args, String root) async {
  final executable =
      p.basenameWithoutExtension(Platform.resolvedExecutable) == 'dart'
      ? Platform.resolvedExecutable
      : 'dart';
  final environment = <String, String>{daemonWorkerEnvironment: '1'};
  // Preserve automatically generated authentication across worker restarts.
  final hostIndex = args.indexOf('--host');
  final host = hostIndex >= 0 && hostIndex + 1 < args.length
      ? args[hostIndex + 1]
      : args
            .where((arg) => arg.startsWith('--host='))
            .map((arg) => arg.substring(7))
            .firstOrNull;
  if (host != null && !['localhost', '127.0.0.1', '::1'].contains(host)) {
    final random = Random.secure();
    environment['SPEEDIAL_TOKEN'] =
        Platform.environment['SPEEDIAL_TOKEN'] ??
        List<int>.generate(
          24,
          (_) => random.nextInt(256),
        ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }
  final explicitToken = args.any(
    (arg) => arg == '--token' || arg.startsWith('--token='),
  );
  if (environment.containsKey('SPEEDIAL_TOKEN') &&
      !Platform.environment.containsKey('SPEEDIAL_TOKEN') &&
      !explicitToken) {
    stdout.writeln('Auth token: ${environment['SPEEDIAL_TOKEN']}');
  }
  while (true) {
    final process = await Process.start(
      executable,
      ['run', p.join(root, 'packages/daemon/bin/speeddial.dart'), ...args],
      environment: environment,
      mode: ProcessStartMode.inheritStdio,
    );
    var stopping = false;
    final subscriptions = [
      for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm])
        signal.watch().listen((_) {
          stopping = true;
          process.kill(signal);
        }),
    ];
    final code = await process.exitCode;
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    if (stopping || code != daemonRestartExitCode) return code;
  }
}
