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

  test('local file href parsing supports agent link formats', () {
    expect(localFilePathFromHref('lib/main.dart'), 'lib/main.dart');
    expect(
      localFilePathFromHref('/work/project/lib/main.dart:42:7'),
      '/work/project/lib/main.dart',
    );
    expect(
      localFilePathFromHref('file:///work/project/my%20report.pdf#L4'),
      '/work/project/my report.pdf',
    );
    expect(
      localFilePathFromHref(r'C:\work\project\main.dart:12'),
      r'C:\work\project\main.dart',
    );
    expect(localFilePathFromHref('https://example.com/file.txt'), isNull);
    expect(localFilePathFromHref('mailto:person@example.com'), isNull);
    expect(localFilePathFromHref('#section'), isNull);
  });

  testWidgets('agent markdown local links request a session file', (
    WidgetTester tester,
  ) async {
    String? openedPath;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSpeedDialTheme(),
        home: Scaffold(
          body: SelectionArea(
            child: AgentMessageView(
              text: '[Open result](/work/project/result.pdf:12)',
              openLocalFile: (String path) async {
                openedPath = path;
              },
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open result', findRichText: true));
    await tester.pump();

    expect(openedPath, '/work/project/result.pdf');
  });
}
