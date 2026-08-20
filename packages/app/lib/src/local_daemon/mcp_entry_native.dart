import 'dart:io';

import 'package:speeddial_daemon/speeddial_daemon.dart';

/// Runs the hidden MCP subprocess mode before Flutter initializes. Returns
/// false for every normal app launch; the MCP path exits with its status code.
Future<bool> runMcpIfRequested(List<String> args) async {
  if (args.length != 1 || args.single != kBuiltInMcpArgument) return false;
  exit(await runBuiltInMcpServer());
}
