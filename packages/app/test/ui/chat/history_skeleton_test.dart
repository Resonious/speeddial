import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/chat/history_skeleton.dart';

void main() {
  Widget host({bool failed = false}) => MaterialApp(
    theme: buildSpeedDialTheme(),
    home: Scaffold(
      body: HistorySkeleton(failed: failed, caption: 'Loading history…'),
    ),
  );
  final Finder skeleton = find.byKey(const Key('history-skeleton'));
  double shown(WidgetTester tester) =>
      tester.widget<FadeTransition>(skeleton).opacity.value;

  testWidgets('a quick load never flashes it', (WidgetTester tester) async {
    await tester.pumpWidget(host());
    expect(shown(tester), 0);
    await tester.pump(
      HistorySkeleton.patience - const Duration(milliseconds: 40),
    );
    // A fade begun at once would be moving by the next frame.
    await tester.pump(const Duration(milliseconds: 16));
    expect(shown(tester), 0);
    // A slower one fades it in.
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump(const Duration(milliseconds: 300));
    expect(shown(tester), 1);
    expect(find.text('Loading history…'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a glint sweeps it while loading, and stops once failed', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.hasRunningAnimations, isTrue);

    await tester.pumpWidget(host(failed: true));
    await tester.pump(const Duration(milliseconds: 500));
    expect(shown(tester), 1);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('reduced motion shows it at once, still', (
    WidgetTester tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(host());
    expect(shown(tester), 1);
    expect(tester.hasRunningAnimations, isFalse);
  });
}
