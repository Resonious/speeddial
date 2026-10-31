import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/chat/history_notice.dart';

void main() {
  for (final dark in [false, true]) {
    testWidgets(
      'offline notice stays still and explains incomplete history ($dark)',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? buildSpeedDialTheme() : buildSpeedDialLightTheme(),
            home: Scaffold(
              body: HistoryNotice(
                offline: true,
                hasContent: true,
                updating: true,
                savedOnly: true,
                savedComplete: false,
                failed: false,
                onRetry: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Offline · Viewing saved messages'), findsOneWidget);
        expect(
          find.textContaining('History may be incomplete'),
          findsOneWidget,
        );
        expect(find.text('Updating conversation…'), findsNothing);
        expect(tester.hasRunningAnimations, isFalse);
      },
    );
  }
  testWidgets(
    'partial refresh is labeled, failure offers retry, success clears',
    (tester) async {
      int retries = 0;
      Widget app({bool updating = false, bool failed = false}) => MaterialApp(
        theme: buildSpeedDialTheme(),
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: HistoryNotice(
              offline: false,
              hasContent: true,
              updating: updating,
              savedOnly: true,
              savedComplete: false,
              failed: failed,
              onRetry: () => retries++,
            ),
          ),
        ),
      );
      await tester.pumpWidget(app(updating: true));
      await tester.pump();
      expect(find.text('Updating conversation…'), findsOneWidget);
      expect(tester.hasRunningAnimations, isFalse);
      await tester.pumpWidget(app(failed: true));
      await tester.tap(find.text('Retry'));
      expect(retries, 1);
      expect(find.text('Could not update conversation'), findsOneWidget);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.text('Could not update conversation'), findsNothing);
      expect(find.text('Updating conversation…'), findsNothing);
    },
  );
}
