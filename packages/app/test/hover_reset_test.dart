import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/ui/hover_reset.dart';

void main() {
  for (final PointerDeviceKind kind in <PointerDeviceKind>[
    PointerDeviceKind.mouse,
    PointerDeviceKind.stylus,
  ]) {
    testWidgets('$kind hover is forgotten on touch and restored by movement', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<bool> shifted = ValueNotifier<bool>(false);
      addTearDown(shifted.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (BuildContext context, Widget? child) =>
              HoverReset(child: child!),
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: shifted,
              builder: (BuildContext context, bool value, Widget? child) =>
                  Stack(
                    children: <Widget>[
                      Positioned(
                        left: value ? 200 : 0,
                        top: 0,
                        child: const Tooltip(
                          message: 'Thinking level',
                          waitDuration: Duration(milliseconds: 200),
                          child: SizedBox(width: 100, height: 100),
                        ),
                      ),
                    ],
                  ),
            ),
          ),
        ),
      );
      final TestGesture pointer = await tester.createGesture(kind: kind);
      await pointer.addPointer(location: const Offset(50, 50));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(find.text('Thinking level'), findsOneWidget);

      // No exit/removal event: the physical pointer has silently disappeared.
      await tester.tapAt(const Offset(400, 400));
      await tester.pumpAndSettle();
      expect(find.text('Thinking level'), findsNothing);
      shifted.value = true;
      await tester.pumpAndSettle();
      shifted.value = false;
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Thinking level'), findsNothing);

      // Hover resumes without requiring a new device-added event.
      await pointer.moveTo(const Offset(51, 50));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(find.text('Thinking level'), findsOneWidget);
      await pointer.removePointer();
      await tester.pumpAndSettle();

      // Touch also cancels hover before its delay has elapsed.
      await pointer.addPointer(location: const Offset(50, 50));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(const Offset(400, 400));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('Thinking level'), findsNothing);
      await pointer.removePointer();

      await pointer.addPointer(location: const Offset(50, 50));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(find.text('Thinking level'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      expect(find.text('Thinking level'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      shifted.value = true;
      await tester.pumpAndSettle();
      shifted.value = false;
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Thinking level'), findsNothing);
      await pointer.removePointer();

      // Touch help remains available and expires normally.
      await tester.longPressAt(const Offset(50, 50));
      await tester.pumpAndSettle();
      expect(find.text('Thinking level'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('Thinking level'), findsNothing);
    });
  }
}
