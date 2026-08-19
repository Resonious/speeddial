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
    MaterialApp(
      theme: buildSpeedDialTheme(),
      home: AppScope(
        data: app,
        child: const SpeedDialShell(),
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
    expect(tester.getBottomLeft(find.text('Add daemon')).dy,
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

    // Left rail's bottom action and the chat composer clear the nav area.
    expect(tester.getBottomLeft(find.text('Add daemon')).dy,
        lessThanOrEqualTo(size.height - kPhoneInsets.bottom));
    expect(tester.getBottomLeft(find.byType(Composer)).dy,
        lessThanOrEqualTo(size.height - kPhoneInsets.bottom));

    // The right panel pads its tab content off the bottom inset: the panel
    // root is a bottom-only SafeArea, whose child is the tab controller.
    expect(
        tester
            .getBottomLeft(find.descendant(
              of: find.byType(RightPanel),
              matching: find.byType(DefaultTabController),
            ))
            .dy,
        lessThanOrEqualTo(size.height - kPhoneInsets.bottom));
  });
}
