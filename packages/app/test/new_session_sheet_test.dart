import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/scope.dart';
import 'package:speeddial_app/src/state/settings_store.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/left/left_rail.dart';
import 'package:speeddial_app/src/ui/left/new_session_sheet.dart';

/// Pumps a host scaffold that opens [NewSessionSheet] as a real modal
/// bottom-sheet route (mirroring the left rail: scroll-controlled,
/// safe-area) against a fake daemon (either [fake] or a fresh scripted one).
/// The sheet is already open when this returns.
Future<({AppData app, String projectId})> pumpSheet(
  WidgetTester tester, {
  FakeDaemonClient? fake,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final FakeDaemonClient fakeClient =
      fake ?? FakeDaemonClient(eventDelay: const Duration(milliseconds: 1));
  final AppData app = AppData()..registerClient('fake', fakeClient);
  addTearDown(app.dispose);
  final String projectId = (await fakeClient.listProjects()).single.id;
  // Mirror what the rail does on load: seed the store caches so tests can
  // read them back without going through a create.
  await app.projects.refresh('fake');
  await app.sessions.refresh('fake');

  await tester.pumpWidget(
    MaterialApp(
      theme: buildSpeedDialTheme(),
      home: Scaffold(
        body: AppScope(
          data: app,
          child: Builder(
            builder: (BuildContext context) => Center(
              child: ElevatedButton(
                onPressed: () {
                  showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    useSafeArea: true,
                    builder: (BuildContext context) => Padding(
                      padding: EdgeInsets.only(
                        bottom: MediaQuery.viewInsetsOf(context).bottom,
                      ),
                      child: NewSessionSheet(
                        data: app,
                        daemonId: 'fake',
                        projectId: projectId,
                      ),
                    ),
                  );
                },
                child: const Text('open-sheet'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open-sheet'));
  await tester.pumpAndSettle();
  return (app: app, projectId: projectId);
}

/// The session most recently created through the fake, found by exclusion:
/// the two seeded sessions are 'sess-1' and 'sess-2'.
Session createdSession(AppData app, String projectId) {
  final List<Session> sessions = app.sessions.sessionsFor(projectId);
  return sessions.singleWhere(
    (Session s) => s.id != 'sess-1' && s.id != 'sess-2',
  );
}

void main() {
  testWidgets('the form asks for provider, supported safety settings and '
      'worktree — no prompt, model or mode', (WidgetTester tester) async {
    await pumpSheet(tester);

    // Ask-ahead removed: no initial prompt, model autocomplete or mode
    // selector. Provider-specific safety controls remain capability-gated.
    expect(find.byKey(const Key('new-session-provider')), findsOneWidget);
    expect(find.byKey(const Key('new-session-yolo')), findsOneWidget);
    expect(find.byKey(const Key('new-session-no-sandbox')), findsNothing);
    expect(find.byKey(const Key('new-session-worktree')), findsOneWidget);
    expect(find.byKey(const Key('new-session-base-branch')), findsOneWidget);
    expect(find.byKey(const Key('new-session-prompt')), findsNothing);
    expect(find.byKey(const Key('new-session-model')), findsNothing);
    expect(find.byKey(const Key('new-session-mode')), findsNothing);
    // The provider defaults to the daemon's first available provider.
    expect(find.text('OMP Agent'), findsOneWidget);
  });

  testWidgets('submit creates the session, selects it and pops — no turn '
      'starts', (WidgetTester tester) async {
    final (:app, :projectId) = await pumpSheet(tester);

    await tester.tap(find.byKey(const Key('new-session-submit')));
    await tester.pumpAndSettle();

    // Sheet closed and the new session selected in the rail's selection.
    expect(find.byKey(const Key('new-session-submit')), findsNothing);
    final Session created = createdSession(app, projectId);
    expect(app.selection.selectedProjectId, projectId);
    expect(app.selection.selectedSessionId, created.id);

    // Provider/baseBranch defaults honored; model was NOT passed, so the
    // daemon's default applies (agent-side adoption happens later from the
    // composer).
    expect(created.providerId, 'omp');
    expect(created.baseBranch, 'main');
    expect(created.cwd, contains('.speeddial-worktrees'));
    expect(created.model, 'omp-default');

    // Nothing was sent: the new session's history and event stream are
    // empty and no turn was ever started.
    final FakeDaemonClient fake = app.clientFor('fake') as FakeDaemonClient;
    expect((await fake.history(created.id)).events, isEmpty);
    expect(app.chat.statusOf(created.id), SessionStatus.idle);
    expect(
      app.chat.eventsFor(created.id).whereType<UserMessageEvent>(),
      isEmpty,
    );
  });

  testWidgets('yolo mode is off by default and sent when checked', (
    WidgetTester tester,
  ) async {
    final (:app, :projectId) = await pumpSheet(tester);

    // Default: no yolo.
    await tester.tap(find.byKey(const Key('new-session-submit')));
    await tester.pumpAndSettle();
    expect(createdSession(app, projectId).yolo, isFalse);

    // Reopen and check the toggle.
    await tester.tap(find.text('open-sheet'));
    await tester.pumpAndSettle();
    final Finder toggle = find.byKey(const Key('new-session-yolo'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new-session-submit')));
    await tester.pumpAndSettle();

    final List<Session> sessions = app.sessions.sessionsFor(projectId);
    final Session second = sessions.singleWhere(
      (Session s) => s.id != 'sess-1' && s.id != 'sess-2' && s.yolo,
    );
    expect(second.yolo, isTrue);
  });

  testWidgets('yolo mode checkbox is sticky across sheet opens', (
    WidgetTester tester,
  ) async {
    await pumpSheet(tester);

    CheckboxListTile yoloTile() => tester.widget<CheckboxListTile>(
      find.byKey(const Key('new-session-yolo')),
    );

    // Check it, then cancel without submitting.
    final Finder toggle = find.byKey(const Key('new-session-yolo'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Reopen: still checked.
    await tester.tap(find.text('open-sheet'));
    await tester.pumpAndSettle();
    expect(yoloTile().value, isTrue);

    // Unchecking sticks the same way.
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open-sheet'));
    await tester.pumpAndSettle();
    expect(yoloTile().value, isFalse);
  });

  testWidgets('Codex no-sandbox choice is sent and sticky across sheet opens', (
    WidgetTester tester,
  ) async {
    final (:app, :projectId) = await pumpSheet(tester);

    await tester.tap(find.byKey(const Key('new-session-provider')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Codex').last);
    await tester.pumpAndSettle();

    final Finder toggle = find.byKey(const Key('new-session-no-sandbox'));
    CheckboxListTile sandboxTile() => tester.widget<CheckboxListTile>(toggle);
    expect(toggle, findsOneWidget);
    expect(sandboxTile().value, isFalse);
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(app.settings.sandboxMode, SessionSandboxMode.unrestricted);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open-sheet'));
    await tester.pumpAndSettle();
    expect(toggle, findsOneWidget);
    expect(sandboxTile().value, isTrue);

    await tester.ensureVisible(find.byKey(const Key('new-session-submit')));
    await tester.tap(find.byKey(const Key('new-session-submit')));
    await tester.pumpAndSettle();
    final Session created = createdSession(app, projectId);
    expect(created.providerId, 'codex');
    expect(created.sandboxMode, SessionSandboxMode.unrestricted);

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(SettingsStore.sandboxStorageKey), 'unrestricted');
  });

  testWidgets('provider selection is sticky across app instances', (
    WidgetTester tester,
  ) async {
    await pumpSheet(tester);

    await tester.tap(find.byKey(const Key('new-session-provider')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Claude').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('open-sheet'));
    await tester.pumpAndSettle();
    DropdownButtonFormField<String> picker = tester.widget(
      find.byKey(const Key('new-session-provider')),
    );
    expect(picker.initialValue, 'claude');

    await tester.pumpWidget(const SizedBox.shrink());
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(SettingsStore.providerStorageKey), 'claude');

    final FakeDaemonClient fake = FakeDaemonClient(
      eventDelay: const Duration(milliseconds: 1),
    );
    final AppData app = AppData()..registerClient('fake', fake);
    addTearDown(app.dispose);
    await app.settings.init();
    expect(app.settings.providerId, 'claude');
  });

  testWidgets('unchecking the worktree box hides the base branch and keeps '
      'the project cwd', (WidgetTester tester) async {
    final (:app, :projectId) = await pumpSheet(tester);

    await tester.tap(find.byKey(const Key('new-session-worktree')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('new-session-base-branch')), findsNothing);

    await tester.tap(find.byKey(const Key('new-session-submit')));
    await tester.pumpAndSettle();
    final Session created = createdSession(app, projectId);
    expect(created.baseBranch, isNull);
    expect(created.cwd, app.projects.projectsFor('fake').single.path);
  });

  testWidgets('Cancel closes the sheet without creating a session', (
    WidgetTester tester,
  ) async {
    final (:app, :projectId) = await pumpSheet(tester);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('new-session-submit')), findsNothing);
    expect(app.sessions.sessionsFor(projectId), hasLength(2));
  });

  testWidgets('the action row stays clear of the system navigation bar', (
    WidgetTester tester,
  ) async {
    // Phone viewport with Android-15-style edge-to-edge bars: status bar on
    // top, gesture/navigation bar at the bottom (see safe_area_test.dart).
    const Size phone = Size(390, 844);
    const double statusBar = 24;
    const double navBar = 48;

    SharedPreferences.setMockInitialValues(<String, Object>{});
    final FakeDaemonClient fake = FakeDaemonClient(
      eventDelay: const Duration(milliseconds: 1),
    );
    final AppData app = AppData()..registerClient('fake', fake);
    addTearDown(app.dispose);
    await app.connections.addEndpoint(
      id: 'fake',
      name: 'Fake daemon',
      url: 'fake://local',
      token: '',
    );

    tester.view.physicalSize = phone;
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = const FakeViewPadding(top: statusBar, bottom: navBar);
    tester.view.viewPadding = const FakeViewPadding(
      top: statusBar,
      bottom: navBar,
    );
    addTearDown(tester.view.reset);

    // The rail hosts the real showModalBottomSheet route under test.
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSpeedDialTheme(),
        home: Scaffold(
          body: AppScope(data: app, child: const LeftRail()),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Fake daemon'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New session'));
    await tester.pumpAndSettle();

    // The action row must stay tappable above the gesture/navigation area.
    expect(
      tester.getBottomLeft(find.byKey(const Key('new-session-submit'))).dy,
      lessThanOrEqualTo(phone.height - navBar),
    );
    expect(
      tester.getBottomLeft(find.text('Cancel')).dy,
      lessThanOrEqualTo(phone.height - navBar),
    );
  });
}
