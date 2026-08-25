import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/local_daemon/local_daemon_controller.dart';
import 'package:speeddial_app/src/scope.dart';
import 'package:speeddial_app/src/state/embedded_daemon_store.dart';
import 'package:speeddial_app/src/ui/left/left_rail.dart';
import 'package:speeddial_app/src/ui/settings/embedded_daemon_page.dart';

/// Scriptable [LocalDaemonController] for tests: records the requested
/// configuration and either restarts at [nextUrl] or fails with [failWith].
class FakeLocalDaemonController implements LocalDaemonController {
  FakeLocalDaemonController(this.url);

  String url;
  String? nextUrl;
  Object? failWith;
  @override
  Object? lastError;
  int startCalls = 0;
  int stopCalls = 0;
  String? lastHost;
  int? lastPort;
  String? lastToken;

  @override
  Future<String?> start({
    String host = '127.0.0.1',
    int port = 0,
    String token = '',
  }) async {
    startCalls++;
    lastHost = host;
    lastPort = port;
    lastToken = token;
    if (failWith != null) {
      lastError = failWith;
      return null;
    }
    if (nextUrl != null) url = nextUrl!;
    return url;
  }
  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  bool get isRunning => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('EmbeddedDaemonStore', () {
    test('init loads a persisted config', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        EmbeddedDaemonStore.storageKey:
            '{"host":"0.0.0.0","port":7331,"token":"tok"}',
      });
      final EmbeddedDaemonStore store = EmbeddedDaemonStore();
      await store.init();
      expect(store.config.host, '0.0.0.0');
      expect(store.config.port, 7331);
      expect(store.config.token, 'tok');
      expect(store.config.isLoopback, isFalse);
    });

    test('defaults when nothing is persisted', () async {
      final EmbeddedDaemonStore fresh = EmbeddedDaemonStore();
      await fresh.init();
      expect(fresh.config, const EmbeddedDaemonConfig());
      expect(fresh.config.isLoopback, isTrue);
    });


    test('save normalizes and persists', () async {
      final EmbeddedDaemonStore store = EmbeddedDaemonStore();
      await store.save(
        const EmbeddedDaemonConfig(host: ' 0.0.0.0 ', port: 9000, token: ' t '),
      );
      expect(store.config.host, '0.0.0.0');
      expect(store.config.token, 't');
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(EmbeddedDaemonStore.storageKey),
        '{"host":"0.0.0.0","port":9000,"token":"t"}',
      );
    });
  });

  group('AppData.applyEmbeddedDaemonConfig', () {
    test('restarts the controller and repoints the embedded endpoint', () async {
      final AppData data = AppData()
        ..registerClient(AppData.embeddedDaemonId, FakeDaemonClient());
      addTearDown(data.dispose);
      final FakeLocalDaemonController controller = FakeLocalDaemonController(
        'ws://127.0.0.1:40001/ws',
      );
      data.localDaemon = controller;
      await data.connections.addEndpoint(
        id: AppData.embeddedDaemonId,
        name: 'This computer',
        url: 'ws://127.0.0.1:40001/ws',
        token: '',
        persist: false,
        embedded: true,
      );

      controller.nextUrl = 'ws://127.0.0.1:7331/ws';
      await data.applyEmbeddedDaemonConfig(
        const EmbeddedDaemonConfig(
          host: '127.0.0.1',
          port: 7331,
          token: 'sekret',
        ),
      );

      expect(controller.stopCalls, 1);
      expect(controller.startCalls, 1);
      expect(controller.lastHost, '127.0.0.1');
      expect(controller.lastPort, 7331);
      expect(controller.lastToken, 'sekret');
      final DaemonEndpoint endpoint = data.connections.endpoints.single;
      expect(endpoint.embedded, isTrue);
      expect(endpoint.url, 'ws://127.0.0.1:7331/ws');
      expect(endpoint.token, 'sekret');
      expect(data.embeddedDaemon.lastError, isNull);
      expect(data.embeddedDaemon.restarting, isFalse);
      // Embedded endpoints never reach preferences.
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(ConnectionsStore.storageKey), '[]');
    });

    test('records the failure and keeps the saved config for next launch',
        () async {
      final AppData data = AppData()
        ..registerClient(AppData.embeddedDaemonId, FakeDaemonClient());
      addTearDown(data.dispose);
      final FakeLocalDaemonController controller = FakeLocalDaemonController(
        'ws://127.0.0.1:40002/ws',
      )..failWith = StateError('port in use');
      data.localDaemon = controller;

      await expectLater(
        data.applyEmbeddedDaemonConfig(
          const EmbeddedDaemonConfig(port: 7331, token: 'sekret'),
        ),
        throwsStateError,
      );
      expect(controller.startCalls, 1);
      expect(data.embeddedDaemon.lastError, isNotNull);
      expect(data.embeddedDaemon.restarting, isFalse);
      // The settings are still persisted so the next launch retries them.
      expect(data.embeddedDaemon.config.port, 7331);
    });

    test('adds the embedded endpoint when boot start had failed', () async {
      final AppData data = AppData()
        ..registerClient(AppData.embeddedDaemonId, FakeDaemonClient());
      addTearDown(data.dispose);
      final FakeLocalDaemonController controller = FakeLocalDaemonController(
        'ws://127.0.0.1:7331/ws',
      );
      data.localDaemon = controller;

      await data.applyEmbeddedDaemonConfig(
        const EmbeddedDaemonConfig(port: 7331, token: 'sekret'),
      );

      final DaemonEndpoint endpoint = data.connections.endpoints.single;
      expect(endpoint.id, AppData.embeddedDaemonId);
      expect(endpoint.embedded, isTrue);
      expect(data.selection.selectedDaemonId, AppData.embeddedDaemonId);
    });

    test('without a controller it only persists', () async {
      final AppData data = AppData();
      addTearDown(data.dispose);
      await data.applyEmbeddedDaemonConfig(
        const EmbeddedDaemonConfig(host: '127.0.0.1', port: 7331),
      );
      expect(data.embeddedDaemon.config.port, 7331);
      expect(data.embeddedDaemon.restarting, isFalse);
    });
  });

  group('EmbeddedDaemonPage', () {
    Future<AppData> pumpPage(WidgetTester tester, AppData data) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AppScope(
            data: data,
            child: EmbeddedDaemonPage(initial: data.embeddedDaemon.config),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return data;
    }

    testWidgets('applies interface, port, and token through the restart',
        (WidgetTester tester) async {
      final AppData data = AppData();
      addTearDown(data.dispose);
      final FakeLocalDaemonController controller = FakeLocalDaemonController(
        'ws://127.0.0.1:40003/ws',
      )..nextUrl = 'ws://127.0.0.1:7331/ws';
      data.localDaemon = controller;
      await pumpPage(tester, data);

      await tester.tap(find.byKey(const Key('embedded-daemon-interface')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('All interfaces (0.0.0.0)').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('embedded-daemon-port')),
        '7331',
      );
      await tester.enterText(
        find.byKey(const Key('embedded-daemon-token')),
        'net-token',
      );
      await tester.tap(find.byKey(const Key('embedded-daemon-apply')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('embedded-daemon-restart-confirm')));
      await tester.pumpAndSettle();

      expect(controller.lastHost, '0.0.0.0');
      expect(controller.lastPort, 7331);
      expect(controller.lastToken, 'net-token');
      expect(data.embeddedDaemon.config.host, '0.0.0.0');
      expect(find.byKey(const Key('embedded-daemon-error')), findsNothing);
    });

    testWidgets('rejects a non-loopback interface without a token', (
      WidgetTester tester,
    ) async {
      final AppData data = AppData();
      addTearDown(data.dispose);
      data.localDaemon = FakeLocalDaemonController('ws://127.0.0.1:40004/ws');
      await pumpPage(tester, data);

      await tester.tap(find.byKey(const Key('embedded-daemon-interface')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('All interfaces (0.0.0.0)').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('embedded-daemon-apply')));
      await tester.pumpAndSettle();

      expect(find.textContaining('A token is required'), findsOneWidget);
      expect(data.embeddedDaemon.config.host, '127.0.0.1');
    });

    testWidgets('shows the running URL and a start failure', (
      WidgetTester tester,
    ) async {
      final AppData data = AppData();
      addTearDown(data.dispose);
      await data.connections.addEndpoint(
        id: AppData.embeddedDaemonId,
        name: 'This computer',
        url: 'ws://127.0.0.1:7331/ws',
        token: '',
        persist: false,
        embedded: true,
      );
      data.embeddedDaemon.setLastError(StateError('address in use'));
      await pumpPage(tester, data);

      expect(
        find.byKey(const Key('embedded-daemon-url')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('embedded-daemon-error')), findsOneWidget);
    });

    testWidgets('left rail exposes the settings entry for the embedded daemon',
        (WidgetTester tester) async {
      final AppData data = AppData();
      addTearDown(data.dispose);
      data.localDaemon = FakeLocalDaemonController('ws://127.0.0.1:7331/ws');
      await tester.pumpWidget(
        MaterialApp(home: AppScope(data: data, child: const LeftRail())),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('embedded-daemon-settings')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('embedded-daemon-settings')));
      await tester.pumpAndSettle();
      expect(find.text('Built-in daemon'), findsOneWidget);
      expect(
        find.byKey(const Key('embedded-daemon-apply')),
        findsOneWidget,
      );
    });
  });
}
