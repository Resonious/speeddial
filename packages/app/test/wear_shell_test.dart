import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/scope.dart' show AppData, ConnectionStatus;
import 'package:speeddial_app/src/state/settings_store.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/wear/wear_app.dart';
import 'package:speeddial_app/src/ui/wear/wear_scaffold.dart';

const String rotaryChannelName = 'sh.speeddial/rotary';
const StandardMethodCodec rotaryCodec = StandardMethodCodec();

Future<void> sendRotaryScroll(double pixels) {
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final ByteData message = rotaryCodec.encodeMethodCall(
    MethodCall('scroll', pixels),
  );
  return messenger.handlePlatformMessage(rotaryChannelName, message, null);
}

void expectInsideRoundScreen(WidgetTester tester, Finder finder, Size size) {
  final Rect rect = tester.getRect(finder);
  final Offset center = Offset(size.width / 2, size.height / 2);
  final double radius = size.shortestSide / 2;
  for (final Offset corner in <Offset>[
    rect.topLeft,
    rect.topRight,
    rect.bottomLeft,
    rect.bottomRight,
  ]) {
    expect(
      (corner - center).distance,
      lessThanOrEqualTo(radius),
      reason: '$finder at $rect is clipped by the $size round screen',
    );
  }
}

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
  await data.settings.init();
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

  await tester.pumpWidget(WearSpeedDialApp(data: data));
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
  testWidgets('keeps header actions inside a 240px round screen', (
    WidgetTester tester,
  ) async {
    const Size size = Size.square(240);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSpeedDialTheme(),
        home: WearScaffold(
          title: 'framework',
          showBack: true,
          action: IconButton(
            key: const Key('round-refresh'),
            onPressed: () {},
            icon: const Icon(Icons.refresh, size: 19),
          ),
          child: WearEmptyState(
            message: 'Could not load projects',
            details: 'Phone proxy channel closed',
            icon: Icons.cloud_off,
            action: FilledButton(onPressed: () {}, child: const Text('Retry')),
          ),
        ),
      ),
    );

    final Finder backIcon = find.descendant(
      of: find.byKey(const Key('wear-back')),
      matching: find.byType(Icon),
    );
    final Finder refreshIcon = find.descendant(
      of: find.byKey(const Key('round-refresh')),
      matching: find.byType(Icon),
    );
    expectInsideRoundScreen(tester, backIcon, size);
    expectInsideRoundScreen(tester, refreshIcon, size);
    expectInsideRoundScreen(
      tester,
      find.widgetWithText(FilledButton, 'Retry'),
      size,
    );
    expect(find.text('Phone proxy channel closed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('shows the useful message from a native proxy failure', () {
    expect(
      wearErrorText(
        PlatformException(
          code: 'phone_proxy_failed',
          message: 'TLS handshake failed',
        ),
      ),
      'TLS handshake failed',
    );
    expect(
      wearErrorText(const DaemonConnectionError('phone proxy channel closed')),
      'phone proxy channel closed',
    );
  });

  testWidgets('fits a round watch flow and sends to an existing session', (
    WidgetTester tester,
  ) async {
    final (AppData data, FakeDaemonClient _) = await pumpWear(tester);

    expect(find.text('Watch daemon'), findsOneWidget);
    await openFirstSession(tester);

    expect(data.selection.selectedSessionId, 'sess-1');
    expect(find.byKey(const Key('wear-message-field')), findsOneWidget);
    expectInsideRoundScreen(
      tester,
      find.byKey(const Key('wear-send')),
      const Size(220, 220),
    );

    await tester.enterText(
      find.byKey(const Key('wear-message-field')),
      'Reply from my watch',
    );
    await tester.tap(find.byKey(const Key('wear-send')));
    await tester.pump();

    expect(find.text('Reply from my watch'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('scrolls the current list from native rotary input', (
    WidgetTester tester,
  ) async {
    final (AppData data, FakeDaemonClient _) = await pumpWear(tester);
    for (int index = 1; index <= 7; index++) {
      await data.connections.addEndpoint(
        id: 'fake-$index',
        name: 'Watch daemon $index',
        url: 'fake://$index',
        token: '',
      );
    }
    await tester.pump();

    final Finder scrollableFinder = find.descendant(
      of: find.byKey(const Key('wear-daemon-list')),
      matching: find.byType(Scrollable),
    );
    final ScrollableState scrollable = tester.state(scrollableFinder);
    expect(scrollable.position.pixels, 0);
    expect(scrollable.position.maxScrollExtent, greaterThan(0));

    await sendRotaryScroll(60);
    await tester.pump();

    expect(scrollable.position.pixels, 60);
  });

  testWidgets('theme button applies and persists dark mode', (
    WidgetTester tester,
  ) async {
    final (AppData data, FakeDaemonClient _) = await pumpWear(tester);
    expect(data.settings.themeMode, ThemeMode.system);

    await tester.tap(find.byKey(const Key('wear-theme-toggle')));
    await tester.pump();

    expect(data.settings.themeMode, ThemeMode.dark);
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(SettingsStore.storageKey), ThemeMode.dark.name);
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
