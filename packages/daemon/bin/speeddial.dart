import 'dart:io';

import 'package:speeddial_daemon/src/cli/auto_update.dart';

import 'package:speeddial_daemon/src/cli/cli_runner.dart';
import 'package:speeddial_daemon/src/mcp/built_in_mcp_server.dart';

/// SpeedDial daemon and bookkeeping CLI.
Future<void> main(List<String> args) async {
  if (args.contains('serve') &&
      Platform.environment[daemonWorkerEnvironment] != '1') {
    String? root;
    try {
      final cwd = Directory.current.path;
      final candidate = await runUpdateGit(cwd, [
        'rev-parse',
        '--show-toplevel',
      ]);
      if (isSpeedDialRepository(candidate) &&
          await runUpdateGit(cwd, ['branch', '--show-current']) == 'main') {
        root = candidate;
      }
    } on Object catch (_) {
      // Normal invocation outside a Git checkout does not auto-update.
    }
    if (root != null) exit(await superviseDaemon(args, root));
  }
  final int code;
  if (args.length == 1 && args.single == kBuiltInMcpArgument) {
    code = await runBuiltInMcpServer();
  } else {
    code = await runCli(args);
  }
  await stdout.flush();
  await stderr.flush();
  exit(code);
}
