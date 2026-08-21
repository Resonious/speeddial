import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/chat/message_view.dart';

void main() {
  testWidgets('agent markdown links open externally', (
    WidgetTester tester,
  ) async {
    Uri? opened;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSpeedDialTheme(),
        home: Scaffold(
          body: SelectionArea(
            child: AgentMessageView(
              text: '[Open the link](https://example.com/docs)',
              launchExternal: (Uri uri) async {
                opened = uri;
                return true;
              },
            ),
          ),
        ),
      ),
    );

    final Finder link = find.text('Open the link', findRichText: true);
    expect(link, findsOneWidget);

    await tester.tap(link);
    await tester.pump();

    expect(opened, Uri.parse('https://example.com/docs'));
  });
}
