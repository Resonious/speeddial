import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/session_title_dialog.dart';

void main() {
  for (final bool reduced in <bool>[false, true]) {
    testWidgets('title modal scrolls and dismisses, reduced motion: $reduced', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final String title = List<String>.filled(
        60,
        'A long session title',
      ).join(' ');
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSpeedDialTheme(),
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduced),
            child: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showSessionTitleDialog(context, title),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pump();
      if (reduced) {
        expect(tester.hasRunningAnimations, isFalse);
      } else {
        expect(tester.hasRunningAnimations, isTrue);
      }
      await tester.pumpAndSettle();
      expect(tester.hasRunningAnimations, isFalse);
      expect(find.widgetWithText(SelectableText, title), findsOneWidget);
      expect(tester.takeException(), isNull);
      final Finder scroll = find
          .descendant(
            of: find.byType(Dialog),
            matching: find.byType(Scrollable),
          )
          .first;
      final ScrollableState state = tester.state<ScrollableState>(scroll);
      expect(state.position.maxScrollExtent, greaterThan(0));
      await tester.drag(scroll, const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(state.position.pixels, greaterThan(0));
      await tester.tapAt(const Offset(2, 420));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
    });
  }
}
