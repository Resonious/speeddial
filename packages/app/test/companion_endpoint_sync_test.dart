import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:speeddial_app/src/api/fake_daemon.dart';
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

    final FakeDaemonClient fake = FakeDaemonClient();
    final CompanionEndpointSync sync = CompanionEndpointSync(channel: channel);
    final AppData data = AppData(
      connections: connections,
      clientFor: (String _) => fake,
    );
    addTearDown(sync.dispose);
    addTearDown(data.dispose);
    addTearDown(fake.dispose);
    await sync.startWatch(connections, data.sessions);

    expect(connections.endpoints, hasLength(1));
    expect(connections.endpoints.single.id, 'phone');
    expect(connections.endpoints.single.token, 'secret');
  });

  test('watch reads a cold-start Tile session target', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          return switch (call.method) {
            'getEndpoints' => null,
            'takeLaunchTarget' => <String, Object?>{
              'wearDestination': 'session',
              'daemonId': 'daemon-a',
              'projectId': 'project-a',
              'sessionId': 'session-a',
            },
            _ => null,
          };
        });
    final FakeDaemonClient fake = FakeDaemonClient();
    final AppData data = AppData(clientFor: (String _) => fake);
    final CompanionEndpointSync sync = CompanionEndpointSync(channel: channel);
    addTearDown(sync.dispose);
    addTearDown(data.dispose);
    addTearDown(fake.dispose);

    await sync.startWatch(data.connections, data.sessions);
    final WearLaunchTarget? target = await sync.takeLaunchTarget();

    expect(target?.destination, WearLaunchDestination.session);
    expect(target?.daemonId, 'daemon-a');
    expect(target?.projectId, 'project-a');
    expect(target?.sessionId, 'session-a');
  });

  test('watch forwards a warm complication target', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async => null);
    final FakeDaemonClient fake = FakeDaemonClient();
    final AppData data = AppData(clientFor: (String _) => fake);
    final CompanionEndpointSync sync = CompanionEndpointSync(channel: channel);
    addTearDown(sync.dispose);
    addTearDown(data.dispose);
    addTearDown(fake.dispose);
    await sync.startWatch(data.connections, data.sessions);
    final Future<WearLaunchTarget> received = sync.launchTargets.first;

    const StandardMethodCodec codec = StandardMethodCodec();
    final ByteData message = codec.encodeMethodCall(
      const MethodCall('launchTarget', <String, Object?>{
        'wearDestination': 'attention',
      }),
    );
    final Completer<ByteData?> reply = Completer<ByteData?>();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(channel.name, message, reply.complete);
    codec.decodeEnvelope((await reply.future)!);

    expect((await received).destination, WearLaunchDestination.attention);
  });

  test('rejects incomplete native session targets', () {
    expect(
      WearLaunchTarget.tryParse(<String, Object?>{
        'wearDestination': 'session',
        'daemonId': 'daemon-a',
      }),
      isNull,
    );
  });

  test('phone publishes changes and omits embedded endpoints', () async {
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          return null;
        });
    final FakeDaemonClient fake = FakeDaemonClient();
    final ConnectionsStore connections = ConnectionsStore();
    final AppData data = AppData(
      connections: connections,
      clientFor: (String _) => fake,
    );
    final CompanionEndpointSync sync = CompanionEndpointSync(channel: channel);
    addTearDown(sync.dispose);
    addTearDown(data.dispose);
    addTearDown(fake.dispose);

    await sync.startPhone(connections, data.sessions);
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
    await data.sessions.refresh('remote');
    await Future<void>.delayed(Duration.zero);

    final MethodCall endpointCall = calls.lastWhere(
      (MethodCall call) => call.method == 'publishEndpoints',
    );
    final Map<Object?, Object?> arguments =
        endpointCall.arguments! as Map<Object?, Object?>;
    final List<Object?> payload =
        jsonDecode(arguments['payload']! as String) as List<Object?>;
    expect(payload, hasLength(1));
    expect((payload.single! as Map<String, Object?>)['id'], 'remote');

    final MethodCall sessionCall = calls.lastWhere(
      (MethodCall call) => call.method == 'publishSessions',
    );
    final Map<Object?, Object?> sessionArguments =
        sessionCall.arguments! as Map<Object?, Object?>;
    final Map<String, Object?> sessionPayload = jsonDecode(
      sessionArguments['payload']! as String,
    ) as Map<String, Object?>;
    expect(sessionPayload['version'], 1);
    expect(sessionPayload['daemonIds'], <Object?>['remote']);
    final List<Object?> sessions = sessionPayload['sessions']! as List<Object?>;
    expect(sessions, hasLength(2));
    expect(
      (sessions.first! as Map<String, Object?>).keys,
      containsAll(<String>['daemonId', 'sessionId', 'status', 'done']),
    );
  });

  test('watch caches complete daemon snapshots as authoritative', () async {
    final List<MethodCall> calls = <MethodCall>[];
    final ConnectionsStore connections = ConnectionsStore();
    await connections.addEndpoint(
      id: 'alpha',
      name: 'Alpha',
      url: 'alpha.example:7331',
      token: '',
    );
    await connections.addEndpoint(
      id: 'beta',
      name: 'Beta',
      url: 'beta.example:7331',
      token: '',
    );
    final String endpointPayload = jsonEncode(<Object?>[
      for (final DaemonEndpoint endpoint in connections.endpoints)
        endpoint.toJson(),
    ]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          return call.method == 'getEndpoints' ? endpointPayload : null;
        });

    final FakeDaemonClient fake = FakeDaemonClient();
    final AppData data = AppData(
      connections: connections,
      clientFor: (String _) => fake,
    );
    final CompanionEndpointSync sync = CompanionEndpointSync(channel: channel);
    addTearDown(sync.dispose);
    addTearDown(data.dispose);
    addTearDown(fake.dispose);

    await sync.startWatch(connections, data.sessions);
    await sync.refreshWatchSessions(data);

    final MethodCall cacheCall = calls.lastWhere(
      (MethodCall call) => call.method == 'cacheSessions',
    );
    final Map<String, Object?> payload =
        jsonDecode(cacheCall.arguments! as String) as Map<String, Object?>;
    expect(payload['daemonIds'], <Object?>['alpha', 'beta']);
    final List<Object?> sessions = payload['sessions']! as List<Object?>;
    expect(sessions, hasLength(4));
    expect(
      sessions
          .cast<Map<String, Object?>>()
          .map((Map<String, Object?> item) => item['daemonId'])
          .toSet(),
      <Object?>{'alpha', 'beta'},
    );
  });
}
