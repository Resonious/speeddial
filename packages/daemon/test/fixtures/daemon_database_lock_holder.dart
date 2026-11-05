import 'dart:io';

import 'package:speeddial_daemon/src/store/daemon_store.dart';

/// Own the database until the test kills this process (or closes its stdin).
Future<void> main(List<String> arguments) async {
  final store = DaemonStore.forDaemon(arguments.single);
  try {
    stdout.writeln('ready');
    await stdout.flush();
    await stdin.drain<void>();
  } finally {
    store.dispose();
  }
}
