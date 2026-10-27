import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/chat/composer.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

const UsageInfo _usage = UsageInfo(
  inputTokens: 0,
  outputTokens: 123,
  totalTokens: 123,
  cacheReadTokens: 456,
  contextUsedTokens: 48000,
  contextLimitTokens: 256000,
  cost: '0.0123',
);

Future<void> _pumpComposer(
  WidgetTester tester, {
  UsageInfo? usage,
  double width = 1200,
  double textScale = 1,
  Brightness brightness = Brightness.light,
  String sessionId = 'session',
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    MaterialApp(
      theme: brightness == Brightness.dark
          ? buildSpeedDialTheme()
          : buildSpeedDialLightTheme(),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: Composer(
            key: ValueKey<String>(sessionId),
            status: SessionStatus.idle,
            usage: usage,
            onSend: (_, _) async {},
            onStop: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows context and estimated cost without turn token totals', (
    WidgetTester tester,
  ) async {
    addTearDown(tester.view.reset);
    await _pumpComposer(tester, usage: _usage);
    expect(find.text('Context 48k / 256k · 18.8%'), findsOneWidget);
    expect(find.text('≈ \$0.0123'), findsOneWidget);
    expect(
      find.byTooltip('Context: 48000 / 256000 tokens (18.8%)'),
      findsOneWidget,
    );
    expect(find.byTooltip('Estimated cost: \$0.0123'), findsOneWidget);
    expect(find.textContaining(' in / '), findsNothing);
    expect(find.textContaining('cached'), findsNothing);
    expect(find.textContaining('123 tokens'), findsNothing);
  });

  testWidgets('missing context never falls back to turn totals or zero', (
    WidgetTester tester,
  ) async {
    addTearDown(tester.view.reset);
    for (final UsageInfo? usage in <UsageInfo?>[
      null,
      const UsageInfo(inputTokens: 0, outputTokens: 0, totalTokens: 0),
      const UsageInfo(
        inputTokens: 48000,
        outputTokens: 123,
        totalTokens: 48123,
        contextLimitTokens: 256000,
      ),
      const UsageInfo(
        inputTokens: 0,
        outputTokens: 0,
        totalTokens: 0,
        contextUsedTokens: 0,
        contextLimitTokens: 0,
      ),
    ]) {
      await _pumpComposer(tester, usage: usage);
      expect(find.textContaining('Context'), findsNothing);
      expect(find.textContaining('≈'), findsNothing);
    }
    await _pumpComposer(
      tester,
      usage: const UsageInfo(
        inputTokens: 0,
        outputTokens: 0,
        totalTokens: 0,
        cost: '0.00',
      ),
    );
    expect(find.text('≈ \$0.00'), findsOneWidget);
    expect(find.textContaining('Context'), findsNothing);
    await _pumpComposer(
      tester,
      usage: const UsageInfo(
        inputTokens: 0,
        outputTokens: 0,
        totalTokens: 0,
        contextUsedTokens: 0,
        contextLimitTokens: 256000,
      ),
    );
    expect(find.text('Context 0 / 256k · 0.0%'), findsOneWidget);
  });

  for (final Brightness brightness in Brightness.values) {
    for (final double scale in <double>[1, 2]) {
      testWidgets(
        'input stays put with usage changes and resizing ($brightness, $scale)',
        (WidgetTester tester) async {
          addTearDown(tester.view.reset);
          double? inputBottom;
          for (final double width in <double>[1200, 390, 320, 1200]) {
            Rect? input;
            double? height;
            for (final UsageInfo? usage in <UsageInfo?>[
              null,
              _usage,
              const UsageInfo(
                inputTokens: 0,
                outputTokens: 0,
                totalTokens: 0,
                contextUsedTokens: 1234567,
                contextLimitTokens: 2000000,
                cost: '1234567.123456789',
              ),
              null,
            ]) {
              await _pumpComposer(
                tester,
                width: width,
                usage: usage,
                textScale: scale,
                brightness: brightness,
                sessionId: usage == null ? 'empty-session' : 'used-session',
              );
              final Rect current = tester.getRect(find.byType(TextField));
              input ??= current;
              inputBottom ??= current.bottom;
              height ??= tester.getSize(find.byType(Composer)).height;
              expect(current.top, input.top);
              expect(current.bottom, inputBottom);
              expect(tester.getSize(find.byType(Composer)).height, height);
              expect(tester.takeException(), isNull);
              expect(tester.hasRunningAnimations, isFalse);
            }
          }
        },
      );
    }
  }
}
