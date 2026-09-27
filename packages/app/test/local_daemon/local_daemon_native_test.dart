import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/local_daemon/local_daemon_native.dart';

// No sockets, database, or agent processes: the real worker lifecycle runs with
// a fake daemon created inside its isolate.
Future<DaemonInstance> _fakeDaemon(String host, int port, String token) async {
  if (host == 'fail') throw StateError('startup failed');
  if (host == 'exit') Isolate.exit();
  if (host == 'busy') sleep(const Duration(milliseconds: 200));
  if (host == 'slow') {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  if (host == 'crash') {
    Timer(
      const Duration(milliseconds: 50),
      () => throw StateError('worker crash'),
    );
  }
  return (
    url: '${Isolate.current.debugName}:$host:$port:$token',
    stop: () async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (token == 'stop-error') throw StateError('cleanup failed');
    },
  );
}

void main() {
  late LocalDaemonControllerNative controller;

  setUp(() {
    controller = LocalDaemonControllerNative.withStarter(_fakeDaemon);
  });
  tearDown(() async => controller.stop());

  test('starts on another isolate, forwards config, and restarts', () async {
    expect(controller.isRunning, isFalse);
    expect(
      await controller.start(host: 'custom', port: 7331, token: 'secret'),
      'speeddial-daemon:custom:7331:secret',
    );
    expect(controller.isRunning, isTrue);
    expect(await controller.start(), 'speeddial-daemon:custom:7331:secret');
    await controller.stop();
    expect(controller.isRunning, isFalse);
    expect(controller.lastError, isNull);
    await controller.stop();
    expect(await controller.start(), 'speeddial-daemon:127.0.0.1:0:');
  });

  test(
    'synchronous daemon work leaves the calling isolate responsive',
    () async {
      int ticks = 0;
      final Timer timer = Timer.periodic(const Duration(milliseconds: 10), (_) {
        ticks++;
      });
      addTearDown(timer.cancel);
      await controller.start(host: 'busy');
      expect(ticks, greaterThan(0));
    },
  );

  test('concurrent start does not create another worker', () async {
    final Future<String?> starting = controller.start(host: 'slow');
    expect(await controller.start(), isNull);
    expect(await starting, 'speeddial-daemon:slow:0:');
  });

  test(
    'stop during startup waits for cleanup and suppresses the endpoint',
    () async {
      final Future<String?> starting = controller.start(
        host: 'slow',
        token: 'stop-error',
      );
      await Future.wait(<Future<void>>[controller.stop(), controller.stop()]);
      expect(await starting, isNull);
      expect(controller.isRunning, isFalse);
      // Only the fake daemon's awaited shutdown can produce this error.
      expect(controller.lastError.toString(), contains('cleanup failed'));
      expect(await controller.start(), isNotNull);
      expect(controller.lastError, isNull);
    },
  );

  test('failed startup returns its error and permits a retry', () async {
    expect(await controller.start(host: 'fail'), isNull);
    expect(controller.isRunning, isFalse);
    expect(controller.lastError.toString(), contains('startup failed'));
    expect(await controller.start(), isNotNull);
    expect(controller.lastError, isNull);
  });

  test('exit before startup completes does not leave start waiting', () async {
    expect(await controller.start(host: 'exit'), isNull);
    expect(controller.lastError.toString(), contains('exited unexpectedly'));
  });

  test('uncaught worker failure clears the running state', () async {
    expect(await controller.start(host: 'crash'), isNotNull);
    final Stopwatch deadline = Stopwatch()..start();
    while (controller.isRunning &&
        deadline.elapsed < const Duration(seconds: 5)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(controller.isRunning, isFalse);
    expect(controller.lastError.toString(), contains('worker crash'));
    expect(await controller.start(), isNotNull);
  });

  test(
    'production worker reports invalid config without opening a server',
    () async {
      await controller.stop();
      controller = LocalDaemonControllerNative();
      expect(await controller.start(host: '0.0.0.0'), isNull);
      expect(
        controller.lastError.toString(),
        contains('requires a non-empty authToken'),
      );
    },
  );
}
