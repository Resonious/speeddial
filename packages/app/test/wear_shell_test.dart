import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/scope.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/wear/wear_shell.dart';

Future<(AppData, FakeDaemonClient)> pumpWear(
  WidgetTester tester, {
  bool withDaemon = true,
  Size size = const Size(220, 220),
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final FakeDaemonClient fake = FakeDaemonClient(
    eventDelay: const Duration(milliseconds: 1),
  );
  final AppData data = AppData(clientFor: (_) => fake)
    ..registerClient('fake', fake);
  if (withDaemon) {
    await data.connections.addEndpoint(
      id: 'fake',
      name: 'Watch daemon',
      url: 'fake://local',
      token: '',
    );
    data.connections.setStatus('fake', ConnectionStatus.connected);
  }
  addTearDown(data.dispose);
  addTearDown(fake.dispose);

  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    AppScope(
      data: data,
      child: MaterialApp(
        theme: buildSpeedDialTheme(),
        home: const WearSpeedDialShell(),
      ),
    ),
  );
  await tester.pump();
  return (data, fake);
}

Future<void> openFirstSession(WidgetTester tester) async {
  await tester.tap(find.text('Watch daemon'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Demo Project'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Build the feature'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('fits a round watch flow and sends to an existing session', (
    WidgetTester tester,
  ) async {
    final (AppData data, FakeDaemonClient _) = await pumpWear(tester);

    expect(find.text('Watch daemon'), findsOneWidget);
    await openFirstSession(tester);

    expect(data.selection.selectedSessionId, 'sess-1');
    expect(find.byKey(const Key('wear-message-field')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('wear-message-field')),
      'Reply from my watch',
    );
    await tester.tap(find.byKey(const Key('wear-send')));
    await tester.pump();

    expect(find.text('Reply from my watch'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('creates a session from the compact provider list', (
    WidgetTester tester,
  ) async {
    final (AppData data, FakeDaemonClient _) = await pumpWear(
      tester,
      size: const Size(192, 192),
    );

    await tester.tap(find.text('Watch daemon'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Demo Project'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wear-new-session')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wear-provider-omp')));
    await tester.pumpAndSettle();

    expect(data.selection.selectedSessionId, isNotNull);
    expect(find.text('New session'), findsOneWidget);
    expect(find.byKey(const Key('wear-message-field')), findsOneWidget);
  });

  testWidgets('shows live read-only git state on session rows', (
    WidgetTester tester,
  ) async {
    final (AppData data, FakeDaemonClient fake) = await pumpWear(
      tester,
      size: const Size(192, 192),
    );

    await tester.tap(find.text('Watch daemon'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Demo Project'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('wear-git-sess-1-dirty')), findsOneWidget);
    expect(find.byKey(const Key('wear-git-sess-1-ahead')), findsOneWidget);
    expect(find.text('↑2'), findsOneWidget);

    fake.sessionGitSummaries['sess-1'] = const SessionGitSummary(
      sessionId: 'sess-1',
      dirty: false,
      aheadOfBase: 0,
      behindBase: 3,
      mergedIntoBase: false,
    );
    await data.git.refreshSessionSummaries('fake', 'proj-demo');
    await tester.pump();

    expect(find.byKey(const Key('wear-git-sess-1-dirty')), findsNothing);
    expect(find.byKey(const Key('wear-git-sess-1-ahead')), findsNothing);
    expect(find.byKey(const Key('wear-git-sess-1-behind')), findsOneWidget);
    expect(find.text('↓3'), findsOneWidget);
  });

  testWidgets('asks for phone configuration when no daemon is synchronized', (
    WidgetTester tester,
  ) async {
    final (AppData data, FakeDaemonClient _) = await pumpWear(
      tester,
      withDaemon: false,
    );

    expect(
      find.text('Add a daemon in SpeedDial on your paired phone'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('wear-daemon-url')), findsNothing);
    expect(data.connections.endpoints, isEmpty);
  });
}
