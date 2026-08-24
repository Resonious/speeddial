import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import 'package:speeddial_app/src/api/ws_daemon_client.dart';
import 'package:speeddial_app/src/companion/phone_proxy_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const String channelName = 'test.phone_proxy';
  const MethodChannel platformChannel = MethodChannel(channelName);
  const StandardMethodCodec codec = StandardMethodCodec();
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<void> sendNativeMethod(String method, Map<String, Object?> args) {
    final ByteData message = codec.encodeMethodCall(MethodCall(method, args));
    return messenger.handlePlatformMessage(channelName, message, null);
  }

  tearDown(() {
    messenger.setMockMethodCallHandler(platformChannel, null);
  });

  test('routes the existing daemon client through the paired phone', () async {
    String? openedUrl;
    String? connectionId;
    final List<String> sentMethods = <String>[];

    messenger.setMockMethodCallHandler(platformChannel, (
      MethodCall call,
    ) async {
      final Map<Object?, Object?> args =
          call.arguments! as Map<Object?, Object?>;
      switch (call.method) {
        case 'openProxy':
          connectionId = args['id']! as String;
          openedUrl = args['url']! as String;
        case 'sendProxyFrame':
          final Map<String, Object?> request =
              jsonDecode(args['payload']! as String) as Map<String, Object?>;
          final String method = request['method']! as String;
          sentMethods.add(method);
          final Map<String, Object?> result = switch (method) {
            'auth.authenticate' => <String, Object?>{'ok': true},
            'projects.list' => <String, Object?>{
              'projects': <Object?>[
                <String, Object?>{
                  'id': 'project-1',
                  'name': 'Through phone',
                  'path': '/repo',
                  'addedAt': '2026-01-01T00:00:00.000Z',
                  'lastActiveAt': '2026-01-01T00:00:00.000Z',
                },
              ],
            },
            _ => throw StateError('Unexpected method: $method'),
          };
          await sendNativeMethod('proxyFrame', <String, Object?>{
            'id': args['id']! as String,
            'payload': jsonEncode(<String, Object?>{
              'jsonrpc': '2.0',
              'id': request['id'],
              'result': result,
            }),
          });
        case 'closeProxy':
          break;
      }
      return null;
    });

    final PhoneProxyChannelFactory proxy = PhoneProxyChannelFactory(
      channel: platformChannel,
    );
    final WsDaemonClient client = WsDaemonClient(
      url: 'wss://framework.tailnet.ts.net/ws',
      token: 'secret',
      channelFactory: proxy.connect,
    );
    addTearDown(client.dispose);
    addTearDown(proxy.dispose);

    await client.connect();
    final projects = await client.listProjects();

    expect(connectionId, 'proxy-0');
    expect(openedUrl, 'wss://framework.tailnet.ts.net/ws');
    expect(sentMethods, <String>['auth.authenticate', 'projects.list']);
    expect(projects.single.name, 'Through phone');
  });

  test('surfaces a phone-side proxy disconnect to the frame stream', () async {
    messenger.setMockMethodCallHandler(platformChannel, (
      MethodCall call,
    ) async {
      return null;
    });
    final PhoneProxyChannelFactory proxy = PhoneProxyChannelFactory(
      channel: platformChannel,
    );
    addTearDown(proxy.dispose);
    final DaemonFrameChannel connection = proxy.connect(
      Uri.parse('wss://daemon.example/ws'),
    );
    await connection.ready;

    final Future<void> errorExpectation = expectLater(
      connection.stream,
      emitsError(isA<PlatformException>()),
    );
    await sendNativeMethod('proxyClosed', <String, Object?>{
      'id': 'proxy-0',
      'error': 'Tailscale is unavailable',
    });
    await errorExpectation;
  });

  test('preserves a phone close reason through a pending RPC call', () async {
    String? connectionId;
    messenger.setMockMethodCallHandler(platformChannel, (
      MethodCall call,
    ) async {
      final Map<Object?, Object?> args =
          call.arguments! as Map<Object?, Object?>;
      switch (call.method) {
        case 'openProxy':
          connectionId = args['id']! as String;
        case 'sendProxyFrame':
          Future<void>.microtask(() async {
            await sendNativeMethod('proxyClosed', <String, Object?>{
              'id': connectionId,
              'error': 'Daemon WebSocket closed (1001: going away)',
            });
          });
        case 'closeProxy':
          break;
      }
      return null;
    });
    final PhoneProxyChannelFactory proxy = PhoneProxyChannelFactory(
      channel: platformChannel,
    );
    final WsDaemonClient client = WsDaemonClient(
      url: 'wss://daemon.example/ws',
      token: 'secret',
      channelFactory: proxy.connect,
    );

    await expectLater(
      client.connect(),
      throwsA(
        isA<DaemonConnectionError>().having(
          (DaemonConnectionError error) => error.message,
          'message',
          'Daemon WebSocket closed (1001: going away)',
        ),
      ),
    );
    await client.dispose();
    await proxy.dispose();
  });
}
