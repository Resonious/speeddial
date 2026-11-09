import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/scope.dart';
import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/ui/left/selected_item_scroll_view.dart';
import 'package:speeddial_app/src/ui/left/session_list.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import 'left_rail_test.dart' show pumpRail, selectFakeDaemon;

Finder listFor(String label) => find.byWidgetPredicate(
  (Widget widget) =>
      widget is SelectedItemScrollView && widget.itemLabel == label,
);

ScrollPosition positionFor(WidgetTester tester, String label) => tester
    .state<ScrollableState>(
      find.descendant(of: listFor(label), matching: find.byType(Scrollable)),
    )
    .position;

Future<AppData> populateSessions(WidgetTester tester) async {
  final AppData app = await pumpRail(tester);
  await selectFakeDaemon(tester, app);
  final Project project = app.projects.projectsFor('fake').single;
  for (int i = 0; i < 25; i++) {
    await app.sessions.create(
      'fake',
      projectId: project.id,
      providerId: 'omp',
      title: 'Session $i',
    );
  }
  final Session selected = app.sessions
      .sessionsFor(project.id, daemonId: 'fake')
      .last;
  app.selection.selectSession(
    daemonId: 'fake',
    projectId: project.id,
    sessionId: selected.id,
  );
  await tester.pumpAndSettle();
  return app;
}

Finder selectionLabel(String label) => find.byWidgetPredicate(
  (Widget widget) => widget is Semantics && widget.properties.label == label,
);

void main() {
  testWidgets('daemon highlight stays inside its scrollable material', (
    WidgetTester tester,
  ) async {
    final AppData app = await pumpRail(tester);
    for (int i = 0; i < 12; i++) {
      app.registerClient('daemon-$i', FakeDaemonClient());
      await app.connections.addEndpoint(
        id: 'daemon-$i',
        name: 'Daemon $i',
        url: 'fake://$i',
        token: '',
      );
    }
    app.selection.selectDaemon('fake');
    await tester.pumpAndSettle();
    final Finder tile = find.ancestor(
      of: find.text('Fake daemon'),
      matching: find.byType(ListTile),
    );
    // The ink must be painted below the viewport, not on the rail's Material.
    expect(
      find.descendant(
        of: listFor('daemon'),
        matching: find.ancestor(of: tile, matching: find.byType(Material)),
      ),
      findsWidgets,
    );
    positionFor(tester, 'daemon').jumpTo(500);
    await tester.pumpAndSettle();
    expect(selectionLabel('Selected daemon above'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.arrow_upward), findsNothing);
    app.selection.selectDaemon(app.connections.endpoints.last.id);
    await tester.pumpAndSettle();
    expect(selectionLabel('Selected daemon below'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_downward));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.arrow_downward), findsNothing);
  });

  testWidgets(
    'tree tracks nested sessions and collapses to the project header',
    (WidgetTester tester) async {
      await populateSessions(tester);
      expect(selectionLabel('Selected session below'), findsOneWidget);
      final ScrollPosition position = positionFor(tester, 'session');
      await tester.tap(find.byIcon(Icons.arrow_downward));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.arrow_downward), findsNothing);
      final Finder selectedRow = find.byWidgetPredicate(
        (Widget widget) => widget is SessionRow && widget.selected,
      );
      expect(
        find.descendant(of: selectedRow, matching: find.byType(Material)),
        findsWidgets,
      );
      position.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Demo Project'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.arrow_downward), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Inbox tracks selection and removes its arrow when filtered out',
    (WidgetTester tester) async {
      await populateSessions(tester);
      await tester.tap(find.byKey(const Key('rail-tab-inbox')));
      await tester.pumpAndSettle();
      expect(selectionLabel('Selected session below'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.arrow_downward));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.arrow_downward), findsNothing);
      await tester.enterText(
        find.byKey(const Key('inbox-search-field')),
        'Session 2',
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.arrow_downward), findsNothing);
      expect(find.byIcon(Icons.arrow_upward), findsNothing);
      expect(find.text('Session 24').hitTestable(), findsOneWidget);
    },
  );
}
