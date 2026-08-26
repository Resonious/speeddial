import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  testWidgets('agent markdown link context menu copies its URL', (
    WidgetTester tester,
  ) async {
    final List<MethodCall> clipboardCalls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        clipboardCalls.add(call);
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSpeedDialTheme(),
        home: const Scaffold(
          body: SelectionArea(
            child: AgentMessageView(
              text: '[Copy this link](https://example.com/a?b=c#section)',
            ),
          ),
        ),
      ),
    );

    await tester.tap(
      find.text('Copy this link'),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('Copy URL'), findsOneWidget);

    await tester.tap(find.text('Copy URL'));
    await tester.pumpAndSettle();

    final MethodCall write = clipboardCalls.singleWhere(
      (MethodCall call) => call.method == 'Clipboard.setData',
    );
    expect(
      (write.arguments! as Map<Object?, Object?>)['text'],
      'https://example.com/a?b=c#section',
    );
    expect(find.text('URL copied'), findsOneWidget);
  });

  testWidgets('agent markdown reports an external launch failure', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSpeedDialTheme(),
        home: Scaffold(
          body: AgentMessageView(
            text: '[Broken link](https://example.invalid)',
            launchExternal: (Uri uri) async => false,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Broken link'));
    await tester.pumpAndSettle();

    expect(
      find.text('Could not open URL. Right-click it to copy the URL.'),
      findsOneWidget,
    );
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
