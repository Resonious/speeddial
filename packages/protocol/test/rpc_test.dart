import 'dart:async';

import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:test/test.dart';

/// An in-memory one-direction message pipe; mirrors a transport half-duplex
/// leg between two peers.
class Pipe {
  final StreamController<Object?> _controller =
      StreamController<Object?>(sync: true);

  void send(Object? message) => _controller.add(message);
  Stream<Object?> get stream => _controller.stream;
  Future<void> close() => _controller.close();
}

/// Two peers wired through independent pipes: `a` sends via `aToB`; `b` sends
/// via `bToA`.
({RpcPeer a, RpcPeer b, Pipe aToB, Pipe bToA}) pair() {
  final aToB = Pipe();
  final bToA = Pipe();
  final a = RpcPeer(incoming: bToA.stream, send: aToB.send);
  final b = RpcPeer(incoming: aToB.stream, send: bToA.send);
  return (a: a, b: b, aToB: aToB, bToA: bToA);
}

/// Flushes microtasks and zero-delay timers so async handler replies land.
Future<void> pump() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('calls', () {
    test('call -> result', () async {
      final p = pair();
      p.b.registerHandler('echo', (params) => <String, Object?>{
            'got': params['v'],
          });
      final result = await p.a.call('echo', <String, Object?>{'v': 42});
      expect(result, {'got': 42});
    });

    test('async handler result', () async {
      final p = pair();
      p.b.registerHandler('slow', (params) async {
        await Future<void>.delayed(Duration.zero);
        return (params['n']! as int) * 2;
      });
      expect(await p.a.call('slow', <String, Object?>{'n': 21}), 42);
    });

    test('null result is delivered', () async {
      final p = pair();
      p.b.registerHandler('void', (_) => null);
      expect(await p.a.call('void'), isNull);
    });

    test('handler may read request params; ids do not collide', () async {
      final p = pair();
      p.b.registerHandler('echo2', (params) => params['v']);
      final first = p.a.call('echo2', <String, Object?>{'v': 'first'});
      final second = p.a.call('echo2', <String, Object?>{'v': 'second'});
      expect(await first, 'first');
      expect(await second, 'second');
    });

    test('call -> DaemonError passthrough with code/message/data', () async {
      final p = pair();
      p.b.registerHandler('boom', (_) =>
          throw DaemonError(kErrNotFound, 'missing', <String, Object?>{
            'id': 7,
          }));
      await expectLater(
        p.a.call('boom'),
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', kErrNotFound)
            .having((e) => e.message, 'message', 'missing')
            .having((e) => e.data, 'data', {'id': 7})),
      );
    });

    test('DaemonError without data arrives with null data', () async {
      final p = pair();
      p.b.registerHandler('nodata',
          (_) => throw DaemonError(kErrProviderUnavailable, 'unavailable'));
      await expectLater(
        p.a.call('nodata'),
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', kErrProviderUnavailable)
            .having((e) => e.message, 'message', 'unavailable')
            .having((e) => e.data, 'data', isNull)),
      );
    });

    test('unregistered method -> -32601', () async {
      final p = pair();
      await expectLater(
        p.a.call('no.such.method'),
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', -32601)
            .having((e) => e.message, 'message', 'Method not found')),
      );
    });

    test('handler throwing a plain error -> -32603', () async {
      final p = pair();
      p.b.registerHandler('oops', (_) async => throw StateError('kaboom'));
      await expectLater(
        p.a.call('oops'),
        throwsA(isA<DaemonError>().having((e) => e.code, 'code', -32603)),
      );
    });

    test('async DaemonError throw also maps cleanly', () async {
      final p = pair();
      p.b.registerHandler('asyncboom', (_) async {
        await Future<void>.delayed(Duration.zero);
        throw DaemonError(kErrConflict, 'already running');
      });
      await expectLater(
        p.a.call('asyncboom'),
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', kErrConflict)
            .having((e) => e.message, 'message', 'already running')),
      );
    });

    test('malformed error response -> -32603 peer-side error', () async {
      final p = pair();
      p.b.registerHandler('hang', (_) => Completer<Object?>().future);
      final pending = p.a.call('hang');
      p.bToA.send(<String, Object?>{
        'jsonrpc': '2.0',
        'id': 1,
        'error': 'not a map',
      });
      await expectLater(
        pending,
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', -32603)
            .having((e) => e.message, 'message', 'malformed error')),
      );
    });
  });

  group('notifications', () {
    test('notification without handler arrives on the stream', () async {
      final p = pair();
      final received = <RpcNotification>[];
      final sub = p.b.notifications.listen(received.add);
      p.a.notify('session.event', <String, Object?>{
        'sessionId': 's1',
        'seq': 1,
      });
      await pump();
      expect(received, hasLength(1));
      expect(received.single.method, 'session.event');
      expect(received.single.params, {'sessionId': 's1', 'seq': 1});
      await sub.cancel();
    });

    test('notification for a registered method is routed to the handler, '
        'not the stream', () async {
      final p = pair();
      var handled = false;
      p.b.registerHandler('session.event', (params) async {
        handled = params['handled'] == true;
        return null;
      });
      final received = <RpcNotification>[];
      final sub = p.b.notifications.listen(received.add);
      p.a.notify('session.event', <String, Object?>{'handled': true});
      await pump();
      expect(received, isEmpty);
      expect(handled, isTrue);
      await sub.cancel();
    });

    test('notify with no params yields empty params map', () async {
      final p = pair();
      final received = <RpcNotification>[];
      final sub = p.b.notifications.listen(received.add);
      p.a.notify('ping');
      await pump();
      expect(received.single.method, 'ping');
      expect(received.single.params, isEmpty);
      await sub.cancel();
    });

    test('malformed non-map frames are ignored, not fatal', () async {
      final p = pair();
      p.b.registerHandler('ok', (_) => 'fine');
      p.aToB.send('garbage');
      p.aToB.send(<int, Object?>{1: 2}); // Map with non-String key: still a Map -> id lookup misses.
      p.aToB.send(const <String, Object?>{}); // No id/method: ignored.
      p.aToB.send(<String, Object?>{
        'jsonrpc': '2.0',
        'id': 9999,
        'result': 'stale response for unknown id',
      });
      expect(await p.a.call('ok'), 'fine');
    });

    test('notification params that are not a map decode as empty', () async {
      final p = pair();
      final received = <RpcNotification>[];
      final sub = p.b.notifications.listen(received.add);
      p.aToB.send(<String, Object?>{
        'jsonrpc': '2.0',
        'method': 'weird',
        'params': 'just a string',
      });
      await pump();
      expect(received.single.method, 'weird');
      expect(received.single.params, isEmpty);
      await sub.cancel();
    });
  });

  group('close semantics', () {
    test('close completes pending calls with peer-closed error', () async {
      final p = pair();
      p.b.registerHandler('hang', (_) => Completer<Object?>().future);
      final pending = p.a.call('hang');
      final done = expectLater(
        pending,
        throwsA(isA<DaemonConnectionError>()
            .having((e) => e.code, 'code', -32603)
            .having((e) => e.message, 'message', 'peer closed')),
      );
      await p.a.close();
      await done;
      await p.b.close();
      await p.aToB.close();
      await p.bToA.close();
    });

    test('close is idempotent', () async {
      final p = pair();
      await p.a.close();
      await p.a.close();
      await p.b.close();
      await p.aToB.close();
      await p.bToA.close();
    });

    test('close preserves a transport-specific reason', () async {
      final p = pair();
      p.b.registerHandler('hang', (_) => Completer<Object?>().future);
      final pending = p.a.call('hang');
      const error = DaemonConnectionError('phone proxy channel closed');
      final done = expectLater(
        pending,
        throwsA(
          isA<DaemonConnectionError>().having(
            (e) => e.message,
            'message',
            error.message,
          ),
        ),
      );
      await p.a.close(error);
      await done;
      await expectLater(
        p.a.call('anything'),
        throwsA(
          isA<DaemonConnectionError>().having(
            (e) => e.message,
            'message',
            error.message,
          ),
        ),
      );
      await p.b.close();
      await p.aToB.close();
      await p.bToA.close();
    });

    test('call after close fails immediately with peer-closed', () async {
      final p = pair();
      await p.a.close();
      await expectLater(
        p.a.call('anything'),
        throwsA(isA<DaemonConnectionError>()
            .having((e) => e.code, 'code', -32603)
            .having((e) => e.message, 'message', 'peer closed')),
      );
      await p.b.close();
      await p.aToB.close();
      await p.bToA.close();
    });

    test('notifications stream emits done after close', () async {
      final p = pair();
      final done = expectLater(p.b.notifications, emitsDone);
      await p.b.close();
      await done;
      await p.a.close();
      await p.aToB.close();
      await p.bToA.close();
    });

    test('requests complete normally before close', () async {
      final p = pair();
      p.b.registerHandler('echo', (params) => params['v']);
      final pending = p.a.call('echo', <String, Object?>{'v': 'ok'});
      // Let the response flow back; the pending completer resolves to 'ok'
      // and is removed from `_pending` before close() is ever called.
      await pump();
      await p.a.close();
      // The response arrived before close, so the call must complete normally
      // rather than being failed with the peer-closed error.
      await expectLater(pending, completion('ok'));
      await p.b.close();
      await p.aToB.close();
      await p.bToA.close();
    });
  });
}
