/// Desktop [LocalDaemonController] backed by `package:speeddial_daemon`'s
/// [LocalDaemon]. Imported via the conditional export in `local_daemon.dart`
/// only on linux/macos/windows builds, so `dart:io` and the daemon package
/// are guaranteed available here.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:speeddial_daemon/speeddial_daemon.dart';

import 'local_daemon_controller.dart';

/// A [LocalDaemonController] that runs the daemon in this process.
class LocalDaemonControllerNative implements LocalDaemonController {
  LocalDaemon? _daemon;
  String? _url;
  bool _starting = false;

  @override
  bool get isRunning => _daemon != null;

  @override
  Future<String?> start() async {
    if (_daemon != null) return _url;
    if (_starting) return null;
    _starting = true;
    try {
      final daemon = await LocalDaemon.start();
      _daemon = daemon;
      _url = daemon.url;
      return _url;
    } on Object catch (error) {
      if (kDebugMode) {
        debugPrint('embedded daemon failed to start: $error');
      }
      return null;
    } finally {
      _starting = false;
    }
  }

  @override
  Future<void> stop() async {
    final daemon = _daemon;
    _daemon = null;
    _url = null;
    if (daemon == null) return;
    try {
      await daemon.stop();
    } on Object catch (error) {
      if (kDebugMode) {
        debugPrint('embedded daemon shutdown error: $error');
      }
    }
  }
}

/// Factory selected by the conditional import in `local_daemon.dart`.
LocalDaemonController platformControllerImpl() =>
    LocalDaemonControllerNative();
