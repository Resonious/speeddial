import 'dart:io';

import 'package:speeddial_daemon/src/cli/cli_runner.dart';

/// SpeedDial daemon and bookkeeping CLI.
Future<void> main(List<String> args) async {
  final code = await runCli(args);
  await stdout.flush();
  await stderr.flush();
  exit(code);
}
