import 'dart:async';

import 'package:speeddial_daemon/src/cli/auto_update.dart';
import 'package:test/test.dart';

void main() {
  late DaemonAutoUpdate updater;
  late List<String> commands;
  late List<String> logs;
  late String branch;
  late String commit;
  late bool idle;
  late bool recognized;
  late bool failPull;
  late int restarts;
  Completer<void>? pull;

  setUp(() {
    commands = [];
    logs = [];
    branch = 'main';
    commit = 'boot';
    idle = true;
    recognized = true;
    failPull = false;
    restarts = 0;
    pull = null;
    updater = DaemonAutoUpdate(
      git: (arguments) async {
        final command = arguments.join(' ');
        commands.add(command);
        switch (command) {
          case 'rev-parse --show-toplevel':
            return '/repo';
          case 'branch --show-current':
            return branch;
          case 'rev-parse HEAD':
            return commit;
          case 'pull --ff-only':
            if (failPull) throw StateError('offline');
            await pull?.future;
            return '';
          default:
            throw StateError(command);
        }
      },
      isIdle: () => idle,
      isSpeedDial: (_) => recognized,
      restart: () async {
        restarts++;
      },
      log: logs.add,
    );
  });

  test(
    'records boot HEAD, pulls at idle, restarts only for a new commit',
    () async {
      await updater.initialize();
      expect(updater.initialCommit, 'boot');
      await updater.check();
      expect(restarts, 0);
      commit = 'updated';
      await updater.check();
      await updater.check();
      expect(restarts, 1);
      expect(
        commands.where((command) => command == 'pull --ff-only'),
        hasLength(2),
      );
    },
  );

  test('does not pull while sessions are active', () async {
    await updater.initialize();
    idle = false;
    await updater.check();
    expect(commands, isNot(contains('pull --ff-only')));
    idle = true;
    await updater.check();
    expect(commands, contains('pull --ff-only'));
  });

  test(
    'defers restart if a session starts during pull and serializes checks',
    () async {
      await updater.initialize();
      pull = Completer<void>();
      final checking = updater.check();
      await Future<void>.delayed(Duration.zero);
      await updater.check();
      idle = false;
      commit = 'updated';
      pull!.complete();
      await checking;
      expect(restarts, 0);
      idle = true;
      await updater.check();
      expect(restarts, 1);
      expect(
        commands.where((command) => command == 'pull --ff-only'),
        hasLength(1),
      );
    },
  );

  for (final value in ['feature', '']) {
    test('disabled on branch "$value" at boot', () async {
      branch = value;
      await updater.initialize();
      await updater.check();
      expect(updater.initialCommit, isNull);
      expect(commands, isNot(contains('pull --ff-only')));
    });
  }

  test('disabled outside the SpeedDial repo', () async {
    recognized = false;
    await updater.initialize();
    await updater.check();
    expect(commands, ['rev-parse --show-toplevel']);
  });

  test('rechecks branch before pulling', () async {
    await updater.initialize();
    branch = 'feature';
    await updater.check();
    expect(commands, isNot(contains('pull --ff-only')));
  });

  test('logs pull failure and allows retry', () async {
    await updater.initialize();
    failPull = true;
    commit = 'updated';
    await updater.check();
    expect(restarts, 0);
    expect(logs.last, contains('offline'));
    failPull = false;
    await updater.check();
    expect(restarts, 1);
  });

  test('shutdown during pull prevents restart', () async {
    await updater.initialize();
    pull = Completer<void>();
    final checking = updater.check();
    await Future<void>.delayed(Duration.zero);
    updater.stop();
    commit = 'updated';
    pull!.complete();
    await checking;
    expect(restarts, 0);
  });
}
