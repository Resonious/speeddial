import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:speeddial_app/main.dart';
import 'package:speeddial_app/src/scope.dart';

void main() {
  /// Pumps the real app with real stores over an empty shared_preferences
  /// mock at the given logical viewport size.
  Future<AppData> pumpApp(WidgetTester tester, {Size size = const Size(1440, 900)}) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final AppData data = AppData(
      connections: ConnectionsStore(),
      selection: SelectionStore(),
    );
    await data.connections.init();
    addTearDown(() {
      data.connections.dispose();
      data.selection.dispose();
    });

    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(SpeedDialApp(data: data));
    await tester.pump();
    return data;
  }

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

    // Dialog closed, endpoint materialized in the store and the rail.
    expect(find.text('Add daemon'), findsOneWidget);
    expect(find.text('Local'), findsOneWidget);
    expect(data.connections.endpoints, hasLength(1));
    expect(data.connections.endpoints.single.url, 'localhost:7331');
    expect(data.connections.endpoints.single.token, 'secret');
    expect(
      data.connections.statusOf(data.connections.endpoints.single.id),
      ConnectionStatus.disconnected,
    );
  });
}
