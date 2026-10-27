import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/toast.dart';

void main() {
  Future<BuildContext> pumpHost(WidgetTester tester) async {
    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSpeedDialLightTheme(),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) {
              captured = context;
              return const Align(
                alignment: Alignment.bottomCenter,
                child: TextField(key: Key('input')),
              );
            },
          ),
        ),
      ),
    );
    return captured;
  }

  final Finder toast = find.byKey(const Key('toast'));

  testWidgets('drops in at the top, clear of the input, and times out', (
    WidgetTester tester,
  ) async {
    final BuildContext context = await pumpHost(tester);
    showToast(context, 'Something broke', tone: ToastTone.error);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Something broke'), findsOneWidget);
    // Nothing animates while it just sits there.
    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
    expect(toast, findsOneWidget);
    final Rect box = tester.getRect(toast);
    final Size screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(box.bottom, lessThan(screen.height / 3));

    // The input underneath stays usable while the toast shows.
    await tester.tap(find.byKey(const Key('input')));
    await tester.enterText(find.byKey(const Key('input')), 'still typing');
    expect(find.text('still typing'), findsOneWidget);

    await tester.pump(const Duration(seconds: 8));
    await tester.pumpAndSettle();
    expect(toast, findsNothing);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('the close button dismisses it', (WidgetTester tester) async {
    final BuildContext context = await pumpHost(tester);
    showToast(context, 'Close me');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const Key('toast-close')));
    await tester.pumpAndSettle();
    expect(toast, findsNothing);
  });

  testWidgets('a repeat restarts the toast instead of stacking a copy', (
    WidgetTester tester,
  ) async {
    final BuildContext context = await pumpHost(tester);
    showToast(context, 'Again', duration: const Duration(seconds: 2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1500));
    showToast(context, 'Again', duration: const Duration(seconds: 2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1500));
    expect(find.text('Again'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(toast, findsNothing);
  });

  testWidgets('keeps at most three, newest on top', (
    WidgetTester tester,
  ) async {
    final BuildContext context = await pumpHost(tester);
    for (int i = 0; i < 5; i++) {
      showToast(context, 'Toast $i');
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 400));
    expect(toast, findsNWidgets(3));
    expect(
      tester.getRect(find.text('Toast 4')).top,
      lessThan(tester.getRect(find.text('Toast 3')).top),
    );
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('hovering holds the timer', (WidgetTester tester) async {
    final BuildContext context = await pumpHost(tester);
    showToast(context, 'Hold on', duration: const Duration(seconds: 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: tester.getCenter(toast));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(toast, findsOneWidget);
    await mouse.moveTo(Offset.zero);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(toast, findsNothing);
    await mouse.removePointer();
  });

  testWidgets('holds still under reduced motion', (WidgetTester tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final BuildContext context = await pumpHost(tester);
    showToast(context, 'Still', tone: ToastTone.success);
    await tester.pump();
    expect(find.text('Still'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(toast, findsNothing);
  });
}
