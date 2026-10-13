import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/left/idle_session_ember.dart';

void main() {
  for (final Brightness brightness in Brightness.values) {
    testWidgets('idle ember cools and stops in ${brightness.name}', (
      tester,
    ) async {
      final DateTime start = DateTime.utc(2026, 10, 14);
      DateTime now = start;
      final ThemeData theme = brightness == Brightness.dark
          ? buildSpeedDialTheme()
          : buildSpeedDialLightTheme();
      await tester.pumpWidget(
        MaterialApp(
          themeAnimationDuration: Duration.zero,
          theme: theme,
          home: IdleSessionEmber(lastActivityAt: start, now: () => now),
        ),
      );
      BoxDecoration decoration() =>
          tester
                  .widget<Container>(
                    find.descendant(
                      of: find.byType(IdleSessionEmber),
                      matching: find.byType(Container),
                    ),
                  )
                  .decoration!
              as BoxDecoration;
      final Color hot = decoration().color!;
      final double initialGlow = decoration().boxShadow!.single.color.a;
      expect(tester.hasRunningAnimations, isFalse);
      now = start.add(const Duration(minutes: 90));
      await tester.pump(const Duration(minutes: 1));
      expect(decoration().color, isNot(hot));
      expect(decoration().boxShadow!.single.color.a, lessThan(initialGlow));
      now = start.add(const Duration(hours: 3));
      await tester.pump(const Duration(minutes: 1));
      expect(decoration().color, theme.extension<SpeedDialColors>()!.idle);
      expect(decoration().boxShadow, isNull);
      expect(tester.hasRunningAnimations, isFalse);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('dormant is cold; reconnect and new activity refresh heat', (
    tester,
  ) async {
    final DateTime now = DateTime.utc(2026, 10, 14);
    Future<void> show({required DateTime at, bool dormant = false}) =>
        tester.pumpWidget(
          MaterialApp(
            themeAnimationDuration: Duration.zero,
            theme: buildSpeedDialTheme(),
            home: MediaQuery(
              data: const MediaQueryData(disableAnimations: true),
              child: IdleSessionEmber(
                lastActivityAt: at,
                dormant: dormant,
                now: () => now,
              ),
            ),
          ),
        );
    BoxDecoration decoration() =>
        tester
                .widget<Container>(
                  find.descendant(
                    of: find.byType(IdleSessionEmber),
                    matching: find.byType(Container),
                  ),
                )
                .decoration!
            as BoxDecoration;
    await show(at: now, dormant: true);
    expect(decoration().boxShadow, isNull);
    await show(at: now);
    expect(decoration().boxShadow, isNotNull);
    expect(tester.hasRunningAnimations, isFalse);
    await show(at: now.subtract(const Duration(hours: 4)));
    expect(decoration().boxShadow, isNull);
    await show(at: now.add(const Duration(minutes: 5)));
    expect(decoration().boxShadow, isNotNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
