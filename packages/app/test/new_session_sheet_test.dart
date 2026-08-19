import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/scope.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/left/new_session_sheet.dart';

/// Pumps [NewSessionSheet] directly (no bottom-sheet route) against a fake
/// daemon whose `omp` provider offers two models.
Future<({AppData app, String projectId})> pumpSheet(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final FakeDaemonClient fake =
      FakeDaemonClient(eventDelay: const Duration(milliseconds: 1));
  final AppData app = AppData()..registerClient('fake', fake);
  addTearDown(app.dispose);
  final String projectId = (await fake.listProjects()).single.id;

  await tester.pumpWidget(
    MaterialApp(
      theme: buildSpeedDialTheme(),
      home: Scaffold(
        body: AppScope(
          data: app,
          child: NewSessionSheet(
            data: app,
            daemonId: 'fake',
            projectId: projectId,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (app: app, projectId: projectId);
}

/// The session most recently created through the fake, found by exclusion:
/// the two seeded sessions carry models 'omp-default' and null.
Session createdSession(AppData app, String projectId) {
  final List<Session> sessions = app.sessions.sessionsFor(projectId);
  return sessions.singleWhere(
      (Session s) => s.id != 'sess-1' && s.id != 'sess-2');
}

void main() {
  testWidgets('model field offers provider models; selection is sent on '
      'create', (WidgetTester tester) async {
    final (:app, :projectId) = await pumpSheet(tester);

    // Focusing the field opens the provider's model list.
    await tester.tap(find.byKey(const Key('new-session-model')));
    await tester.pumpAndSettle();
    expect(find.text('omp-default'), findsOneWidget);
    expect(find.text('omp-fast'), findsOneWidget);

    await tester.tap(find.text('omp-fast'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('new-session-submit')));
    await tester.pumpAndSettle();
    expect(createdSession(app, projectId).model, 'omp-fast');
  });

  testWidgets('model list filters as you type', (WidgetTester tester) async {
    await pumpSheet(tester);

    await tester.enterText(
        find.byKey(const Key('new-session-model')), 'fast');
    await tester.pumpAndSettle();
    expect(find.text('omp-fast'), findsOneWidget);
    expect(find.text('omp-default'), findsNothing);
  });

  testWidgets('a hand-typed model id is sent as-is',
      (WidgetTester tester) async {
    final (:app, :projectId) = await pumpSheet(tester);

    await tester.enterText(
        find.byKey(const Key('new-session-model')), 'some/custom-id');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('new-session-submit')));
    await tester.pumpAndSettle();
    expect(createdSession(app, projectId).model, 'some/custom-id');
  });
}
