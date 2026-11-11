import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/scope.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/chat/composer.dart';
import 'package:speeddial_app/src/ui/right/right_panel.dart';
import 'package:speeddial_app/src/ui/shell.dart';

/// System-bar insets a phone reports under edge-to-edge (Android 15+):
/// status bar on top, gesture/navigation bar at the bottom.
const EdgeInsets kPhoneInsets = EdgeInsets.only(top: 24, bottom: 48);

/// Pumps [SpeedDialShell] with a fake daemon, a session selected, and fake
/// system-bar insets, at [size].
Future<AppData> pumpShell(WidgetTester tester, Size size) async {
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

  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  tester.view.padding =
      FakeViewPadding(top: kPhoneInsets.top, bottom: kPhoneInsets.bottom);
  tester.view.viewPadding =
      FakeViewPadding(top: kPhoneInsets.top, bottom: kPhoneInsets.bottom);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    // Mirrors main.dart: AppScope above MaterialApp, so routes pushed on the
    // Navigator (the narrow layout's right-panel sheet) still see it.
    AppScope(
      data: app,
      child: MaterialApp(
        theme: buildSpeedDialTheme(),
        home: const SpeedDialShell(),
      ),
    ),
  );
  await tester.pump();

  // Select through the same path the rail uses so a session (and therefore
  // the composer) is on screen.
  app.selection.selectedDaemonId = 'fake';
  await app.projects.refresh('fake');
  await app.sessions.refresh('fake');
  final Project demo = app.projects.projectsFor('fake').single;
  app.selection.selectedProjectId = demo.id;
  app.selection.selectedSessionId =
      app.sessions.sessionsFor(demo.id).first.id;
  await tester.pumpAndSettle();
  return app;
}

void main() {
  testWidgets('narrow layout keeps content clear of the system bars',
      (WidgetTester tester) async {
    const Size size = Size(390, 844);
    await pumpShell(tester, size);

    // AppBar content sits below the status bar; its background extends up.
    expect(tester.getTopLeft(find.byKey(const Key('top-bar-title'))).dy,
        greaterThanOrEqualTo(kPhoneInsets.top));

    // The composer (and its usage footer) clears the gesture area.
    expect(tester.getBottomLeft(find.byType(Composer)).dy,
        lessThanOrEqualTo(size.height - kPhoneInsets.bottom));

    // The drawer keeps its content off the bars too.
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Daemons')).dy,
        greaterThanOrEqualTo(kPhoneInsets.top));
  });

  testWidgets('narrow notes sheet lifts the note field above the keyboard',
      (WidgetTester tester) async {
    const Size size = Size(390, 844);
    const double keyboard = 300;
    await pumpShell(tester, size);

    await tester.tap(find.byTooltip('Open notes'));
    await tester.pumpAndSettle();
    final Finder field = find.byKey(const Key('note-composer'));
    expect(field, findsOneWidget);

    // Tapping the note field opens the keyboard: Android reports it as
    // viewInsets and consumes the bottom system padding.
    tester.view.viewInsets = const FakeViewPadding(bottom: keyboard);
    tester.view.padding = FakeViewPadding(top: kPhoneInsets.top);
    await tester.pumpAndSettle();

    expect(tester.getBottomLeft(field).dy,
        lessThanOrEqualTo(size.height - keyboard));
    // The sheet grew toward full height instead of overflowing: the header
    // stays on screen.
    expect(tester.getTopLeft(find.text('Notes')).dy, greaterThanOrEqualTo(0));

    // Dismissing the keyboard sinks the sheet back to the bottom edge.
    tester.view.viewInsets = FakeViewPadding.zero;
    tester.view.padding = FakeViewPadding(
        top: kPhoneInsets.top, bottom: kPhoneInsets.bottom);
    await tester.pumpAndSettle();
    expect(tester.getBottomLeft(field).dy,
        lessThanOrEqualTo(size.height - kPhoneInsets.bottom));
  });

  testWidgets('wide layout keeps content clear of the system bars',
      (WidgetTester tester) async {
    const Size size = Size(1440, 900);
    await pumpShell(tester, size);

    // Desktop top bar: content padded down, background extends (the bar's
    // own top edge is still at y=0).
    expect(tester.getTopLeft(find.byKey(const Key('top-bar-title'))).dy,
        greaterThanOrEqualTo(kPhoneInsets.top));

    // The chat composer clears the nav area.
    expect(tester.getBottomLeft(find.byType(Composer)).dy,
        lessThanOrEqualTo(size.height - kPhoneInsets.bottom));

    // The right panel pads its content off the bottom inset: the panel
    // root is a bottom-only SafeArea around the notes column.
    expect(
        tester
            .getBottomLeft(find.descendant(
              of: find.byType(RightPanel),
              matching: find.byType(ListView),
            ))
            .dy,
        lessThanOrEqualTo(size.height - kPhoneInsets.bottom));
  });
}
