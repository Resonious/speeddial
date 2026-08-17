@TestOn('vm')
library;

import 'package:speeddial_daemon/src/cli/cli_runner.dart';
import 'package:test/test.dart';

void main() {
  group('runCli argument parsing', () {
    test('unknown top-level command exits 1', () async {
      expect(await runCli(['frobnicate']), 1);
    });

    test('unknown subcommand exits 1', () async {
      expect(await runCli(['projects', 'frobnicate']), 1);
    });

    test('branch command without a subcommand exits 1', () async {
      expect(await runCli(['projects']), 1);
      expect(await runCli(['sessions']), 1);
      expect(await runCli(['git']), 1);
    });

    test('git status without --project exits 1', () async {
      expect(await runCli(['git', 'status']), 1);
    });

    test('git commit without --project exits 1 even with -m', () async {
      expect(await runCli(['git', 'commit', '-m', 'wip']), 1);
    });

    test('git checkout is not a CLI command', () async {
      expect(await runCli(['git', 'checkout']), 1);
    });

    test('invalid --mode exits 1', () async {
      expect(await runCli(['sessions', 'create', '--project', 'p1',
          '--provider', 'omp', '--mode', 'bogus']), 1);
    });

    test('--help exits 0', () async {
      expect(await runCli(['--help']), 0);
    });

    test('usage errors are written to the provided stderr sink', () async {
      final err = StringBuffer();
      final code = await runCli(['frobnicate'], err: err);
      expect(code, 1);
      expect(err.toString(), contains('Could not find a command'));
      expect(err.toString(), contains('frobnicate'));
    });
  });
}
