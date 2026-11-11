import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/scope.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/left/session_list.dart';
import 'package:speeddial_app/src/ui/right/note_check.dart';
import 'package:speeddial_app/src/ui/right/notes_panel.dart';
import 'package:speeddial_app/src/ui/right/right_panel.dart';

/// The fake daemon seeds three notes: "Build the feature" (sess-1) has one
/// checked off and one open, "Plan the refactor" (sess-2) one open.
void main() {
  Future<AppData> pumpNotes(
    WidgetTester tester,
    FakeDaemonClient fake, {
    String? selectedSession = 'sess-1',
    bool light = false,
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final AppData app = AppData()..registerClient('fake', fake);
    await app.connections.addEndpoint(
      id: 'fake',
      name: 'Fake daemon',
      url: 'fake://local',
      token: '',
    );
    addTearDown(app.dispose);
    final Project project = (await fake.listProjects()).single;
    await app.projects.refresh('fake');
    await app.sessions.refresh('fake');
    if (selectedSession != null) {
      app.selection.selectSession(
        daemonId: 'fake',
        projectId: project.id,
        sessionId: selectedSession,
      );
    }

    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: light ? buildSpeedDialLightTheme() : buildSpeedDialTheme(),
        home: Scaffold(
          body: AppScope(data: app, child: const RightPanel()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return app;
  }

  testWidgets('lists open notes across sessions, selected session first', (
    WidgetTester tester,
  ) async {
    await pumpNotes(tester, FakeDaemonClient());

    expect(find.text('2 open'), findsOneWidget);
    expect(find.text('Build the feature'), findsOneWidget);
    expect(find.text('Plan the refactor'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Build the feature')).dy,
      lessThan(tester.getTopLeft(find.text('Plan the refactor')).dy),
    );
    expect(find.text('Add a widget test for the retry card'), findsOneWidget);
    expect(find.text('Ask about the release date'), findsOneWidget);
    // Checked-off notes hide behind a toggle on the selected session only.
    expect(find.text('Check the empty-state copy'), findsNothing);
    expect(find.text('1 done'), findsOneWidget);
    await tester.tap(find.text('1 done'));
    await tester.pumpAndSettle();
    expect(find.text('Check the empty-state copy'), findsOneWidget);
    expect(find.byKey(const Key('note-composer')), findsOneWidget);
  });

  testWidgets('without a selection only open notes show, and no composer', (
    WidgetTester tester,
  ) async {
    await pumpNotes(tester, FakeDaemonClient(), selectedSession: null);
    expect(find.byKey(const Key('note-composer')), findsNothing);
    expect(find.text('1 done'), findsNothing);
    expect(find.text('Add a widget test for the retry card'), findsOneWidget);
    expect(find.text('Ask about the release date'), findsOneWidget);
  });

  testWidgets('the composer adds a note to the selected session', (
    WidgetTester tester,
  ) async {
    final FakeDaemonClient fake = FakeDaemonClient();
    await pumpNotes(tester, fake);

    await tester.enterText(
      find.byKey(const Key('note-composer')),
      '  Update the changelog ',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('Update the changelog'), findsOneWidget);
    expect(find.text('3 open'), findsOneWidget);
    final List<SessionNote> notes = await fake.listNotes(sessionId: 'sess-1');
    expect(notes.last.text, 'Update the changelog');
    expect(notes.last.done, isFalse);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('checking off another session\'s note pops, lingers, and folds '
      'away', (WidgetTester tester) async {
    final FakeDaemonClient fake = FakeDaemonClient();
    await pumpNotes(tester, fake);

    final Finder row = find.ancestor(
      of: find.text('Ask about the release date'),
      matching: find.byType(NoteRow),
    );
    await tester.tap(
      find.descendant(of: row, matching: find.byType(NoteCheck)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // Still there, checked and struck through, while the check pops.
    expect(find.text('Ask about the release date'), findsOneWidget);
    expect(tester.hasRunningAnimations, isTrue);
    expect((await fake.listNotes(sessionId: 'sess-2')).single.done, isTrue);

    await tester.pump(kNoteLinger);
    await tester.pump(kNoteFold);
    await tester.pumpAndSettle();
    expect(find.text('Ask about the release date'), findsNothing);
    // The session's whole group goes with its last open note.
    expect(find.text('Plan the refactor'), findsNothing);
    expect(find.text('1 open'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('checking off the selected session\'s note moves it to done', (
    WidgetTester tester,
  ) async {
    await pumpNotes(tester, FakeDaemonClient());
    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text('Add a widget test for the retry card'),
          matching: find.byType(NoteRow),
        ),
        matching: find.byType(NoteCheck),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Add a widget test for the retry card'), findsNothing);
    expect(find.text('2 done'), findsOneWidget);

    // Reopening from the done list brings it back.
    await tester.tap(find.text('2 done'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text('Add a widget test for the retry card'),
          matching: find.byType(NoteRow),
        ),
        matching: find.byType(NoteCheck),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('1 done'), findsOneWidget);
    expect(find.text('2 open'), findsOneWidget);
  });

  testWidgets('reduced motion checks a note off without lingering', (
    WidgetTester tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await pumpNotes(tester, FakeDaemonClient());

    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text('Ask about the release date'),
          matching: find.byType(NoteRow),
        ),
        matching: find.byType(NoteCheck),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Ask about the release date'), findsNothing);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('tapping a note edits it; deleting removes it', (
    WidgetTester tester,
  ) async {
    final FakeDaemonClient fake = FakeDaemonClient();
    await pumpNotes(tester, fake);

    await tester.tap(find.text('Ask about the release date'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(NoteRow),
        matching: find.byType(TextField),
      ),
      'Ask about the launch date',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Ask about the launch date'), findsOneWidget);
    expect(
      (await fake.listNotes(sessionId: 'sess-2')).single.text,
      'Ask about the launch date',
    );

    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text('Ask about the launch date'),
          matching: find.byType(NoteRow),
        ),
        matching: find.byTooltip('Delete note'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Ask about the launch date'), findsNothing);
    expect(await fake.listNotes(sessionId: 'sess-2'), isEmpty);
  });

  testWidgets('tapping another session\'s header opens that session', (
    WidgetTester tester,
  ) async {
    final AppData app = await pumpNotes(tester, FakeDaemonClient());
    await tester.tap(find.text('Plan the refactor'));
    await tester.pumpAndSettle();
    expect(app.selection.selectedSessionId, 'sess-2');
    // The newly selected session now leads, with the composer.
    expect(
      tester.getTopLeft(find.text('Plan the refactor')).dy,
      lessThan(tester.getTopLeft(find.text('Build the feature')).dy),
    );
  });

  testWidgets('a failed check-off rolls back and says so', (
    WidgetTester tester,
  ) async {
    await pumpNotes(tester, _FailingUpdateFake());
    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text('Ask about the release date'),
          matching: find.byType(NoteRow),
        ),
        matching: find.byType(NoteCheck),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Ask about the release date'), findsOneWidget);
    expect(find.text('2 open'), findsOneWidget);
    expect(find.textContaining('Could not check off the note'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  });

  testWidgets('empty state explains notes', (WidgetTester tester) async {
    final FakeDaemonClient fake = FakeDaemonClient();
    for (final SessionNote note in await fake.listNotes()) {
      await fake.deleteNote(note.id);
    }
    await pumpNotes(tester, fake, selectedSession: null);
    expect(find.text('No open notes'), findsOneWidget);
  });

  testWidgets('session rows show checked-off and total note counts', (
    WidgetTester tester,
  ) async {
    final FakeDaemonClient fake = FakeDaemonClient();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final AppData app = AppData()..registerClient('fake', fake);
    addTearDown(app.dispose);
    await app.projects.refresh('fake');
    await app.sessions.refresh('fake');
    final List<Session> sessions = app.sessions.sessionsFor(
      'proj-demo',
      daemonId: 'fake',
    );
    Session session(String id) =>
        sessions.firstWhere((Session session) => session.id == id);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSpeedDialLightTheme(),
        home: Scaffold(
          body: AppScope(
            data: app,
            child: Column(
              children: <Widget>[
                SessionNotesBadge(session: session('sess-1'), daemonId: 'fake'),
                SessionNotesBadge(session: session('sess-2'), daemonId: 'fake'),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('1/2'), findsOneWidget);
    expect(find.text('0/1'), findsOneWidget);

    await fake.updateNote(
      (await fake.listNotes(sessionId: 'sess-2')).single.id,
      done: true,
    );
    await tester.pumpAndSettle();
    expect(find.text('1/1'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
  });
}

class _FailingUpdateFake extends FakeDaemonClient {
  @override
  Future<SessionNote> updateNote(
    String noteId, {
    String? text,
    bool? done,
  }) async {
    throw const DaemonError(-32603, 'disk full');
  }
}
