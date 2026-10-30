import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:speeddial_app/main.dart';
import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/scope.dart';
import 'package:speeddial_app/src/ui/left/left_rail.dart';
import 'package:speeddial_app/src/ui/native_title_bar.dart';
import 'package:speeddial_app/src/ui/right/right_panel.dart';

void main() {
  const MethodChannel channel = NativeTitleBar.defaultChannel;

  /// Stands in for linux/runner/native_title_bar.cc: answers `attach` with
  /// [attached] and records every `update`.
  List<Map<Object?, Object?>> mockRunner(
    WidgetTester tester, {
    required bool attached,
  }) {
    final List<Map<Object?, Object?>> updates = <Map<Object?, Object?>>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      MethodCall call,
    ) async {
      switch (call.method) {
        case 'attach':
          return attached;
        case 'update':
          updates.add(call.arguments as Map<Object?, Object?>);
          return null;
      }
      throw MissingPluginException();
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    return updates;
  }

  Future<void> press(WidgetTester tester, String method) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(MethodCall(method)),
      (ByteData? _) {},
    );
    await tester.pump();
  }

  /// Platform-channel replies arrive outside the fake-async zone.
  Future<NativeTitleBar?> attach(WidgetTester tester) async =>
      tester.runAsync<NativeTitleBar?>(NativeTitleBar.attach);

  Future<AppData> pumpApp(
    WidgetTester tester,
    NativeTitleBar? bar, {
    Size size = const Size(1440, 900),
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final AppData data = AppData();
    await data.connections.init();
    await data.settings.init();
    addTearDown(data.dispose);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(SpeedDialApp(data: data, nativeTitleBar: bar));
    await tester.pump();
    return data;
  }

  testWidgets('no runner handler: attach yields null, Flutter bar stays', (
    WidgetTester tester,
  ) async {
    final NativeTitleBar? bar = await attach(tester);
    expect(bar, isNull);
    await pumpApp(tester, bar);
    expect(find.byTooltip('Toggle left rail'), findsOneWidget);
  });

  testWidgets('runner without a header bar declines to attach', (
    WidgetTester tester,
  ) async {
    mockRunner(tester, attached: false);
    expect(await attach(tester), isNull);
  });

  testWidgets('wide: native bar replaces the Flutter top bar and drives it', (
    WidgetTester tester,
  ) async {
    final List<Map<Object?, Object?>> updates = mockRunner(
      tester,
      attached: true,
    );
    final NativeTitleBar? bar = await attach(tester);
    expect(bar, isNotNull);
    final AppData data = await pumpApp(tester, bar);

    expect(find.byTooltip('Toggle left rail'), findsNothing);
    expect(find.byKey(const Key('top-bar-title')), findsNothing);
    expect(updates.last['title'], 'SpeedDial');
    expect(updates.last['status'], 'Not connected');
    expect(updates.last['leftOpen'], isTrue);
    expect(updates.last['rightOpen'], isTrue);
    expect(updates.last['themeMode'], 'system');

    await press(tester, 'toggleLeft');
    expect(find.byType(LeftRail), findsNothing);
    expect(updates.last['leftOpen'], isFalse);

    await press(tester, 'toggleRight');
    expect(find.byType(RightPanel), findsNothing);
    expect(updates.last['rightOpen'], isFalse);

    await press(tester, 'cycleTheme');
    await tester.pump();
    expect(data.settings.themeMode, ThemeMode.light);
    expect(updates.last['themeMode'], 'light');
    expect(updates.last['dark'], isFalse);

    // Unchanged state is not re-sent.
    final int sent = updates.length;
    await tester.pump();
    expect(updates.length, sent);
  });

  testWidgets('narrow: native toggles open the drawer and the sheet', (
    WidgetTester tester,
  ) async {
    final List<Map<Object?, Object?>> updates = mockRunner(
      tester,
      attached: true,
    );
    final NativeTitleBar? bar = await attach(tester);
    await pumpApp(tester, bar, size: const Size(600, 900));

    expect(find.byType(AppBar), findsNothing);
    await tester.pump();
    expect(updates.last['leftOpen'], isFalse);
    expect(updates.last['rightOpen'], isFalse);

    await press(tester, 'toggleLeft');
    await tester.pumpAndSettle();
    expect(find.byType(LeftRail), findsOneWidget);

    await press(tester, 'toggleLeft');
    await tester.pumpAndSettle();
    expect(find.byType(LeftRail), findsNothing);

    await press(tester, 'toggleRight');
    await tester.pumpAndSettle();
    expect(find.byType(RightPanel), findsOneWidget);
  });

  testWidgets('a rename types into the header bar; the window title settles', (
    WidgetTester tester,
  ) async {
    final List<Map<Object?, Object?>> updates = mockRunner(
      tester,
      attached: true,
    );
    final NativeTitleBar? bar = await attach(tester);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final AppData data = AppData()
      ..registerClient(
        'fake',
        FakeDaemonClient(eventDelay: const Duration(milliseconds: 1)),
      );
    addTearDown(data.dispose);
    await data.connections.addEndpoint(
      id: 'fake',
      name: 'Fake daemon',
      url: 'fake://local',
      token: '',
    );
    await data.sessions.refresh('fake');
    data.selection
      ..selectedDaemonId = 'fake'
      ..selectedSessionId = 'sess-1';
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(SpeedDialApp(data: data, nativeTitleBar: bar));
    await tester.pump();

    // Selecting a session shows its name at once.
    expect(updates.last['title'], 'Build the feature');

    final int before = updates.length;
    await data.sessions.rename('fake', 'sess-1', 'Build the docs');
    for (int frame = 0; frame < 30; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final List<Map<Object?, Object?>> typed = updates.sublist(before);
    final List<Object?> titles = <Object?>[
      for (final Map<Object?, Object?> update in typed) update['title'],
    ];
    // Backspaced to the shared prefix, then typed the rest in.
    expect(titles, contains('Build the '));
    expect(titles, contains('Build the d'));
    expect(titles.last, 'Build the docs');
    for (final Map<Object?, Object?> update in typed) {
      expect(update['windowTitle'], 'Build the docs');
    }

    // Switching sessions swaps the name without typing.
    data.selection.selectedSessionId = 'sess-2';
    await tester.pump();
    final Object? other = data.sessions.byId('sess-2')?.title;
    expect(other, isNotNull);
    expect(updates.last['title'], other);
    await tester.pump(const Duration(milliseconds: 5));
  });
}
