import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/companion/companion_endpoint_sync.dart';
import 'package:speeddial_app/src/scope.dart' show AppData, ConnectionStatus;
import 'package:speeddial_app/src/state/settings_store.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/wear/wear_app.dart';
import 'package:speeddial_app/src/ui/wear/wear_scaffold.dart';

const String rotaryChannelName = 'sh.speeddial/rotary';
const StandardMethodCodec rotaryCodec = StandardMethodCodec();

Future<Object?> sendRotaryScroll(double pixels) async {
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final ByteData message = rotaryCodec.encodeMethodCall(
    MethodCall('scroll', pixels),
  );
  final Completer<ByteData?> reply = Completer<ByteData?>();
  await messenger.handlePlatformMessage(
    rotaryChannelName,
    message,
    reply.complete,
  );
  return rotaryCodec.decodeEnvelope((await reply.future)!);
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
  WearLaunchTarget? initialLaunchTarget,
  Stream<WearLaunchTarget>? launchTargets,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final FakeDaemonClient fake = FakeDaemonClient(
    eventDelay: const Duration(milliseconds: 1),
  );
  final AppData data = AppData(
    clientFor: (_) => fake,
    chatHistoryPageSize: kWearHistoryPageSize,
    chatRetainedSessionLimit: kWearRetainedSessionLimit,
  )..registerClient('fake', fake);
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

  await tester.pumpWidget(
    WearSpeedDialApp(
      data: data,
      initialLaunchTarget: initialLaunchTarget,
      launchTargets: launchTargets,
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

  testWidgets('tile session target opens its chat without picker screens', (
    WidgetTester tester,
  ) async {
    final (AppData data, FakeDaemonClient _) = await pumpWear(
      tester,
      initialLaunchTarget: const WearLaunchTarget.session(
        daemonId: 'fake',
        projectId: 'proj-demo',
        sessionId: 'sess-1',
      ),
    );
    await tester.pumpAndSettle();

    expect(data.selection.selectedDaemonId, 'fake');
    expect(data.selection.selectedProjectId, 'proj-demo');
    expect(data.selection.selectedSessionId, 'sess-1');
    expect(find.byKey(const Key('wear-message-field')), findsOneWidget);
    expect(find.byKey(const Key('wear-daemon-list')), findsNothing);
    expect(find.byKey(const Key('wear-project-list')), findsNothing);
    expect(find.byKey(const Key('wear-session-list')), findsNothing);
  });

  testWidgets('complication target lists sessions needing attention globally', (
    WidgetTester tester,
  ) async {
    final (AppData data, FakeDaemonClient fake) = await pumpWear(
      tester,
      initialLaunchTarget: const WearLaunchTarget.attention(),
    );
    await tester.pumpAndSettle();
    expect(find.text('Needs attention'), findsOneWidget);
    expect(find.text('Everything is quiet'), findsOneWidget);

    await fake.sendMessage('sess-2', 'finish in the background');
    await tester.pump(const Duration(milliseconds: 100));
    await data.sessions.refresh('fake');
    await tester.pump();

    expect(find.byKey(const Key('wear-attention-list')), findsOneWidget);
    expect(find.text('Plan the refactor'), findsOneWidget);
    expect(find.text('Watch daemon · Done'), findsOneWidget);

    await tester.tap(find.text('Plan the refactor'));
    await tester.pumpAndSettle();
    expect(data.selection.selectedSessionId, 'sess-2');
    expect(find.byKey(const Key('wear-message-field')), findsOneWidget);
  });

  testWidgets('running app responds to a new complication tap', (
    WidgetTester tester,
  ) async {
    final StreamController<WearLaunchTarget> targets =
        StreamController<WearLaunchTarget>();
    addTearDown(targets.close);
    await pumpWear(tester, launchTargets: targets.stream);
    expect(find.byKey(const Key('wear-daemon-list')), findsOneWidget);

    targets.add(const WearLaunchTarget.attention());
    await tester.pumpAndSettle();

    expect(find.text('Needs attention'), findsOneWidget);
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

    expect(await sendRotaryScroll(60), 60);
    await tester.pump();

    expect(scrollable.position.pixels, 60);

    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    expect(await sendRotaryScroll(60), 0);
  });

  testWidgets('keeps scrolling with crown momentum after input stops', (
    WidgetTester tester,
  ) async {
    final (AppData data, FakeDaemonClient _) = await pumpWear(tester);
    for (int index = 1; index <= 12; index++) {
      await data.connections.addEndpoint(
        id: 'momentum-$index',
        name: 'Momentum daemon $index',
        url: 'fake://momentum-$index',
        token: '',
      );
    }
    await tester.pump();

    final Finder scrollableFinder = find.descendant(
      of: find.byKey(const Key('wear-daemon-list')),
      matching: find.byType(Scrollable),
    );
    final ScrollableState scrollable = tester.state(scrollableFinder);

    expect(await sendRotaryScroll(20), 20);
    await tester.pump(const Duration(milliseconds: 20));
    expect(await sendRotaryScroll(20), 20);
    await tester.pump(const Duration(milliseconds: 20));
    expect(await sendRotaryScroll(20), 20);
    final double positionAtRelease = scrollable.position.pixels;

    await tester.pump(const Duration(milliseconds: 110));
    await tester.pump(const Duration(milliseconds: 50));

    expect(scrollable.position.pixels, greaterThan(positionAtRelease));
  });

  testWidgets('keeps crown direction natural in reversed chat history', (
    WidgetTester tester,
  ) async {
    final (AppData _, FakeDaemonClient fake) = await pumpWear(tester);
    fake.seedHistory(
      'sess-1',
      List<SessionEvent>.generate(
        24,
        (int index) => AgentMessageChunkEvent(
          text: 'A sufficiently long history message number $index',
        ),
      ),
    );
    await openFirstSession(tester);

    final Finder scrollableFinder = find.descendant(
      of: find.byKey(const Key('wear-chat-timeline')),
      matching: find.byType(Scrollable),
    );
    final ScrollableState scrollable = tester.state(scrollableFinder);
    expect(scrollable.position.axisDirection, AxisDirection.up);
    expect(scrollable.position.maxScrollExtent, greaterThan(120));
    scrollable.position.jumpTo(100);

    expect(await sendRotaryScroll(40), 40);
    await tester.pump();

    expect(scrollable.position.pixels, 60);
  });

  testWidgets('loads a watch-sized initial history page', (
    WidgetTester tester,
  ) async {
    final (AppData data, FakeDaemonClient fake) = await pumpWear(tester);
    fake.seedHistory('sess-1', <SessionEvent>[
      for (var i = 1; i <= 140; i++) UserMessageEvent(text: 'message $i'),
    ]);

    await openFirstSession(tester);

    expect(data.chat.eventsFor('sess-1'), hasLength(kWearHistoryPageSize));
    expect(data.chat.hasOlderHistory('sess-1'), isTrue);
    expect(find.byKey(const Key('wear-chat-timeline')), findsOneWidget);
    expect(find.text('message 140'), findsOneWidget);
  });

  testWidgets('merges agent chunks across watch history page boundaries', (
    WidgetTester tester,
  ) async {
    final (AppData data, FakeDaemonClient fake) = await pumpWear(tester);
    final List<String> chunks = List<String>.generate(
      kWearHistoryPageSize + 2,
      (int index) => switch (index) {
        0 => 'Cutover: ',
        1 => 'deployment ',
        _ => '${index % 10}',
      },
    );
    fake.seedHistory('sess-1', <SessionEvent>[
      for (final String chunk in chunks) AgentMessageChunkEvent(text: chunk),
    ]);

    await openFirstSession(tester);

    expect(data.chat.hasOlderHistory('sess-1'), isFalse);
    expect(data.chat.eventsFor('sess-1'), hasLength(3));
    expect(find.text(chunks.join()), findsOneWidget);
    expect(find.text('Cutover: '), findsNothing);
  });

  testWidgets('folds identified messages and tool snapshots on watch', (
    WidgetTester tester,
  ) async {
    final (AppData _, FakeDaemonClient fake) = await pumpWear(tester);
    fake.seedHistory('sess-1', const <SessionEvent>[
      AgentMessageChunkEvent(text: 'One ', messageId: 'message-1'),
      ToolCallEvent(
        toolCall: ToolCall(
          id: 'tool-1',
          title: 'Inspect',
          kind: 'read',
          status: ToolCallStatus.running,
          content: <ToolCallContent>[],
          locations: <String>[],
        ),
      ),
      AgentMessageChunkEvent(text: 'logical ', messageId: 'message-1'),
      ToolCallEvent(
        toolCall: ToolCall(
          id: 'tool-1',
          title: 'Inspect',
          kind: 'read',
          status: ToolCallStatus.completed,
          content: <ToolCallContent>[],
          locations: <String>[],
        ),
      ),
      AgentMessageChunkEvent(text: 'message.', messageId: 'message-1'),
    ]);

    await openFirstSession(tester);

    expect(find.text('One logical message.'), findsOneWidget);
    expect(find.text('One '), findsNothing);
    expect(find.text('Inspect · completed'), findsOneWidget);
    expect(find.text('Inspect · running'), findsNothing);
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
