import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/clipboard/rich_clipboard_native.dart';
import 'package:speeddial_app/src/ui/chat/copy_menu.dart';
import 'package:speeddial_app/src/ui/chat/message_view.dart';
import 'package:speeddial_app/src/ui/chat/timeline.dart';

void main() {
  for (final bool dark in <bool>[false, true]) {
    testWidgets('message and table menus copy scoped formats (dark: $dark)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final List<String> copied = <String>[];
      final List<String> richHtml = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        richClipboardChannel,
        (call) async {
          expect(call.method, 'writeHtml');
          final Map<Object?, Object?> args =
              call.arguments as Map<Object?, Object?>;
          copied.add(args['text']! as String);
          richHtml.add(args['html']! as String);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          richClipboardChannel,
          null,
        ),
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      const String table = '| Name | Count |\n| --- | --- |\n| Apples | 3 |';
      await tester.pumpWidget(
        MaterialApp(
          theme: dark ? buildSpeedDialTheme() : buildSpeedDialLightTheme(),
          home: const Scaffold(
            body: MediaQuery(
              data: MediaQueryData(disableAnimations: true),
              child: Timeline(
                items: <TimelineItem>[
                  AgentMessageItem(
                    text: 'Before\n\n$table\n\nAfter',
                    forkSeq: 2,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Copy message'));
      await tester.pumpAndSettle();
      expect(copied, isEmpty);
      expect(find.text('Copy as CSV'), findsNothing);
      await tester.tap(find.text('Copy Markdown'));
      await tester.pumpAndSettle();
      expect(copied.single, 'Before\n\n$table\n\nAfter');
      for (final String label in <String>[
        'Copy as CSV',
        'Copy HTML',
        'Copy for Slack',
        'Copy Markdown',
      ]) {
        await tester.tap(
          find.text('Copy table').evaluate().isEmpty
              ? find.text('Copied')
              : find.text('Copy table'),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        expect(copied.last, isNot(contains('Before')));
        expect(copied.last, isNot(contains('After')));
        if (label == 'Copy as CSV') {
          expect(copied.last, 'Name,Count\r\nApples,3');
        }
        if (label == 'Copy HTML') expect(copied.last, contains('<table>'));
        if (label == 'Copy for Slack') {
          expect(copied.last, startsWith('Name'));
          expect(copied.last, isNot(contains('```')));
          expect(richHtml.single, startsWith('<pre>'));
          expect(richHtml.single, endsWith('</pre>'));
        }
        if (label == 'Copy Markdown') expect(copied.last, table);
      }
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Copied'), findsNothing);
      expect(tester.hasRunningAnimations, isFalse);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  }
  testWidgets('Android message and table menus publish labeled rows', (
    tester,
  ) async {
    final List<Map<Object?, Object?>> writes = <Map<Object?, Object?>>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      richClipboardChannel,
      (call) async {
        writes.add(call.arguments as Map<Object?, Object?>);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        richClipboardChannel,
        null,
      ),
    );
    const String table =
        '| What | Where |\n| - | - |\n| App | ~/.local/share/app |';
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSpeedDialTheme(),
        home: const Scaffold(
          body: SelectionArea(
            child: Column(
              children: <Widget>[
                CopyMenu(text: 'Before\n\n$table\n\nAfter'),
                CopyMenu(text: table, table: true),
              ],
            ),
          ),
        ),
      ),
    );
    for (final Finder button in <Finder>[
      find.byTooltip('Copy message'),
      find.text('Copy table'),
    ]) {
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy for Slack'));
      await tester.pumpAndSettle();
    }
    expect(writes, hasLength(2));
    expect(
      writes.first['text'],
      'Before\n\nWhat: App\nWhere: ~/.local/share/app\n\nAfter',
    );
    expect(writes.last['text'], 'What: App\nWhere: ~/.local/share/app');
    for (final Map<Object?, Object?> write in writes) {
      expect(
        write['html'],
        contains(
          '<strong>What: </strong>App<br><strong>Where: </strong>~/.local/share/app',
        ),
      );
      expect(write['html'], isNot(contains('<pre>')));
    }
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  testWidgets(
    'rich clipboard failure reports an error without plain-text fallback',
    (tester) async {
      final List<MethodCall> plainWrites = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') plainWrites.add(call);
          return null;
        },
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        richClipboardChannel,
        (call) async {
          throw PlatformException(
            code: 'clipboard_write',
            message: 'Clipboard busy',
          );
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          richClipboardChannel,
          null,
        );
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSpeedDialTheme(),
          home: const Scaffold(body: CopyMenu(text: '**Hello**')),
        ),
      );
      await tester.tap(find.byTooltip('Copy message'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy for Slack'));
      await tester.pumpAndSettle();
      expect(plainWrites, isEmpty);
      expect(find.byTooltip('Copied'), findsNothing);
      expect(find.text('Could not copy to clipboard'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'tables inside quotes and consecutive tables each have copy controls',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSpeedDialTheme(),
          home: const Scaffold(
            body: SelectionArea(
              child: AgentMessageView(
                text: '> | A | B |\n> | - | - |\n> | 1 | 2 |\n\nOutside\n\n| C | D |\n| - | - |\n| 3 | 4 |',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Copy table'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );
}
