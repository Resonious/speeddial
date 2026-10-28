import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import 'package:speeddial_app/src/api/daemon_client.dart';
import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/api/ws_daemon_client.dart';
import 'package:speeddial_app/src/scope.dart';
import 'package:speeddial_app/src/state/chat_store.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/chat/chat_pane.dart';

/// In-memory wire peer so endpoint edits exercise real client subscriptions.
class _EndpointChannel implements DaemonFrameChannel {
  final StreamController<Object?> incoming = StreamController<Object?>();
  Session session = Session(
    id: 'session',
    projectId: 'project',
    providerId: 'ante',
    title: 'New session',
    status: SessionStatus.idle,
    model: null,
    cwd: '/workspace',
    baseBranch: null,
    yolo: false,
    archived: false,
    preparing: true,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  );
  int listings = 0;
  bool closed = false;

  @override
  Future<void> get ready async {}
  @override
  Stream<Object?> get stream => incoming.stream;
  @override
  void add(Object? data) {
    final Map<String, Object?> request = (jsonDecode(data! as String) as Map)
        .cast<String, Object?>();
    if (request['method'] == 'sessions.list') listings++;
    final Object result = switch (request['method']) {
      'auth.authenticate' => <String, Object?>{'ok': true},
      'sessions.list' => <String, Object?>{
        'sessions': [session.toJson()],
      },
      'sessions.create' => <String, Object?>{'session': session.toJson()},
      'sessions.history' => <String, Object?>{'events': [], 'hasMore': false},
      'sessions.commands' => <String, Object?>{'commands': []},
      _ => throw StateError('Unexpected method: ${request['method']}'),
    };
    incoming.add(
      jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': result}),
    );
  }

