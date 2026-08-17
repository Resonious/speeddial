import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:speeddial_app/src/api/daemon_client.dart';
import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/api/ws_daemon_client.dart';
import 'package:speeddial_app/src/scope.dart';

/// Polls until [condition] holds, failing the test after [timeout].
Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition did not become true within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('registered clients win over the lazy websocket wiring', () async {
    final AppData data = AppData();
    addTearDown(data.dispose);
    final FakeDaemonClient fake = FakeDaemonClient();
    data.registerClient('dbg', fake);

    await data.connections.addEndpoint(
      id: 'dbg',
      name: 'Demo daemon',
      url: 'ws://127.0.0.1:1/ws',
      token: 'secret',
    );

    expect(identical(data.clientFor('dbg'), fake), isTrue);
    // A registered id is never auto-connected or wired to a websocket
    // client: its status stays right where the owner left it.
    expect(data.connections.statusOf('dbg'), ConnectionStatus.disconnected);
  });

  test('unknown daemon ids still throw StateError', () {
    final AppData data = AppData();
    addTearDown(data.dispose);
    expect(() => data.clientFor('nope'), throwsStateError);
  });

  test('clientFor lazily creates and caches a WsDaemonClient per endpoint',
      () async {
    final AppData data = AppData();
    addTearDown(data.dispose);
    await data.connections.addEndpoint(
      id: 'ep1',
      name: 'Endpoint one',
      url: 'not-a-ws://ep1',
      token: 't1',
    );

    final DaemonClient first = data.clientFor('ep1');
    expect(first, isA<WsDaemonClient>());
    expect(identical(data.clientFor('ep1'), first), isTrue);

    // Adding an endpoint already started the connection; the invalid scheme
    // makes the attempt fail deterministically and the status reflects it.
    await waitFor(() => data.connections.statusOf('ep1') == ConnectionStatus.failed);
  });

  test('connectAll connects pre-existing endpoints at startup', () async {
    final ConnectionsStore connections = ConnectionsStore();
    await connections.addEndpoint(
      id: 'ep-a',
      name: 'A',
      url: 'not-a-ws://a',
      token: '',
    );
    await connections.addEndpoint(
      id: 'ep-b',
      name: 'B',
      url: 'not-a-ws://b',
      token: '',
    );
    final AppData data = AppData(
      connections: connections,
      selection: SelectionStore(),
    );
    addTearDown(data.dispose);

    await data.connectAll();
    expect(data.clientFor('ep-a'), isA<WsDaemonClient>());
    expect(data.clientFor('ep-b'), isA<WsDaemonClient>());
    await waitFor(() => data.connections.statusOf('ep-a') == ConnectionStatus.failed);
    await waitFor(() => data.connections.statusOf('ep-b') == ConnectionStatus.failed);
  });

  test('buildDemoAppData wires the fake under the demo endpoint', () {
    final AppData data = buildDemoAppData();
    addTearDown(data.dispose);

    expect(data.connections.endpoints, hasLength(1));
    expect(data.connections.endpoints.single.id, 'demo');
    expect(data.connections.endpoints.single.name, 'Local demo');
    expect(data.selection.selectedDaemonId, 'demo');
    expect(data.connections.statusOf('demo'), ConnectionStatus.connected);
    expect(data.clientFor('demo'), isA<FakeDaemonClient>());
  });
}
