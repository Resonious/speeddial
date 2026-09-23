import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/chat/message_view.dart';

void main() {
  testWidgets('drag selection crosses inline code and list items', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const String message =
        r'Start of message with `ops-${environment_prefix}@${base_domain}` '
        'and **bold text** plus [link text](https://example.com) that wraps '
        'across multiple lines.\n\n'
        '```dart\nvoid main() {}\n```\n\n'
        'What I verified:\n\n'
        '- First item in the list spans multiple lines of text.\n'
        '- Second item in the list spans multiple lines of text.\n\n'
        'End of message after the list.';
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
          body: SelectionArea(child: AgentMessageView(text: message)),
        ),
      ),
    );
    await tester.pump();

    final Offset start =
        tester.getTopLeft(
          find.textContaining('Start of message', findRichText: true).first,
        ) +
        const Offset(3, 12);
    final Offset end =
        tester.getTopLeft(
          find.textContaining('End of message', findRichText: true).first,
        ) +
        const Offset(170, 12);
    final TestGesture gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 600));
    for (int step = 1; step <= 12; step++) {
      await gesture.moveTo(Offset.lerp(start, end, step / 12)!);
      await tester.pump(const Duration(milliseconds: 20));
    }
    await gesture.up();
    await tester.pump();

    final BuildContext context = tester.element(
      find.textContaining('Start of message', findRichText: true).first,
    );
    Actions.invoke(context, CopySelectionTextIntent.copy);
    final Iterable<MethodCall> writes = clipboardCalls.where(
      (MethodCall call) => call.method == 'Clipboard.setData',
    );
    expect(writes, hasLength(1));
    final String copied =
        (writes.single.arguments! as Map<Object?, Object?>)['text']! as String;
    expect(copied, contains(r'ops-${environment_prefix}@${base_domain}'));
    expect(copied, contains('bold text'));
    expect(copied, contains('link text'));
    expect(copied, contains('void main() {}'));
    expect(copied, contains('First item in the list'));
    expect(copied, contains('Second item in the list'));
    expect(copied, contains('End of message'));
  });

  testWidgets('selection handle over a list marker reaches item text', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const String message =
        'Start of message with `inline code` and more text that wraps across '
        'multiple lines.\n\n'
        'What I verified:\n\n'
        '- First item in the list spans multiple lines of text.\n'
        '- Second item in the list spans multiple lines of text.\n\n'
        'End of message after the list.';
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
          body: SelectionArea(child: AgentMessageView(text: message)),
        ),
      ),
    );
    await tester.pump();
    final Offset start =
        tester.getTopLeft(
          find.textContaining('Start of message', findRichText: true).first,
        ) +
        const Offset(5, 12);
    await tester.longPressAt(start);
    await tester.pump();
    // A handle dragged straight down through the marker gutter used to stop
    // on a bullet and omit the first item's text from the selection.
    final Offset end = tester.getCenter(find.text('•').last);
    final Finder handles = find.byWidgetPredicate(
      (Widget widget) =>
          widget.runtimeType.toString() == '_SelectionHandleOverlay',
    );
    expect(handles, findsNWidgets(2));
    final Finder endHandle = find.descendant(
      of: handles.last,
      matching: find.byType(RawGestureDetector),
    );
    await tester.drag(endHandle.first, end - tester.getCenter(endHandle.first));
    await tester.pump();
    final BuildContext context = tester.element(
      find.textContaining('Start of message', findRichText: true).first,
    );
    Actions.invoke(context, CopySelectionTextIntent.copy);
    final Iterable<MethodCall> writes = clipboardCalls.where(
      (MethodCall call) => call.method == 'Clipboard.setData',
    );
    expect(writes, hasLength(1));
    final String copied =
        (writes.single.arguments! as Map<Object?, Object?>)['text']! as String;
    expect(copied, contains('inline code'));
    expect(copied, contains('•'));
    expect(copied, contains('First item in the list'));
  });

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
