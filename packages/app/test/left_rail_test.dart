import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/scope.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/left/left_rail.dart';

/// Pumps the left rail at a phone-ish viewport with one fake daemon
/// registered as `'fake'` and visible as an endpoint tile.
Future<AppData> pumpRail(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final AppData app = AppData()
    ..registerClient(
      'fake',
      FakeDaemonClient(eventDelay: const Duration(milliseconds: 1)),
    );
  await app.connections.addEndpoint(
    id: 'fake',
    name: 'Fake daemon',
    url: 'fake://local',
    token: '',
  );
  addTearDown(app.dispose);

  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildSpeedDialTheme(),
      home: Scaffold(
        body: AppScope(
          data: app,
          child: const LeftRail(),
        ),
      ),
    ),
  );
  await tester.pump();
  return app;
}

/// Taps the fake daemon tile and settles, mirroring what a user does to
/// populate the tree.
Future<AppData> selectFakeDaemon(WidgetTester tester, AppData app) async {
  await tester.tap(find.text('Fake daemon'));
  await tester.pumpAndSettle();
  return app;
}

void main() {
  testWidgets('empty state before any daemon is selected', (WidgetTester tester) async {
    final AppData app = await pumpRail(tester);

    expect(find.text('Daemons'), findsOneWidget);
    expect(find.text('Fake daemon'), findsOneWidget);
    expect(find.text('Add daemon'), findsOneWidget);
    expect(find.text('Add a daemon to begin'), findsOneWidget);
    expect(find.text('Projects'), findsNothing);
    expect(find.text('Demo Project'), findsNothing);
    expect(app.selection.selectedDaemonId, isNull);
  });

  testWidgets('selecting the fake daemon loads and lists the seeded project',
      (WidgetTester tester) async {
    final AppData app = await pumpRail(tester);

    await selectFakeDaemon(tester, app);

    expect(app.selection.selectedDaemonId, 'fake');
    expect(find.text('Projects'), findsOneWidget);
    expect(find.text('Demo Project'), findsOneWidget);
    expect(find.text('/demo'), findsOneWidget);
    expect(app.projects.projectsFor('fake'), hasLength(1));
  });

  testWidgets('expanding the project shows the seeded sessions with status chips',
      (WidgetTester tester) async {
    final AppData app = await pumpRail(tester);
    await selectFakeDaemon(tester, app);

    await tester.tap(find.text('Demo Project'));
    await tester.pumpAndSettle();

    expect(find.text('Build the feature'), findsOneWidget);
    expect(find.text('Plan the refactor'), findsOneWidget);
    // Status chips for the two idle sessions.
    expect(find.text('idle'), findsNWidgets(2));
    // Provider badge + mode label per session.
    expect(find.text('omp'), findsNWidgets(2));
    expect(find.text('build'), findsOneWidget);
    expect(find.text('plan'), findsOneWidget);
    // Expanding selects the project.
    final Project demo = app.projects.projectsFor('fake').single;
    expect(demo.name, 'Demo Project');
    expect(app.selection.selectedProjectId, demo.id);
  });

  testWidgets('session rows show git badges from the daemon summaries',
      (WidgetTester tester) async {
    final AppData app = await pumpRail(tester);
    await selectFakeDaemon(tester, app);

    await tester.tap(find.text('Demo Project'));
    await tester.pumpAndSettle();

    // Seeded fake: sess-1 is dirty and two commits ahead of main; sess-2
    // shares the dirty project checkout and has no base branch.
    expect(find.text('changes'), findsNWidgets(2));
    expect(find.text('↑2'), findsOneWidget);
    expect(find.text('merged'), findsNothing);

    // New scripted state lands on the next refresh: sess-1 merged, sess-2
    // reports all-unknown and renders no badges.
    final FakeDaemonClient fake = app.clientFor('fake') as FakeDaemonClient;
    fake.sessionGitSummaries['sess-1'] = const SessionGitSummary(
      sessionId: 'sess-1',
      dirty: false,
      aheadOfBase: 0,
      mergedIntoBase: true,
    );
    fake.sessionGitSummaries.remove('sess-2');
    await app.git.refreshSessionSummaries('fake', 'proj-demo');
    await tester.pumpAndSettle();

    expect(find.text('changes'), findsNothing);
    expect(find.text('↑2'), findsNothing);
    expect(find.text('merged'), findsOneWidget);
  });

  testWidgets('a failed endpoint offers Retry now in its actions menu',
      (WidgetTester tester) async {
    final AppData app = await pumpRail(tester);

    // A healthy endpoint has no retry entry.
    app.connections.setStatus('fake', ConnectionStatus.connected);
    await tester.pump();
    await tester.tap(find.byKey(const Key('endpoint-actions-fake')));
    await tester.pumpAndSettle();
    expect(find.text('Retry now'), findsNothing);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Remove'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10)); // dismiss the menu
    await tester.pumpAndSettle();

    // A failed one does, and tapping it triggers AppData.reconnect (a no-op
    // for this registered fake, but the wiring must not throw).
    app.connections.setStatus('fake', ConnectionStatus.failed);
    await tester.pump();
    await tester.tap(find.byKey(const Key('endpoint-actions-fake')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('endpoint-action-retry')), findsOneWidget);
    await tester.tap(find.text('Retry now'));
    await tester.pumpAndSettle();
    expect(find.text('Retry now'), findsNothing); // menu closed
  });

  testWidgets('+ Project adds a project row; a project without sessions says so',
      (WidgetTester tester) async {
    final AppData app = await pumpRail(tester);
    await selectFakeDaemon(tester, app);

    await tester.tap(find.byKey(const Key('add-project')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('add-project-path')),
      '/tmp/x',
    );
    await tester.tap(find.byKey(const Key('add-project-submit')));
    await tester.pumpAndSettle();

    expect(find.text('Demo Project'), findsOneWidget);
    expect(find.text('x'), findsOneWidget);
    expect(find.text('/tmp/x'), findsOneWidget);
    expect(app.projects.projectsFor('fake'), hasLength(2));

    // Empty project expands to a "No sessions" hint.
    await tester.tap(find.text('x'));
    await tester.pumpAndSettle();
    expect(find.text('No sessions'), findsOneWidget);
  });

  testWidgets('new-session sheet sends the initial prompt and creates a '
      'worktree session', (WidgetTester tester) async {
    final AppData app = await pumpRail(tester);
    await selectFakeDaemon(tester, app);
    await tester.tap(find.text('Demo Project'));
    await tester.pumpAndSettle();

    // Open the sheet from the project's new-session button.
    await tester.tap(
      find.byKey(const ValueKey<String>('new-session-proj-demo')),
    );
    await tester.pumpAndSettle();

    expect(find.text('New session'), findsOneWidget);
    // Provider dropdown defaults to the daemon's first available provider.
    expect(find.text('OMP Agent'), findsOneWidget);
    // The title field is gone; the prompt is the primary input, and a git
    // project offers worktree creation with the current branch preselected.
    expect(find.byKey(const Key('new-session-title')), findsNothing);
    expect(find.byKey(const Key('new-session-prompt')), findsOneWidget);
    expect(find.byKey(const Key('new-session-worktree')), findsOneWidget);
    expect(find.byKey(const Key('new-session-base-branch')), findsOneWidget);
    expect(find.text('main'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('new-session-prompt')),
      'Fix the login redirect\nIt loops on mobile.',
    );
    await tester.tap(find.byKey(const Key('new-session-submit')));
    await tester.pumpAndSettle();

    // Sheet closed; the prompt's first line became the rail title.
    expect(find.text('New session'), findsNothing);
    expect(find.text('Fix the login redirect'), findsOneWidget);

    final Project demo = app.projects.projectsFor('fake').single;
    final List<Session> sessions = app.sessions.sessionsFor(demo.id);
    expect(sessions, hasLength(3));
    final Session created = sessions.lastWhere(
        (Session s) => s.id != 'sess-1' && s.id != 'sess-2');
    expect(created.title, 'Fix the login redirect');
    expect(created.cwd, contains('.speeddial-worktrees'),
        reason: 'a base branch routes the session into a worktree');
    expect(created.projectId, demo.id);
    expect(app.selection.selectedSessionId, created.id);
    expect(app.selection.selectedProjectId, demo.id);

    // The prompt went out as the session's first turn.
    app.chat.watchSession('fake', created.id);
    await tester.pump();
    await tester.pump();
    expect(
      app.chat
          .eventsFor(created.id)
          .whereType<UserMessageEvent>()
          .map((UserMessageEvent e) => e.text),
      contains('Fix the login redirect\nIt loops on mobile.'),
    );
  });

  testWidgets('unchecking the worktree box hides the base branch and keeps '
      'the project cwd', (WidgetTester tester) async {
    final AppData app = await pumpRail(tester);
    await selectFakeDaemon(tester, app);
    await tester.tap(find.text('Demo Project'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('new-session-proj-demo')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('new-session-worktree')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('new-session-base-branch')), findsNothing);

    await tester.enterText(
        find.byKey(const Key('new-session-prompt')), 'Quick fix');
    await tester.tap(find.byKey(const Key('new-session-submit')));
    await tester.pumpAndSettle();

    final Project demo = app.projects.projectsFor('fake').single;
    final Session created = app.sessions
        .sessionsFor(demo.id)
        .lastWhere((Session s) => s.id != 'sess-1' && s.id != 'sess-2');
    expect(created.title, 'Quick fix');
    expect(created.cwd, demo.path);
  });

  testWidgets('base branch selector filters the branch list by text',
      (WidgetTester tester) async {
    final AppData app = await pumpRail(tester);
    await selectFakeDaemon(tester, app);
    await tester.tap(find.text('Demo Project'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('new-session-proj-demo')),
    );
    await tester.pumpAndSettle();

    // Typing filters the entries; non-matching branches leave the menu.
    await tester.tap(find.byKey(const Key('new-session-base-branch')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('new-session-base-branch')), 'feat');
    await tester.pumpAndSettle();
    expect(find.text('feature/x'), findsOneWidget);
    expect(find.text('main'), findsNothing);

    await tester.tap(find.text('feature/x'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new-session-submit')));
    await tester.pumpAndSettle();

    final Project demo = app.projects.projectsFor('fake').single;
    final Session created = app.sessions
        .sessionsFor(demo.id)
        .lastWhere((Session s) => s.id != 'sess-1' && s.id != 'sess-2');
    expect(created.baseBranch, 'feature/x');
    expect(created.cwd, contains('.speeddial-worktrees'));
  });

  testWidgets('deleting the selected session clears the selection',
      (WidgetTester tester) async {
    final AppData app = await pumpRail(tester);
    await selectFakeDaemon(tester, app);
    await tester.tap(find.text('Demo Project'));
    await tester.pumpAndSettle();

    // Select the first session row.
    await tester.tap(find.text('Build the feature'));
    await tester.pumpAndSettle();
    expect(app.selection.selectedSessionId, 'sess-1');

    // Delete it via the row menu and confirm.
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(ListTile, 'Build the feature'),
        matching: find.byIcon(Icons.more_vert),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-delete-confirm')));
    await tester.pumpAndSettle();

    // The chat pane must unpin from the dead session; the project stays.
    expect(app.selection.selectedSessionId, isNull);
    expect(app.selection.selectedProjectId, 'proj-demo');
    expect(find.text('Build the feature'), findsNothing);
    expect(find.text('Plan the refactor'), findsOneWidget);
  });

  testWidgets('archiving a session removes it from the default list',
      (WidgetTester tester) async {
    final AppData app = await pumpRail(tester);
    await selectFakeDaemon(tester, app);
    await tester.tap(find.text('Demo Project'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: find.widgetWithText(ListTile, 'Build the feature'),
        matching: find.byIcon(Icons.more_vert),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();

    expect(find.text('Build the feature'), findsNothing);
    expect(find.text('Plan the refactor'), findsOneWidget);

    final Project demo = app.projects.projectsFor('fake').single;
    expect(app.sessions.sessionsFor(demo.id), hasLength(1));
    expect(
      app.sessions.sessionsFor(demo.id).single.title,
      'Plan the refactor',
    );
  });

  testWidgets('add daemon dialog still adds an endpoint to the rail',
      (WidgetTester tester) async {
    final AppData app = await pumpRail(tester);

    await tester.tap(find.text('Add daemon'));
    await tester.pumpAndSettle();
    expect(find.text('Add daemon'), findsNWidgets(2)); // rail button + dialog title.

    await tester.enterText(find.byKey(const Key('add-daemon-name')), 'Local');
    await tester.enterText(find.byKey(const Key('add-daemon-url')), 'localhost:7331');
    await tester.enterText(find.byKey(const Key('add-daemon-token')), 'secret');
    await tester.tap(find.byKey(const Key('add-daemon-submit')));
    await tester.pumpAndSettle();

    expect(find.text('Add daemon'), findsOneWidget);
    expect(find.text('Local'), findsOneWidget);
    expect(app.connections.endpoints, hasLength(2));
    // The endpoint is wired to a WsDaemonClient whose attempt to reach the
    // dead normalized URL cannot complete under the widget-test binding
    // (mocked HttpClient swallows the handshake — see shell_test); it is
    // never `connected`, only failed/hanging in the real app.
    expect(
      app.connections.statusOf(
        app.connections.endpoints.lastWhere((DaemonEndpoint e) => e.id != 'fake').id,
      ),
      isNot(ConnectionStatus.connected),
    );
  });

  testWidgets('endpoint menu edits a daemon in place', (WidgetTester tester) async {
    final AppData app = await pumpRail(tester);
    await selectFakeDaemon(tester, app);

    await tester.tap(find.byKey(const Key('endpoint-actions-fake')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    // Prefilled with the stored (normalized) values.
    expect(find.text('Edit daemon'), findsOneWidget);
    expect(
      tester
          .widget<TextFormField>(find.byKey(const Key('add-daemon-name')))
          .controller!
          .text,
      'Fake daemon',
    );
    expect(
      tester
          .widget<TextFormField>(find.byKey(const Key('add-daemon-url')))
          .controller!
          .text,
      'fake://local/ws',
    );

    await tester.enterText(
        find.byKey(const Key('add-daemon-name')), 'Renamed daemon');
    await tester.tap(find.byKey(const Key('add-daemon-submit')));
    await tester.pumpAndSettle();

    // Same endpoint, new name — the id is stable so the registered client
    // and the selection survive the edit.
    expect(app.connections.endpoints.single.id, 'fake');
    expect(app.connections.endpoints.single.name, 'Renamed daemon');
    expect(find.text('Renamed daemon'), findsOneWidget);
    expect(app.selection.selectedDaemonId, 'fake');
  });

  testWidgets('endpoint menu removes a daemon after confirmation',
      (WidgetTester tester) async {
    final AppData app = await pumpRail(tester);
    await selectFakeDaemon(tester, app);
    expect(app.selection.selectedDaemonId, 'fake');

    await tester.tap(find.byKey(const Key('endpoint-actions-fake')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();

    // Confirmation names the endpoint; cancelling keeps it.
    expect(find.text('Remove daemon'), findsOneWidget);
    expect(
        find.textContaining(
            'Its sessions and projects stay on the daemon'),
        findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(app.connections.endpoints, hasLength(1));

    await tester.tap(find.byKey(const Key('endpoint-actions-fake')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('daemon-remove-confirm')));
    await tester.pumpAndSettle();

    expect(app.connections.endpoints, isEmpty);
    expect(find.text('Fake daemon'), findsNothing);
    expect(find.text('No daemons yet'), findsOneWidget);
    // The selected daemon vanished: selection is cleared with it.
    expect(app.selection.selectedDaemonId, isNull);
    expect(app.selection.selectedProjectId, isNull);
    expect(app.selection.selectedSessionId, isNull);
  });
}
