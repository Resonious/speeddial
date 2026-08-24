import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:speeddial_app/src/companion/companion_endpoint_sync.dart';
import 'package:speeddial_app/src/scope.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('test.companion');

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('watch replaces stale endpoints with the phone snapshot', () async {
    final ConnectionsStore connections = ConnectionsStore();
    await connections.addEndpoint(
      id: 'stale',
      name: 'Stale',
      url: 'stale.example:7331',
      token: 'old',
    );
    final String payload = jsonEncode(<Object?>[
      <String, Object?>{
        'id': 'phone',
        'name': 'Phone daemon',
        'url': 'wss://daemon.example/ws',
        'token': 'secret',
      },
    ]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, 'getEndpoints');
          return payload;
        });

    final CompanionEndpointSync sync = CompanionEndpointSync(channel: channel);
    addTearDown(sync.dispose);
    addTearDown(connections.dispose);
    await sync.startWatch(connections);

    expect(connections.endpoints, hasLength(1));
    expect(connections.endpoints.single.id, 'phone');
    expect(connections.endpoints.single.token, 'secret');
  });

  test('phone publishes changes and omits embedded endpoints', () async {
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          return null;
        });
    final ConnectionsStore connections = ConnectionsStore();
    final CompanionEndpointSync sync = CompanionEndpointSync(channel: channel);
    addTearDown(sync.dispose);
    addTearDown(connections.dispose);

    await sync.startPhone(connections);
    await connections.addEndpoint(
      id: 'embedded',
      name: 'This computer',
      url: 'ws://127.0.0.1:7331/ws',
      token: '',
      persist: false,
      embedded: true,
    );
    await connections.addEndpoint(
      id: 'remote',
      name: 'Remote',
      url: 'daemon.example:7331',
      token: 'token',
    );
    await Future<void>.delayed(Duration.zero);

    final Map<Object?, Object?> arguments =
        calls.last.arguments! as Map<Object?, Object?>;
    final List<Object?> payload =
        jsonDecode(arguments['payload']! as String) as List<Object?>;
    expect(payload, hasLength(1));
    expect((payload.single! as Map<String, Object?>)['id'], 'remote');
  });
}
