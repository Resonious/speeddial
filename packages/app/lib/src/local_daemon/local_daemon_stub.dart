/// Unsupported-platform [LocalDaemonController]: `dart:io` is absent on the
/// web and the daemon shells out to `git`/agent CLIs absent on mobile, so the
/// stub reports unsupported on every non-desktop build. Imported via the
/// conditional export in `local_daemon.dart`.
library;

import 'local_daemon_controller.dart';

/// A [LocalDaemonController] that never starts anything.
class LocalDaemonControllerStub implements LocalDaemonController {
  const LocalDaemonControllerStub();

  @override
  Future<String?> start({
    String host = '127.0.0.1',
    int port = 0,
    String token = '',
  }) async => null;

  @override
  Future<void> stop() async {}

  @override
  bool get isRunning => false;

  @override
  Object? get lastError => null;
}


/// Factory selected by the conditional import in `local_daemon.dart`.
LocalDaemonController platformControllerImpl() =>
    const LocalDaemonControllerStub();
