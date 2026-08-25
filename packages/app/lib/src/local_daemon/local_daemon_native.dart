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
  Object? _lastError;

  @override
  bool get isRunning => _daemon != null;

  @override
  Object? get lastError => _lastError;

  @override
  Future<String?> start({
    String host = '127.0.0.1',
    int port = 0,
    String token = '',
  }) async {
    if (_daemon != null) return _url;
    if (_starting) return null;
    _starting = true;
    try {
      final daemon = await LocalDaemon.start(
        host: host,
        port: port,
        authToken: token.isEmpty ? null : token,
      );
      _daemon = daemon;
      _url = daemon.url;
      _lastError = null;
      return _url;
    } on Object catch (error) {
      _lastError = error;
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

LocalDaemonController platformControllerImpl() =>
    LocalDaemonControllerNative();
