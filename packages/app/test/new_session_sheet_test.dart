import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/scope.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/daemon_error_text.dart';
import 'package:speeddial_app/src/ui/left/left_rail.dart';
import 'package:speeddial_app/src/ui/left/new_session_sheet.dart';

/// Pumps a host scaffold that opens [NewSessionSheet] as a real modal
/// bottom-sheet route (mirroring the left rail: caller-captured
/// [ScaffoldMessenger], scroll-controlled, safe-area) against a fake daemon
/// (either [fake] or a fresh scripted one) whose `omp` provider offers two
/// models. The sheet is already open when this returns.
///
/// A real route matters: submit pops the sheet, and the host survives
/// underneath — so post-create send failures can land in a snackbar.
Future<({AppData app, String projectId})> pumpSheet(WidgetTester tester,
    {FakeDaemonClient? fake}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final FakeDaemonClient fakeClient =
      fake ?? FakeDaemonClient(eventDelay: const Duration(milliseconds: 1));
  final AppData app = AppData()..registerClient('fake', fakeClient);
  addTearDown(app.dispose);
  final String projectId = (await fakeClient.listProjects()).single.id;

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
                  final ScaffoldMessengerState messenger =
                      ScaffoldMessenger.of(context);
                  showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    useSafeArea: true,
                    builder: (BuildContext context) => Padding(
                      padding: EdgeInsets.only(
                          bottom: MediaQuery.viewInsetsOf(context).bottom),
                      child: NewSessionSheet(
                        data: app,
                        daemonId: 'fake',
                        projectId: projectId,
                        messenger: messenger,
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
/// the two seeded sessions carry models 'omp-default' and null.
Session createdSession(AppData app, String projectId) {
  final List<Session> sessions = app.sessions.sessionsFor(projectId);
  return sessions.singleWhere(
      (Session s) => s.id != 'sess-1' && s.id != 'sess-2');
}

/// A fake whose sends always fail with [error], driving the sheet's
/// post-create send-failure snackbar path.
class _SendFailingFake extends FakeDaemonClient {
  _SendFailingFake(this.error);

  final Object error;

  @override
  Future<void> sendMessage(String sessionId, String text,
      {List<OutgoingAttachment>? attachments}) async {
    throw error;
  }
}

void main() {
  testWidgets('yolo mode is off by default and sent when checked',
      (WidgetTester tester) async {
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
    final Session second = sessions.singleWhere((Session s) =>
        s.id != 'sess-1' && s.id != 'sess-2' && s.yolo);
    expect(second.yolo, isTrue);
  });

  testWidgets('yolo mode checkbox is sticky across sheet opens',
      (WidgetTester tester) async {
    await pumpSheet(tester);

    CheckboxListTile yoloTile() =>
        tester.widget<CheckboxListTile>(find.byKey(const Key('new-session-yolo')));

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

  testWidgets('a connection drop while sending the initial prompt shows a '
      'soft reconnecting notice, not a raw error',
      (WidgetTester tester) async {
    await pumpSheet(
      tester,
      fake: _SendFailingFake(const DaemonConnectionError('peer closed')),
    );

    await tester.enterText(find.byKey(const Key('new-session-prompt')),
        'Fix the login redirect');
    await tester.tap(find.byKey(const Key('new-session-submit')));
    await tester.pumpAndSettle();

    // The drop self-heals (auto-reconnect + resync), so no raw socket
    // error and no "failed to send" framing reaches the user.
    expect(find.text(kConnectionLostMessage), findsOneWidget);
    expect(find.textContaining('Failed to send the initial prompt'),
        findsNothing);
    expect(find.textContaining('peer closed'), findsNothing);

    // Let the SnackBar auto-dismiss timer fire so the test ends clean.
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('a genuine rejection of the initial prompt still shows the '
      'raw error', (WidgetTester tester) async {
    await pumpSheet(
      tester,
      fake: _SendFailingFake(
          const DaemonError(kErrConflict, 'a turn is already running')),
    );

    await tester.enterText(find.byKey(const Key('new-session-prompt')),
        'Fix the login redirect');
    await tester.tap(find.byKey(const Key('new-session-submit')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Failed to send the initial prompt'),
        findsOneWidget);
    expect(find.textContaining('a turn is already running'), findsOneWidget);

    // Let the SnackBar auto-dismiss timer fire so the test ends clean.
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('keyboard dismissal keeps Cancel/Create session clear of the '
      'system navigation bar', (WidgetTester tester) async {
    // Phone viewport with Android-15-style edge-to-edge bars: status bar on
    // top, gesture/navigation bar at the bottom (see safe_area_test.dart).
    const Size phone = Size(390, 844);
    const double statusBar = 24;
    const double navBar = 48;

    SharedPreferences.setMockInitialValues(<String, Object>{});
    final FakeDaemonClient fake =
        FakeDaemonClient(eventDelay: const Duration(milliseconds: 1));
    final AppData app = AppData()..registerClient('fake', fake);
    addTearDown(app.dispose);
    await app.connections.addEndpoint(
        id: 'fake', name: 'Fake daemon', url: 'fake://local', token: '');

    tester.view.physicalSize = phone;
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding =
        const FakeViewPadding(top: statusBar, bottom: navBar);
    tester.view.viewPadding =
        const FakeViewPadding(top: statusBar, bottom: navBar);
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

    // The autofocused prompt opens the keyboard: Android reports the
    // keyboard as viewInsets and consumes the bottom system padding.
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    tester.view.padding = const FakeViewPadding(top: statusBar);
    await tester.pumpAndSettle();

    // Dismissing the keyboard sinks the sheet back to the screen's bottom
    // edge, where the nav bar overlays it.
    tester.view.viewInsets = const FakeViewPadding(bottom: 0);
    tester.view.padding =
        const FakeViewPadding(top: statusBar, bottom: navBar);
    await tester.pumpAndSettle();

    // The action row must stay tappable above the gesture/navigation area.
    expect(
        tester.getBottomLeft(find.byKey(const Key('new-session-submit'))).dy,
        lessThanOrEqualTo(phone.height - navBar));
    expect(tester.getBottomLeft(find.text('Cancel')).dy,
        lessThanOrEqualTo(phone.height - navBar));
  });
}
