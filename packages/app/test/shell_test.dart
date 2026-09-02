import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import 'package:speeddial_app/main.dart';
import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/scope.dart';
import 'package:speeddial_app/src/ui/connection_status_indicator.dart';

void main() {
  /// Pumps the real app with real stores over an empty shared_preferences
  /// mock at the given logical viewport size.
  Future<AppData> pumpApp(WidgetTester tester, {Size size = const Size(1440, 900)}) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final AppData data = AppData();
    await data.connections.init();
    addTearDown(data.dispose);

    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(SpeedDialApp(data: data));
    await tester.pump();
    return data;
  }

  Future<AppData> pumpFakeShell(
    WidgetTester tester, {
    required Size size,
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final FakeDaemonClient fake =
        FakeDaemonClient(eventDelay: const Duration(milliseconds: 1));
    final AppData data = AppData()..registerClient('fake', fake);
    await data.connections.addEndpoint(
      id: 'fake',
      name: 'Fake daemon',
      url: 'fake://local',
      token: '',
    );
    await data.projects.refresh('fake');
    await data.sessions.refresh('fake');
    data.selection
      ..selectedDaemonId = 'fake'
      ..selectedProjectId = 'proj-demo';
    addTearDown(data.dispose);

    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(SpeedDialApp(data: data));
    await tester.pump();
    await tester.pump();
    return data;
  }

  Finder messageInput() => find.byWidgetPredicate(
    (Widget widget) =>
        widget is TextField &&
        widget.decoration?.hintText == 'Message the agent…',
  );

  testWidgets('desktop: all three panes visible at 1440x900', (WidgetTester tester) async {
    await pumpApp(tester);

    // Top bar title.
    expect(find.text('SpeedDial'), findsOneWidget);
    // Left rail.
    expect(find.text('Daemons'), findsOneWidget);
    expect(find.text('Add daemon'), findsOneWidget);
    // Chat pane.
    expect(find.text('Select or create a session'), findsOneWidget);
    // Right panel.
    expect(find.text('Files'), findsOneWidget);
    expect(find.text('Git'), findsOneWidget);
  });

  testWidgets('connecting daemon uses spinners instead of connected dots', (
    WidgetTester tester,
  ) async {
    final AppData data = await pumpFakeShell(
      tester,
      size: const Size(1440, 900),
    );
    final Finder statusIndicators = find.byType(ConnectionStatusIndicator);
    final Finder statusSpinners = find.descendant(
      of: statusIndicators,
      matching: find.byType(CircularProgressIndicator),
    );

    data.connections.setStatus('fake', ConnectionStatus.connecting);
    await tester.pump();
    expect(statusIndicators, findsNWidgets(2));
    expect(statusSpinners, findsNWidgets(2));

    data.connections.setStatus('fake', ConnectionStatus.connected);
    await tester.pump();
    expect(statusIndicators, findsNWidgets(2));
    expect(statusSpinners, findsNothing);
  });

  testWidgets('desktop: right panel toggle hides and restores it', (WidgetTester tester) async {
    await pumpApp(tester);
    expect(find.text('Files'), findsOneWidget);

    await tester.tap(find.byTooltip('Toggle right panel'));
    await tester.pumpAndSettle();
    expect(find.text('Files'), findsNothing);
    expect(find.text('Git'), findsNothing);
    // Chat and left rail remain visible while the right panel is hidden.
    expect(find.text('Select or create a session'), findsOneWidget);
    expect(find.text('Daemons'), findsOneWidget);

    await tester.tap(find.byTooltip('Toggle right panel'));
    await tester.pumpAndSettle();
    expect(find.text('Files'), findsOneWidget);
    expect(find.text('Git'), findsOneWidget);
  });

  testWidgets('theme button cycles mode and updates MaterialApp',
      (WidgetTester tester) async {
    final AppData data = await pumpApp(tester);

    expect(data.settings.themeMode, ThemeMode.system);
    expect(find.byTooltip('Theme: System'), findsOneWidget);
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.system,
    );

    await tester.tap(find.byTooltip('Theme: System'));
    await tester.pumpAndSettle();

    expect(data.settings.themeMode, ThemeMode.light);
    expect(find.byTooltip('Theme: Light'), findsOneWidget);
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.light,
    );
  });

  testWidgets('mobile: chat-only body, drawer reveals left rail', (WidgetTester tester) async {
    await pumpApp(tester, size: const Size(390, 844));

    expect(find.text('Select or create a session'), findsOneWidget);
    expect(find.text('Daemons'), findsNothing);
    expect(find.text('Files'), findsNothing);

    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    expect(find.text('Daemons'), findsOneWidget);
    expect(find.text('Add daemon'), findsOneWidget);
  });

  testWidgets(
    'mobile: creating a session closes the drawer and focuses the message input',
    (WidgetTester tester) async {
      final AppData data = await pumpFakeShell(
        tester,
        size: const Size(390, 844),
      );

      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('new-session-proj-demo')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('new-session-submit')));
      await tester.pumpAndSettle();

      expect(data.selection.selectedSessionId, isNotNull);
      expect(
        data.selection.selectedSessionId,
        isNot(anyOf('sess-1', 'sess-2')),
      );
      expect(find.text('Daemons'), findsNothing);
      expect(messageInput(), findsOneWidget);
      expect(
        tester.widget<TextField>(messageInput()).focusNode?.hasFocus,
        isTrue,
      );
    },
  );

  testWidgets(
    'desktop: creating a session keeps the rail open and focuses the message input',
    (WidgetTester tester) async {
      await pumpFakeShell(tester, size: const Size(1440, 900));

      await tester.tap(
        find.byKey(const ValueKey<String>('new-session-proj-demo')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('new-session-submit')));
      await tester.pumpAndSettle();

      expect(find.text('Daemons'), findsOneWidget);
      expect(messageInput(), findsOneWidget);
      expect(
        tester.widget<TextField>(messageInput()).focusNode?.hasFocus,
        isTrue,
      );
    },
  );

  testWidgets('add daemon dialog adds an endpoint visible in the rail', (WidgetTester tester) async {
    final AppData data = await pumpApp(tester);

    await tester.tap(find.text('Add daemon'));
    await tester.pumpAndSettle();
    // Rail button + dialog title.
    expect(find.text('Add daemon'), findsNWidgets(2));

    await tester.enterText(find.byKey(const Key('add-daemon-name')), 'Local');
    await tester.enterText(find.byKey(const Key('add-daemon-url')), 'localhost:7331');
    await tester.enterText(find.byKey(const Key('add-daemon-token')), 'secret');
    await tester.tap(find.byKey(const Key('add-daemon-submit')));
    await tester.pumpAndSettle();

    // Dialog closed, endpoint materialized in the store and the rail. The
    // bare host was normalized into a connectable ws:// URL.
    expect(find.text('Add daemon'), findsOneWidget);
    expect(find.text('Local'), findsOneWidget);
    expect(data.connections.endpoints, hasLength(1));
    expect(
      data.connections.endpoints.single.url,
      'ws://localhost:7331/ws',
    );
    expect(data.connections.endpoints.single.token, 'secret');
    // Adding an endpoint triggers a connection attempt (AppData rewires the
    // endpoint to a WsDaemonClient). Nothing listens on localhost:7331, so
    // the attempt cannot succeed — but under the widget-test binding the
    // mocked HttpClient swallows the ws handshake, so the refusal never
    // resolves here (the real app lands `failed`; ws_daemon_client_test
    // pins that failure path against a real dead port). Never `connected`.
    expect(
      data.connections.statusOf(data.connections.endpoints.single.id),
      isNot(ConnectionStatus.connected),
    );
  });

  test('addEndpoint normalizes bare hosts into ws:// URLs', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final ConnectionsStore store = ConnectionsStore();
    await store.addEndpoint(name: 'a', url: 'localhost:7331', token: '');
    await store.addEndpoint(name: 'b', url: 'ws://host:9000/ws', token: '');
    await store.addEndpoint(name: 'c', url: 'wss://secure.example', token: '');
    await store.addEndpoint(
      name: 'd',
      url: 'wss://tunnel.example/proxy',
      token: '',
    );
    await store.addEndpoint(name: 'e', url: '  ws://host:1/  ', token: '');

    expect(store.endpoints[0].url, 'ws://localhost:7331/ws');
    expect(store.endpoints[1].url, 'ws://host:9000/ws'); // untouched
    expect(store.endpoints[2].url, 'wss://secure.example/ws');
    expect(store.endpoints[3].url, 'wss://tunnel.example/proxy'); // path kept
    expect(store.endpoints[4].url, 'ws://host:1/ws'); // trimmed
  });

  test('updateEndpoint replaces fields in place, normalizes, and persists',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final ConnectionsStore store = ConnectionsStore();
    await store.addEndpoint(name: 'a', url: 'localhost:1', token: 't1');
    final String id = store.endpoints.single.id;

    await store.updateEndpoint(
        id: id, name: 'B', url: 'example:9000', token: 't2');
    expect(store.endpoints.single.id, id);
    expect(store.endpoints.single.name, 'B');
    expect(store.endpoints.single.url, 'ws://example:9000/ws');
    expect(store.endpoints.single.token, 't2');

    // Persisted: a fresh store over the same prefs sees the edit.
    final ConnectionsStore reloaded = ConnectionsStore();
    await reloaded.init();
    expect(reloaded.endpoints.single.name, 'B');
    expect(reloaded.endpoints.single.url, 'ws://example:9000/ws');

    // Unknown ids are a no-op.
    await store.updateEndpoint(id: 'nope', name: 'x', url: 'y', token: '');
    expect(store.endpoints, hasLength(1));
    expect(store.endpoints.single.name, 'B');
  });

  test('replaceEndpoints applies an authoritative persistent snapshot', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final ConnectionsStore store = ConnectionsStore();
    await store.addEndpoint(
      id: 'embedded',
      name: 'This computer',
      url: 'ws://127.0.0.1:7331/ws',
      token: '',
      persist: false,
      embedded: true,
    );
    await store.addEndpoint(
      id: 'old',
      name: 'Old',
      url: 'old.example:7331',
      token: 'old',
    );

    await store.replaceEndpoints(const <DaemonEndpoint>[
      DaemonEndpoint(
        id: 'new',
        name: 'New',
        url: 'new.example:9000',
        token: 'new-token',
      ),
    ]);

    expect(store.endpoints.map((DaemonEndpoint endpoint) => endpoint.id),
        <String>['embedded', 'new']);
    expect(store.endpoints.last.url, 'ws://new.example:9000/ws');
    final ConnectionsStore reloaded = ConnectionsStore();
    await reloaded.init();
    expect(reloaded.endpoints.single.id, 'new');
  });

  testWidgets('demo mode: buildDemoAppData populates the tree without taps',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final AppData data = buildDemoAppData();
    addTearDown(data.dispose);

    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(SpeedDialApp(data: data));
    // Let the unawaited project/session refreshes land.
    await tester.pump();
    await tester.pump();

    // The rail shows the seeded project without any user interaction.
    expect(data.selection.selectedDaemonId, 'demo');
    expect(find.text('Local demo'), findsOneWidget);
    expect(find.text('Demo Project'), findsOneWidget);
    expect(find.text('No projects yet'), findsNothing);

    // The demo opens straight into a live session: project + session
    // selected, scripted turn streamed into the timeline.
    await tester.pump(const Duration(milliseconds: 100));
    expect(data.selection.selectedProjectId, isNotNull);
    expect(data.selection.selectedSessionId, isNotNull);
    // Drain the scripted turn (~9 events at the fake's 50ms event delay) so
    // no timers outlive the test.
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('Working on it', findRichText: true),
        findsOneWidget);
    expect(find.textContaining('Add retry logic', findRichText: true),
        findsOneWidget);
  });

  testWidgets('mobile: tapping a session in the drawer selects it and closes the drawer',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final FakeDaemonClient fake =
        FakeDaemonClient(eventDelay: const Duration(milliseconds: 1));
    final AppData data = AppData()..registerClient('fake', fake);
    await data.connections.addEndpoint(
      id: 'fake',
      name: 'Fake daemon',
      url: 'fake://local',
      token: '',
    );
    await data.projects.refresh('fake');
    await data.sessions.refresh('fake');
    data.selection.selectedDaemonId = 'fake';
    addTearDown(data.dispose);

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(SpeedDialApp(data: data));
    await tester.pump();

    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    expect(find.text('Demo Project'), findsOneWidget);

    await tester.tap(find.text('Demo Project'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Build the feature'));
    await tester.pumpAndSettle();

    // The session was selected and the drawer dismissed; the AppBar title
    // now shows the session title instead of the rail row.
    expect(data.selection.selectedSessionId, 'sess-1');
    expect(find.text('Daemons'), findsNothing);
    expect(find.text('Build the feature'), findsOneWidget);
  });

  testWidgets('top bar shows the selected session title and follows renames',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final FakeDaemonClient fake =
        FakeDaemonClient(eventDelay: const Duration(milliseconds: 1));
    final AppData data = AppData()..registerClient('fake', fake);
    await data.connections.addEndpoint(
      id: 'fake',
      name: 'Fake daemon',
      url: 'fake://local',
      token: '',
    );
    await data.projects.refresh('fake');
    await data.sessions.refresh('fake');
    data.selection
      ..selectedDaemonId = 'fake'
      ..selectedProjectId = 'proj-demo';
    addTearDown(data.dispose);

    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(SpeedDialApp(data: data));
    await tester.pump();

    Text topBarTitle() =>
        tester.widget<Text>(find.byKey(const Key('top-bar-title')));

    // No session selected: the app name is the fallback.
    expect(topBarTitle().data, 'SpeedDial');

    data.selection.selectedSessionId = 'sess-1';
    await tester.pump();
    expect(topBarTitle().data, 'Build the feature');

    // A rename propagates through the store into the title.
    await data.sessions.rename('fake', 'sess-1', 'Ship it');
    await tester.pump();
    expect(topBarTitle().data, 'Ship it');
    // Drain the fake's delayed sessionUpdates broadcast so no timer
    // outlives the test.
    await tester.pump(const Duration(milliseconds: 5));

    // Deselecting falls back to the app name.
    data.selection.selectedSessionId = null;
    await tester.pump();
    expect(topBarTitle().data, 'SpeedDial');
  });

  testWidgets('narrow layout with a session already selected keeps the timeline',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final FakeDaemonClient fake =
        FakeDaemonClient(eventDelay: const Duration(milliseconds: 1));
    final AppData data = AppData()..registerClient('fake', fake);
    await data.connections.addEndpoint(
      id: 'fake',
      name: 'Fake daemon',
      url: 'fake://local',
      token: '',
    );
    await data.projects.refresh('fake');
    await data.sessions.refresh('fake');
    final Project project = (await fake.listProjects()).first;
    final Session session = (await fake.listSessions()).first;
    await fake.sendMessage(session.id, 'hello seeded');
    await tester.pump(const Duration(seconds: 1)); // run the scripted turn
    data.selection
      ..selectedDaemonId = 'fake'
      ..selectedProjectId = project.id
      ..selectedSessionId = session.id;
    addTearDown(data.dispose);

    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(SpeedDialApp(data: data));
    await tester.pump();

    // Switch to the narrow (mobile) layout: the chat pane must not lose its
    // session watch or its rendered timeline.
    tester.view.physicalSize = const Size(390, 844);
    await tester.pump();
    await tester.pump();

    expect(find.text('hello seeded'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 350));
  });
}
