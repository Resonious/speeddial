import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/api/demo_explainer.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/chat/explainer/explainer_view.dart';
import 'package:speeddial_app/src/ui/chat/timeline.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

Widget _host(Widget child, {ThemeData? theme}) => MaterialApp(
  theme: theme ?? buildSpeedDialTheme(),
  home: Scaffold(
    body: Center(child: SizedBox(width: 640, child: child)),
  ),
);

Finder _caption(String text) => find.text(text);

void main() {
  test('the demo explainer is valid and warning-free', () {
    final ExplainerDocument document = ExplainerDocument.parse(kDemoExplainer);
    expect(document.warnings, isEmpty);
    expect(document.steps, hasLength(5));
  });

  test('explainer events become timeline rows', () {
    final List<TimelineItem> items = deriveTimelineItems(<SessionEvent>[
      const ExplainerEvent(explainer: kDemoExplainer, seq: 1),
    ]);
    expect(items.single, isA<ExplainerItem>());
  });

  testWidgets('steps forward and back with buttons, dots, and keys', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(const ExplainerView(spec: kDemoExplainer)));
    final List<String> captions = kDemoExplainer.steps
        .map((ExplainerStepSpec s) => s.caption)
        .toList();
    expect(find.text('How a SpeedDial turn flows'), findsOneWidget);
    expect(_caption(captions[0]), findsOneWidget);
    expect(find.text('1 / 5'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('explainer-next')));
    await tester.pump(const Duration(milliseconds: 200)); // mid-transition
    await tester.pumpAndSettle();
    expect(_caption(captions[1]), findsOneWidget);
    expect(find.text('2 / 5'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('explainer-dot-3')));
    await tester.pumpAndSettle();
    expect(_caption(captions[3]), findsOneWidget);

    // Keyboard navigation once the diagram has focus.
    await tester.tap(find.byKey(const ValueKey<String>('explainer-canvas')));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('5 / 5'), findsOneWidget);
    final IconButton next = tester.widget<IconButton>(
      find.byKey(const ValueKey<String>('explainer-next')),
    );
    expect(next.onPressed, isNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pumpAndSettle();
    expect(_caption(captions[0]), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final double width in <double>[360, 640]) {
    for (final bool reduced in <bool>[false, true]) {
      testWidgets('stable caption height: width=$width reduced=$reduced', (
        tester,
      ) async {
        const String longCaption =
            'The operating system receives the alert while the app is in the background. Tapping it opens the saved session, and reading the conversation still requires connectivity to the daemon.';
        const ExplainerSpec spec = ExplainerSpec(
          title: 'Stable steps',
          svg: '<svg viewBox="0 0 600 120"><rect width="600" height="120"/></svg>',
          steps: <ExplainerStepSpec>[
            ExplainerStepSpec(caption: 'Short caption'),
            ExplainerStepSpec(caption: longCaption),
            ExplainerStepSpec(caption: ''),
          ],
        );
        await tester.pumpWidget(
          _host(
            MediaQuery(
              data: MediaQueryData(
                textScaler: TextScaler.linear(1.4),
                disableAnimations: reduced,
              ),
              child: Center(
                child: SizedBox(
                  width: width,
                  child: const ExplainerView(spec: spec),
                ),
              ),
            ),
            theme: reduced ? buildSpeedDialLightTheme() : buildSpeedDialTheme(),
          ),
        );
        final Finder card = find.byType(ExplainerView);
        final Finder next = find.byKey(
          const ValueKey<String>('explainer-next'),
        );
        final Rect original = tester.getRect(card);
        final Offset controls = tester.getTopLeft(next);
        expect(find.text(longCaption), findsNothing);
        for (final int step in <int>[1, 2, 0]) {
          await tester.tap(find.byKey(ValueKey<String>('explainer-dot-$step')));
          await tester.pump();
          expect(tester.getRect(card), original);
          expect(tester.getTopLeft(next), controls);
          await tester.pump(const Duration(milliseconds: 100));
          expect(tester.getRect(card), original);
          await tester.pumpAndSettle();
          expect(tester.getRect(card), original);
          expect(tester.getTopLeft(next), controls);
          expect(
            find.text(longCaption),
            step == 1 ? findsOneWidget : findsNothing,
          );
          expect(tester.takeException(), isNull);
        }
        expect(tester.hasRunningAnimations, isFalse);
      });
    }
  }

  testWidgets('toggles flip and tooltips show on tap', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const ExplainerView(spec: kDemoExplainer),
        theme: buildSpeedDialLightTheme(),
      ),
    );
    final Finder toggle = find.byKey(
      const ValueKey<String>('explainer-toggle-0'),
    );
    expect(tester.widget<FilterChip>(toggle).selected, isFalse);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<FilterChip>(toggle).selected, isTrue);

    // The diagram fills the column at about scale 1; the App box spans
    // x 20..170, y 70..140 in viewBox units.
    final Finder canvas = find.byKey(
      const ValueKey<String>('explainer-canvas'),
    );
    final Offset origin = tester.getTopLeft(canvas);
    await tester.tapAt(origin + const Offset(60, 110));
    await tester.pump();
    expect(find.text('Desktop, web, Android, or a watch'), findsOneWidget);
    await tester.tapAt(origin + const Offset(60, 110));
    await tester.pump();
    expect(find.text('Desktop, web, Android, or a watch'), findsNothing);
  });

  testWidgets('fullscreen opens at the current step and hands it back', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(const ExplainerView(spec: kDemoExplainer)));
    await tester.tap(find.byKey(const ValueKey<String>('explainer-next')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Expand'));
    await tester.pumpAndSettle();
    expect(find.text('2 / 5'), findsNWidgets(2));
    await tester.tap(find.byKey(const ValueKey<String>('explainer-next')).last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('3 / 5'), findsOneWidget);
  });

  testWidgets('an explainer that fails to parse shows a readable card', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const ExplainerView(
          spec: ExplainerSpec(title: 'Broken', svg: '<svg><blink/></svg>'),
        ),
      ),
    );
    expect(find.textContaining('Broken can’t be shown'), findsOneWidget);
  });
}
