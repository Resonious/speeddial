import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/chat/mermaid/mermaid_diagram.dart';
import 'package:speeddial_app/src/ui/chat/message_view.dart';

void main() {
  testWidgets('message colors settle after animated theme changes', (
    WidgetTester tester,
  ) async {
    final ThemeData light = buildSpeedDialLightTheme();
    final ThemeData dark = buildSpeedDialTheme();
    Future<void> show(ThemeMode mode) => tester.pumpWidget(
      MaterialApp(
        theme: light,
        darkTheme: dark,
        themeMode: mode,
        home: const Scaffold(
          body: AgentMessageView(
            text: 'Readable answer\n\n- List item\n\n```\nplain code\n```',
            streaming: true,
          ),
        ),
      ),
    );

    await show(ThemeMode.light);
    for (final ThemeMode mode in [ThemeMode.dark, ThemeMode.light]) {
      await show(mode);
      // Render intermediate colors after brightness has already switched.
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pumpAndSettle();
      final ThemeData theme = mode == ThemeMode.dark ? dark : light;
      final MarkdownStyleSheet styles = tester
          .widget<MarkdownBody>(find.byType(MarkdownBody))
          .styleSheet!;
      expect(styles.p?.color, theme.colorScheme.onSurface);
      expect(styles.listBullet?.color, theme.colorScheme.onSurface);
      final Color background =
          (styles.codeblockDecoration! as BoxDecoration).color!;
      expect(background, theme.speedDialColors.codeBackground);
      final double foregroundLuminance = styles.code!.color!.computeLuminance();
      final double backgroundLuminance = background.computeLuminance();
      final double contrast = foregroundLuminance > backgroundLuminance
          ? (foregroundLuminance + 0.05) / (backgroundLuminance + 0.05)
          : (backgroundLuminance + 0.05) / (foregroundLuminance + 0.05);
      expect(contrast, greaterThanOrEqualTo(4.5));
    }
  });

  testWidgets('code block selection has a visible highlight', (
    WidgetTester tester,
  ) async {
    SelectedContent? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSpeedDialTheme(),
        home: Scaffold(
          body: SelectionArea(
            onSelectionChanged: (SelectedContent? value) => selected = value,
            child: const RepaintBoundary(
              key: Key('code-selection'),
              child: AgentMessageView(text: '```\nalpha beta gamma\n```'),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    final Finder code = find.textContaining('alpha beta', findRichText: true);
    final Finder boundaryFinder = find.byKey(const Key('code-selection'));
    final RenderRepaintBoundary boundary = tester.renderObject(boundaryFinder);
    final Rect codeRect = tester
        .getRect(code.first)
        .shift(-tester.getTopLeft(boundaryFinder));
    Future<Uint8List> pixels() async {
      final ui.Image image = await boundary.toImage();
      final ByteData data = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      image.dispose();
      return data.buffer.asUint8List();
    }

    final Uint8List before = (await tester.runAsync(pixels))!;
    final Offset start = tester.getTopLeft(code.first) + const Offset(4, 10);
    final TestGesture gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(start + const Offset(90, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(selected?.plainText, contains('alpha'));

    final Uint8List after = (await tester.runAsync(pixels))!;
    final int width = boundary.size.width.toInt();
    int changedTextPixels = 0;
    for (int y = codeRect.top.ceil(); y < codeRect.bottom.floor(); y++) {
      for (int x = codeRect.left.ceil(); x < codeRect.right.floor(); x++) {
        final int red = (y * width + x) * 4;
        if (before[red + 2] <= 150) continue;
        // Largest per-channel shift, so the check holds for any accent hue.
        int delta = 0;
        for (int channel = 0; channel < 3; channel++) {
          final int d = (after[red + channel] - before[red + channel]).abs();
          if (d > delta) delta = d;
        }
        if (delta > 20) changedTextPixels++;
      }
    }
    // A selection painted only behind the glyphs leaves these pixels unchanged.
    expect(changedTextPixels, greaterThan(100));
  });

  testWidgets(
    'streaming batches Markdown updates and completion flushes immediately',
    (tester) async {
      Future<void> show(String text, {bool streaming = true}) =>
          tester.pumpWidget(
            MaterialApp(
              theme: buildSpeedDialTheme(),
              home: Scaffold(
                body: AgentMessageView(text: text, streaming: streaming),
              ),
            ),
          );
      String rendered() =>
          tester.widget<MarkdownBody>(find.byType(MarkdownBody)).data;
      await show('a');
      await show('ab');
      expect(rendered(), 'a');
      await tester.pump(const Duration(milliseconds: 50));
      await show('abc');
      expect(rendered(), 'a');
      await tester.pump(const Duration(milliseconds: 50));
      expect(rendered(), 'abc');
      await show('replacement');
      expect(rendered(), 'replacement');
      await show('abcd');
      await show('final **answer**', streaming: false);
      expect(rendered(), 'final **answer**');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'streaming pauses do not trigger highlighting or remount Markdown',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSpeedDialTheme(),
          home: const Scaffold(
            body: AgentMessageView(
              text: '```dart\nvoid main() {}\n```',
              streaming: true,
            ),
          ),
        ),
      );
      final Element body = tester.element(find.byType(MarkdownBody));
      await tester.pump(const Duration(seconds: 2));
      expect(
        identical(body, tester.element(find.byType(MarkdownBody))),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

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
          body: SelectionArea(
            child: RepaintBoundary(
              key: Key('cross-selection'),
              child: AgentMessageView(text: message),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    final Finder boundaryFinder = find.byKey(const Key('cross-selection'));
    final RenderRepaintBoundary boundary = tester.renderObject(boundaryFinder);
    Future<Uint8List> pixels() async {
      final ui.Image image = await boundary.toImage();
      final ByteData data = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      image.dispose();
      return data.buffer.asUint8List();
    }

    final Rect codeRect = tester
        .getRect(find.textContaining('void main()', findRichText: true).first)
        .shift(-tester.getTopLeft(boundaryFinder));
    final Uint8List before = (await tester.runAsync(pixels))!;

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

    final Uint8List after = (await tester.runAsync(pixels))!;
    final int width = boundary.size.width.toInt();
    int changedTextPixels = 0;
    for (int y = codeRect.top.ceil(); y < codeRect.bottom.floor(); y++) {
      for (int x = codeRect.left.ceil(); x < codeRect.right.floor(); x++) {
        final int red = (y * width + x) * 4;
        if (before[red + 2] <= 150) continue;
        // Largest per-channel shift, so the check holds for any accent hue.
        int delta = 0;
        for (int channel = 0; channel < 3; channel++) {
          final int d = (after[red + channel] - before[red + channel]).abs();
          if (d > delta) delta = d;
        }
        if (delta > 20) changedTextPixels++;
      }
    }
    expect(changedTextPixels, greaterThan(100));

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

  group('mermaid', () {
    const String diagram =
        'flowchart LR\n  A["MySQL<br/>tables"] --> B["ClickPipes"] --> C';

    Future<void> show(
      WidgetTester tester,
      String text, {
      bool streaming = false,
    }) => tester.pumpWidget(
      MaterialApp(
        theme: buildSpeedDialTheme(),
        home: Scaffold(
          body: AgentMessageView(text: text, streaming: streaming),
        ),
      ),
    );

    Finder painted() => find.byWidgetPredicate(
      (Widget w) => w is CustomPaint && w.painter is MermaidPainter,
    );

    testWidgets('renders a mermaid fence and toggles to its source', (
      WidgetTester tester,
    ) async {
      await show(tester, 'Plan:\n\n```mermaid\n$diagram\n```\n');
      expect(painted(), findsOneWidget);
      expect(
        find.textContaining('ClickPipes', findRichText: true),
        findsNothing,
      );

      await tester.tap(find.byTooltip('Show source'));
      await tester.pump();
      expect(painted(), findsNothing);
      expect(
        find.textContaining('ClickPipes', findRichText: true),
        findsOneWidget,
      );

      // A highlight batch remounts the markdown; the choice persists.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(painted(), findsNothing);

      await tester.tap(find.byTooltip('Show diagram'));
      await tester.pump();
      expect(painted(), findsOneWidget);
    });

    testWidgets('untagged flowchart fences render too', (
      WidgetTester tester,
    ) async {
      await show(tester, '```\n$diagram\n```');
      expect(painted(), findsOneWidget);
    });

    testWidgets('unsupported diagrams stay plain code', (
      WidgetTester tester,
    ) async {
      await show(tester, '```mermaid\nsequenceDiagram\n  A->>B: hi\n```');
      expect(painted(), findsNothing);
      expect(find.textContaining('A->>B', findRichText: true), findsOneWidget);
    });

    testWidgets('a still-streaming fence waits for its closing marker', (
      WidgetTester tester,
    ) async {
      await show(tester, '```mermaid\n$diagram', streaming: true);
      expect(painted(), findsNothing);

      await show(tester, '```mermaid\n$diagram\n```\nMore', streaming: true);
      await tester.pump(AgentMessageView.streamRenderInterval);
      expect(painted(), findsOneWidget);
    });

    testWidgets('expand opens a full-screen viewer', (
      WidgetTester tester,
    ) async {
      await show(tester, '```mermaid\n$diagram\n```');
      await tester.tap(find.byTooltip('Expand diagram'));
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(painted(), findsNWidgets(2));

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsNothing);
    });

    testWidgets('wide diagrams fit narrow screens', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final StringBuffer wide = StringBuffer('flowchart LR\n');
      for (int i = 0; i < 10; i++) {
        wide.writeln('  n$i["Step number $i"] --> n${i + 1}');
      }
      await show(tester, '```mermaid\n$wide```');
      expect(painted(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('typewriter', () {
    const String reply =
        'First line of the reply.\n\n'
        'A second paragraph follows it.\n\n'
        'Then a third.\n\n'
        'And a fourth to finish.';
    final Finder typewriter = find.byKey(const Key('typewriter'));
    final Finder body = find.byType(MarkdownBody);
    double typed(WidgetTester tester) => tester.getSize(typewriter).height;
    double whole(WidgetTester tester) => tester.getSize(body).height;

    Widget view(String text, {required bool writing}) => MaterialApp(
      theme: buildSpeedDialTheme(),
      home: Scaffold(
        body: AgentMessageView(text: text, streaming: true, writing: writing),
      ),
    );

    Future<void> frames(WidgetTester tester, int count) async {
      for (int i = 0; i < count; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    testWidgets('a message first seen being written types itself out', (
      WidgetTester tester,
    ) async {
      // However it arrived — here all at once — it shows a line at a time
      // behind the ember.
      await tester.pumpWidget(view(reply, writing: true));
      await frames(tester, 3);
      expect(typed(tester), greaterThan(0));
      expect(typed(tester), lessThan(whole(tester)));
      expect(typewriter, paints..circle());

      await frames(tester, 90);
      expect(typed(tester), whole(tester));
      // Caught up while still writing: the ember waits at the end.
      expect(typewriter, paints..circle());

      await tester.pumpWidget(view(reply, writing: false));
      await frames(tester, 60);
      expect(typewriter, isNot(paints..circle()));
      expect(typed(tester), whole(tester));
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('text arriving later types on from where it was', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(view('First line of the reply.', writing: true));
      await frames(tester, 30);
      final double first = whole(tester);
      expect(typed(tester), first);

      await tester.pumpWidget(view(reply, writing: true));
      await tester.pump(AgentMessageView.streamRenderInterval);
      await frames(tester, 2);
      expect(typed(tester), greaterThanOrEqualTo(first));
      expect(typed(tester), lessThan(whole(tester)));
      await frames(tester, 90);
      expect(typed(tester), whole(tester));

      await tester.pumpWidget(view(reply, writing: false));
      await frames(tester, 60);
    });

    testWidgets('a message first seen finished shows whole', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(view(reply, writing: false));
      expect(typed(tester), whole(tester));
      expect(typewriter, isNot(paints..circle()));
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('reduced motion shows the message whole', (
      WidgetTester tester,
    ) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpWidget(view(reply, writing: true));
      await tester.pump();
      expect(typed(tester), whole(tester));
      expect(typewriter, isNot(paints..circle()));
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('scrolling a typed message away and back does not retype it', (
      WidgetTester tester,
    ) async {
      final PageStorageBucket bucket = PageStorageBucket();
      Widget host({required bool shown}) => MaterialApp(
        theme: buildSpeedDialTheme(),
        home: Scaffold(
          body: PageStorage(
            bucket: bucket,
            child: shown
                ? const KeyedSubtree(
                    key: PageStorageKey<String>('reply'),
                    child: AgentMessageView(
                      text: reply,
                      streaming: true,
                      writing: true,
                    ),
                  )
                : const SizedBox(),
          ),
        ),
      );
      await tester.pumpWidget(host(shown: true));
      await frames(tester, 90);
      await tester.pumpWidget(host(shown: false));
      await tester.pumpWidget(host(shown: true));
      expect(typed(tester), whole(tester));
      await frames(tester, 2);
      expect(typed(tester), whole(tester));
    });
  });
}