  void notify(String method, Map<String, Object?> params) {
    incoming.add(
      jsonEncode({'jsonrpc': '2.0', 'method': method, 'params': params}),
    );
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await incoming.close();
  }
}

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

  test('editing an endpoint recycles its websocket client when url/token '
      'change', () async {
    // Exercise failed-connection recycling without depending on real closed
    // ports, whose WebSocket handshake can outlast this test's deadline.
    final AppData data = AppData(
      daemonChannelFactory: (_) => throw StateError('connection refused'),
    );
    addTearDown(data.dispose);
    await data.connections.addEndpoint(
      id: 'ep1',
      name: 'Endpoint one',
      url: 'ws://127.0.0.1:1/ws',
      token: 't1',
    );

    final DaemonClient first = data.clientFor('ep1');
    expect(first, isA<WsDaemonClient>());
    await waitFor(
      () => data.connections.statusOf('ep1') == ConnectionStatus.failed,
    );

    // A name-only edit keeps the live client.
    await data.connections.updateEndpoint(
      id: 'ep1',
      name: 'Renamed',
      url: 'ws://127.0.0.1:1/ws',
      token: 't1',
    );
    expect(identical(data.clientFor('ep1'), first), isTrue);

    // Changing url/token disposes the stale client; the next touch builds a
    // fresh one with the edited parameters.
    await data.connections.updateEndpoint(
      id: 'ep1',
      name: 'Renamed',
      url: 'ws://127.0.0.1:2/ws',
      token: 't2',
    );
    final DaemonClient second = data.clientFor('ep1');
    expect(identical(second, first), isFalse);
    expect((second as WsDaemonClient).url, 'ws://127.0.0.1:2/ws');
    expect(second.token, 't2');
  });

  test(
    'endpoint edits preserve live preparation and chat subscriptions',
    () async {
      final List<_EndpointChannel> channels = <_EndpointChannel>[];
      final AppData data = AppData(
        daemonChannelFactory: (_) {
          final _EndpointChannel channel = _EndpointChannel();
          channels.add(channel);
          return channel;
        },
      );
      addTearDown(data.dispose);
      await data.connections.addEndpoint(
        id: 'ep',
        name: 'Daemon',
        url: 'ws://daemon/ws',
        token: 'first',
      );
      await waitFor(
        () => data.connections.statusOf('ep') == ConnectionStatus.connected,
      );
      await data.sessions.refresh('ep');
      final Completer<void> closed = Completer<void>();
      final StreamSubscription<Session> originalUpdates = data
          .clientFor('ep')
          .sessionUpdates
          .listen((_) {}, onDone: closed.complete);
      addTearDown(originalUpdates.cancel);
      data.chat.watchSession('ep', 'session');
      await waitFor(
        () => data.chat.historyStatusFor('session') == HistoryStatus.ready,
      );

      await data.connections.updateEndpoint(
        id: 'ep',
        name: 'Daemon',
        url: 'ws://daemon/ws',
        token: 'second',
      );
      await waitFor(
        () => channels.length == 2 && data.clientFor('ep').isConnected,
      );
      final _EndpointChannel current = channels.last;
      await waitFor(() => current.listings > 0);
      await data.sessions.create(
        'ep',
        projectId: 'project',
        providerId: 'ante',
      );
      expect(data.sessions.sessionOnDaemon('ep', 'session')!.preparing, isTrue);
      current.session = Session.fromJson({
        ...current.session.toJson(),
        'preparing': false,
        'title': 'hi',
        'updatedAt': DateTime.utc(2026, 1, 2).toIso8601String(),
      });
      current.notify('session.updated', {'session': current.session.toJson()});
      current.notify('session.event', {
        'sessionId': 'session',
        'seq': 1,
        'event': AgentMessageChunkEvent(
          text: 'Hello',
          seq: 1,
          timestamp: DateTime.utc(2026, 1, 2),
        ).toJson(),
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        data.sessions.sessionOnDaemon('ep', 'session')!.preparing,
        isFalse,
      );
      expect(data.sessions.sessionOnDaemon('ep', 'session')!.title, 'hi');
      expect(
        data.chat
            .eventsFor('session')
            .whereType<AgentMessageChunkEvent>()
            .single
            .text,
        'Hello',
      );
      expect(closed.isCompleted, isFalse);

      // A second edit transfers the same subscriptions again. Only disposing
      // the final connection should close their streams.
      await data.connections.updateEndpoint(
        id: 'ep',
        name: 'Daemon',
        url: 'ws://other-daemon/ws',
        token: 'second',
      );
      await waitFor(
        () => channels.length == 3 && data.clientFor('ep').isConnected,
      );
      final _EndpointChannel latest = channels.last;
      latest.session = Session.fromJson({
        ...current.session.toJson(),
        'title': 'Still live',
        'updatedAt': DateTime.utc(2026, 1, 3).toIso8601String(),
      });
      latest.notify('session.updated', {'session': latest.session.toJson()});
      await waitFor(
        () =>
            data.sessions.sessionOnDaemon('ep', 'session')!.title ==
            'Still live',
      );
      expect(closed.isCompleted, isFalse);
      data.dispose();
      await closed.future.timeout(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'preparation clears after connection edit without switching tabs',
    (tester) async {
      final List<_EndpointChannel> channels = <_EndpointChannel>[];
      final AppData data = AppData(
        daemonChannelFactory: (_) {
          final _EndpointChannel channel = _EndpointChannel();
          channels.add(channel);
          return channel;
        },
      );
      addTearDown(data.dispose);
      await tester.runAsync(() async {
        await data.connections.addEndpoint(
          id: 'ep',
          name: 'Daemon',
          url: 'ws://daemon/ws',
          token: 'first',
        );
        await waitFor(() => data.clientFor('ep').isConnected);
        await data.sessions.refresh('ep');
        data.chat.watchSession('ep', 'session');
        await waitFor(
          () => data.chat.historyStatusFor('session') == HistoryStatus.ready,
        );
      });
      data.selection.selectSession(
        daemonId: 'ep',
        projectId: 'project',
        sessionId: 'session',
      );
      await tester.pumpWidget(
        AppScope(
          data: data,
          child: MaterialApp(
            theme: buildSpeedDialTheme(),
            home: const Scaffold(body: ChatPane()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Preparing session…'), findsOneWidget);
      expect(find.text('You can send a message now.'), findsOneWidget);

      await tester.runAsync(() async {
        await data.connections.updateEndpoint(
          id: 'ep',
          name: 'Daemon',
          url: 'ws://daemon/ws',
          token: 'second',
        );
        await waitFor(
          () => channels.length == 2 && data.clientFor('ep').isConnected,
        );
        await waitFor(() => channels.last.listings > 0);
        final _EndpointChannel current = channels.last;
        current.session = Session.fromJson({
          ...current.session.toJson(),
          'preparing': false,
          'updatedAt': DateTime.utc(2026, 1, 2).toIso8601String(),
        });
        current.notify('session.updated', {
          'session': current.session.toJson(),
        });
        await waitFor(
          () => !data.sessions.sessionOnDaemon('ep', 'session')!.preparing,
        );
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('Preparing session'), findsNothing);
      expect(data.selection.selectedSessionId, 'session');
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'clientFor lazily creates and caches a WsDaemonClient per endpoint',
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
      await waitFor(
        () => data.connections.statusOf('ep1') == ConnectionStatus.failed,
      );
    },
  );

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
    await waitFor(
      () => data.connections.statusOf('ep-a') == ConnectionStatus.failed,
    );
    await waitFor(
      () => data.connections.statusOf('ep-b') == ConnectionStatus.failed,
    );
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
