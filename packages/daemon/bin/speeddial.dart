import 'dart:io';

import 'package:speeddial_daemon/src/cli/cli_runner.dart';
import 'package:speeddial_daemon/src/mcp/built_in_mcp_server.dart';

/// SpeedDial daemon and bookkeeping CLI.
Future<void> main(List<String> args) async {
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
