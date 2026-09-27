/// Desktop daemon hosted on a dedicated isolate. Only lifecycle messages cross
/// this boundary; app clients continue to use the normal WebSocket API.
library;

import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:speeddial_daemon/speeddial_daemon.dart';

import 'local_daemon_controller.dart';

/// Created and disposed entirely inside the worker isolate.
typedef DaemonInstance = ({String url, Future<void> Function() stop});
typedef DaemonStarter = Future<DaemonInstance> Function(
  String host,
  int port,
  String token,
);

Future<DaemonInstance> _startDaemon(String host, int port, String token) async {
  final LocalDaemon daemon = await LocalDaemon.start(
    host: host,
    port: port,
    authToken: token.isEmpty ? null : token,
  );
  return (url: daemon.url, stop: daemon.stop);
}

class LocalDaemonControllerNative implements LocalDaemonController {
  LocalDaemonControllerNative() : _starter = _startDaemon;

  /// The starter must be sendable to an isolate; prefer a top-level function.
  @visibleForTesting
  LocalDaemonControllerNative.withStarter(DaemonStarter starter)
    : _starter = starter;

  final DaemonStarter _starter;
  _DaemonWorker? _worker;
  Object? _lastError;

  @override
  bool get isRunning => _worker?.url != null;

  @override
  Object? get lastError => _worker?.error ?? _lastError;

  @override
  Future<String?> start({
    String host = '127.0.0.1',
    int port = 0,
    String token = '',
  }) async {
    final _DaemonWorker? current = _worker;
    if (current != null) return current.url;
    final _DaemonWorker worker = _DaemonWorker();
    _worker = worker;
    _lastError = null;
    unawaited(
      worker.exited.future.then((_) {
        if (identical(_worker, worker)) {
          _lastError = worker.error;
          _worker = null;
        }
      }),
    );
    await worker.spawn(_starter, host, port, token);
    final String? url = await worker.ready.future;
    // Failed starts are fully cleaned up before callers can retry.
    if (url == null) await worker.exited.future;
    return worker.stopping ? null : url;
  }

  @override
  Future<void> stop() async {
    final _DaemonWorker? worker = _worker;
    if (worker == null) return;
    worker.requestStop();
    await worker.exited.future;
  }
}

class _DaemonWorker {
  _DaemonWorker() {
    _messages.listen(_onMessage);
  }

  final ReceivePort _messages = ReceivePort();
  final Completer<String?> ready = Completer<String?>();
  final Completer<void> exited = Completer<void>();
  SendPort? _commands;
  String? url;
  Object? error;
  bool stopping = false;

  Future<void> spawn(
    DaemonStarter starter,
    String host,
    int port,
    String token,
  ) async {
    try {
      await Isolate.spawn(
        _runDaemon,
        (
          replies: _messages.sendPort,
          starter: starter,
          host: host,
          port: port,
          token: token,
        ),
        debugName: 'speeddial-daemon',
        onError: _messages.sendPort,
        onExit: _messages.sendPort,
        errorsAreFatal: true,
      );
    } on Object catch (failure) {
      error = failure;
      _finish();
    }
  }

  void requestStop() {
    if (stopping) return;
    stopping = true;
    url = null;
    _commands?.send(null);
  }

  void _onMessage(Object? message) {
    switch (message) {
      case SendPort commands:
        _commands = commands;
        if (stopping) commands.send(null);
      case ('ready', String endpoint):
        if (!stopping) url = endpoint;
        ready.complete(stopping ? null : endpoint);
      case ('error', String description, String stack):
        error = RemoteError(description, stack);
      case [String description, String stack]:
        // Uncaught worker errors are followed by the onExit notification.
        error = RemoteError(description, stack);
      case null:
        if (!stopping && error == null) {
          error = StateError('Embedded daemon isolate exited unexpectedly');
        }
        _finish();
    }
  }

  void _finish() {
    url = null;
    if (!ready.isCompleted) ready.complete(null);
    _messages.close();
    if (!exited.isCompleted) exited.complete();
  }
}

typedef _DaemonStart = ({
  SendPort replies,
  DaemonStarter starter,
  String host,
  int port,
  String token,
});

Future<void> _runDaemon(_DaemonStart config) async {
  final ReceivePort commands = ReceivePort();
  config.replies.send(commands.sendPort);
  // Listen before startup so a concurrent stop is retained until startup ends.
  final Completer<void> stopRequested = Completer<void>();
  commands.listen((_) {
    if (!stopRequested.isCompleted) stopRequested.complete();
  });
  try {
    final DaemonInstance daemon = await config.starter(
      config.host,
      config.port,
      config.token,
    );
    config.replies.send(('ready', daemon.url));
    await stopRequested.future;
    await daemon.stop();
  } on Object catch (error, stack) {
    config.replies.send(('error', error.toString(), stack.toString()));
  } finally {
    commands.close();
  }
  // Daemon timers must not keep a stopped or failed worker alive.
  Isolate.exit();
}

LocalDaemonController platformControllerImpl() => LocalDaemonControllerNative();
