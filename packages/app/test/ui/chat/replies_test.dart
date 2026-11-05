import 'dart:ui' show ClipOp;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/state/replies_store.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/chat/composer.dart';
import 'package:speeddial_app/src/ui/chat/message_view.dart';
import 'package:speeddial_app/src/ui/chat/replies.dart';
import 'package:speeddial_app/src/ui/chat/reply_marks.dart';
import 'package:speeddial_app/src/ui/chat/timeline.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

void main() {
  group('reply text format', () {
    test('round-trips replies ahead of the message body', () {
      final String text = formatMessageWithReplies(const <ReplyDraft>[
        ReplyDraft(id: 0, quote: 'first passage', reply: 'why?'),
        ReplyDraft(id: 1, quote: 'two\nlines', reply: 'agreed\nmostly'),
      ], 'And the rest.');
      final ({List<SentReply> replies, String body}) parsed = parseReplies(
        text,
      );
      expect(parsed.body, 'And the rest.');
      expect(parsed.replies.map((SentReply r) => r.quote), <String>[
        'first passage',
        'two\nlines',
      ]);
      expect(parsed.replies.map((SentReply r) => r.reply), <String>[
        'why?',
        'agreed\nmostly',
      ]);
    });

    test('a message of only replies has an empty body', () {
      final String text = formatMessageWithReplies(const <ReplyDraft>[
        ReplyDraft(id: 0, quote: 'q', reply: 'r'),
      ], '');
      final ({List<SentReply> replies, String body}) parsed = parseReplies(
        text,
      );
      expect(parsed.replies, hasLength(1));
      expect(parsed.body, isEmpty);
    });

    test('plain text is left alone', () {
      final ({List<SentReply> replies, String body}) parsed = parseReplies(
        '<reply> is just a word here',
      );
      expect(parsed.replies, isEmpty);
      expect(parsed.body, '<reply> is just a word here');
    });
  });

  test('RepliesStore stages, edits and removes per session', () {
    final RepliesStore store = RepliesStore();
    addTearDown(store.dispose);
    int notifications = 0;
    store.addListener(() => notifications++);
    store.add('d', 's', 'quote', 'reply');
    store.add('d', 'other', 'elsewhere', 'reply');
    final int id = store.repliesFor('d', 's').single.id;
    store.edit('d', 's', id, 'edited');
    expect(store.repliesFor('d', 's').single.reply, 'edited');
    store.remove('d', 's', <int>[id]);
    expect(store.repliesFor('d', 's'), isEmpty);
    expect(store.repliesFor('d', 'other'), hasLength(1));
    expect(notifications, 4);
  });

  group('Composer replies', () {
    Future<void> pump(
      WidgetTester tester, {
      required List<ReplyDraft> replies,
      required Future<void> Function(String text) onSend,
      void Function(int id, String reply)? onEdit,
      ValueChanged<int>? onRemove,
      ValueChanged<List<int>>? onSent,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSpeedDialTheme(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: Composer(
                status: SessionStatus.idle,
                replies: replies,
                onEditReply: onEdit,
                onRemoveReply: onRemove,
                onRepliesSent: onSent,
                onSend: (String text, List<OutgoingAttachment> _) =>
                    onSend(text),
                onStop: () {},
              ),
            ),
          ),
        ),
      );
    }

    const ReplyDraft staged = ReplyDraft(
      id: 7,
      quote: 'The cache is cold',
      reply: 'Warm it first?',
    );

    testWidgets('a staged reply shows as a chip that opens its editor', (
      WidgetTester tester,
    ) async {
      final List<String> edits = <String>[];
      int? removed;
      await pump(
        tester,
        replies: const <ReplyDraft>[staged],
        onSend: (_) async {},
        onEdit: (int id, String reply) => edits.add('$id:$reply'),
        onRemove: (int id) => removed = id,
      );
      expect(find.text('“The cache is cold”'), findsOneWidget);
      expect(find.byKey(const Key('reply-editor')), findsNothing);

      await tester.tap(find.text('“The cache is cold”'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reply-editor')), findsOneWidget);
      expect(find.text('The cache is cold'), findsOneWidget);
      expect(find.text('Warm it first?'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('reply-editor-field')),
        'Warm it now',
      );
      expect(edits, <String>['7:Warm it now']);

      await tester.tap(find.byTooltip('Remove reply'));
      expect(removed, 7);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('sending carries replies ahead of the text', (
      WidgetTester tester,
    ) async {
      String? sent;
      List<int>? cleared;
      await pump(
        tester,
        replies: const <ReplyDraft>[staged],
        onSend: (String text) async => sent = text,
        onSent: (List<int> ids) => cleared = ids,
      );
      // Replies alone are enough to send.
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      expect(parseReplies(sent!).replies.single.reply, 'Warm it first?');
      expect(cleared, <int>[7]);
    });

    testWidgets('a failed send keeps the replies staged', (
      WidgetTester tester,
    ) async {
      List<int>? cleared;
      await pump(
        tester,
        replies: const <ReplyDraft>[staged],
        onSend: (_) async => throw StateError('rejected'),
        onSent: (List<int> ids) => cleared = ids,
      );
      await tester.enterText(find.byType(TextField), 'Also this');
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(cleared, isNull);
      // Only the typed text comes back into the field.
      expect(find.text('Also this'), findsOneWidget);
    });
  });

  group('ReplyMarkResolver', () {
    const AgentMessageItem older = AgentMessageItem(
      text: 'The **cache** is `cold` today.\n\n- first item\n- second item',
    );
    const AgentMessageItem newer = AgentMessageItem(text: 'The cache is warm.');

    String sent(String quote) => formatMessageWithReplies(<ReplyDraft>[
      ReplyDraft(id: 0, quote: quote, reply: 'why?'),
    ], '');

    test('matches rendered text, not the markdown source', () {
      final Map<int, List<String>> marks = ReplyMarkResolver().resolve(
        <TimelineItem>[older, UserMessageItem(text: sent('cache is cold'))],
        const <String>[],
      );
      expect(marks, <int, List<String>>{
        0: <String>['cache is cold'],
      });
    });

    test('a selection across list items still matches', () {
      final Map<int, List<String>> marks = ReplyMarkResolver().resolve(
        const <TimelineItem>[older],
        const <String>['first item•second item'],
      );
      expect(marks.keys, <int>[0]);
    });

    test('a sent reply marks the nearest message before it', () {
      final Map<int, List<String>> marks = ReplyMarkResolver().resolve(
        <TimelineItem>[older, UserMessageItem(text: sent('The cache')), newer],
        const <String>[],
      );
      expect(marks.keys, <int>[0]);
    });

    test('a staged quote marks the latest message holding it', () {
      final Map<int, List<String>> marks = ReplyMarkResolver().resolve(
        const <TimelineItem>[older, newer],
        const <String>['The cache'],
      );
      expect(marks.keys, <int>[1]);
    });

    test('a quote found nowhere marks nothing', () {
      expect(
        ReplyMarkResolver().resolve(
          const <TimelineItem>[older],
          const <String>['not in any message'],
        ),
        isEmpty,
      );
    });
  });

  group('ReplyMarks', () {
    const AgentMessageItem message = AgentMessageItem(
      id: 'a',
      text: 'The cache is `cold` today.\n\n```\nlet x = 1;\n```\n\nAfter code.',
    );

    testWidgets('marks only the quoted text, across inline code', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _timeline(<TimelineItem>[message], staged: <String>['cache is cold']),
      );
      await tester.pumpAndSettle();
      // The text before the inline code, and the code itself.
      expect(_washes(tester, _marksOn('today')), 2);
    });

    testWidgets('a quote across blocks skips the copy button label', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _timeline(
          <TimelineItem>[message],
          staged: <String>['today.let x = 1;After'],
        ),
      );
      await tester.pumpAndSettle();
      expect(_washes(tester, _marksOn('today')), 3);
    });

    testWidgets('a sent reply marks the message it answers', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _timeline(<TimelineItem>[
          message,
          UserMessageItem(
            id: 'u',
            text: formatMessageWithReplies(const <ReplyDraft>[
              ReplyDraft(id: 0, quote: 'After code.', reply: 'why?'),
            ], 'Next'),
          ),
        ]),
      );
      await tester.pumpAndSettle();
      expect(_washes(tester, _marksOn('today')), 1);
    });

    testWidgets('a text with no reply paints nothing', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_timeline(<TimelineItem>[message]));
      await tester.pumpAndSettle();
      expect(_washes(tester, _marksOn('today')), 0);
    });

    testWidgets('a mark flares when staged, then settles', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_timeline(<TimelineItem>[message]));
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        _timeline(<TimelineItem>[message], staged: <String>['After code.']),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(_glows(tester, _marksOn('today')), 1);
      await tester.pumpAndSettle();
      expect(_glows(tester, _marksOn('today')), 0);
      expect(_washes(tester, _marksOn('today')), 1);
    });

    testWidgets('reduced motion shows the mark at once', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_timeline(<TimelineItem>[message], still: true));
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        _timeline(
          <TimelineItem>[message],
          staged: <String>['After code.'],
          still: true,
        ),
      );
      await tester.pump();
      expect(_glows(tester, _marksOn('today')), 0);
      expect(_washes(tester, _marksOn('today')), 1);
    });
  });

  testWidgets('a sent message shows its replies as chips that expand', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSpeedDialTheme(),
        home: Scaffold(
          body: UserMessageBubble(
            text: formatMessageWithReplies(const <ReplyDraft>[
              ReplyDraft(id: 0, quote: 'Ship it Friday', reply: 'Monday?'),
            ], 'Otherwise fine.'),
          ),
        ),
      ),
    );
    expect(find.text('Otherwise fine.'), findsOneWidget);
    expect(find.text('“Ship it Friday”'), findsOneWidget);
    expect(find.textContaining('<reply>'), findsNothing);
    expect(find.text('Monday?'), findsNothing);

    await tester.tap(find.text('“Ship it Friday”'));
    await tester.pumpAndSettle();
    expect(find.text('Ship it Friday'), findsOneWidget);
    expect(find.text('Monday?'), findsOneWidget);
  });

  testWidgets(
    'Reply on a timeline selection opens a box and stages the reply',
    (WidgetTester tester) async {
      final List<String> replies = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSpeedDialTheme(),
          home: Scaffold(
            body: Timeline(
              items: const <TimelineItem>[
                AgentMessageItem(text: 'Preheat the oven', forkSeq: 2),
              ],
              onReply: (String quote, String reply) =>
                  replies.add('$quote|$reply'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.longPress(find.textContaining('Preheat the oven'));
      await tester.pumpAndSettle();
      expect(find.text('Reply'), findsOneWidget);

      await tester.tap(find.text('Reply'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reply-popover')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('reply-popover-field')),
        'How hot?',
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Add reply'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('reply-popover')), findsNothing);
      expect(replies, hasLength(1));
      expect(replies.single, endsWith('|How hot?'));
      expect(replies.single, isNot(startsWith('|')));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('a real selection across every block kind marks its message', (
    WidgetTester tester,
  ) async {
    const AgentMessageItem rich = AgentMessageItem(
      id: 'a',
      text:
          'Intro with `inline code`, **bold** and [a link](https://x.dev).\n\n'
          '- bullet one\n- bullet two\n\n'
          '1. step one\n2. step two\n\n'
          '> a quoted line\n\n'
          '```\nlet x = 1;\n```\n\n'
          '| A | B |\n|---|---|\n| c | d |\n\n'
          'The end.',
    );
    String? quote;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSpeedDialTheme(),
        home: Scaffold(
          body: Timeline(
            items: const <TimelineItem>[rich],
            onReply: (String q, String _) => quote = q,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.textContaining('Intro'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select all'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reply'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('reply-popover-field')),
      'Why?',
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Add reply'));
    await tester.pumpAndSettle();
    expect(quote, allOf(contains('Intro'), contains('The end.')));

    expect(
      ReplyMarkResolver()
          .resolve(const <TimelineItem>[rich], <String>[quote!])
          .keys,
      <int>[0],
    );
    await tester.pumpWidget(
      _timeline(const <TimelineItem>[rich], staged: <String>[quote!]),
    );
    await tester.pumpAndSettle();
    expect(_washes(tester, _marksOn('Intro')), greaterThan(5));
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('Enter adds the reply, Shift+Enter breaks the line, Esc drops it', (
    WidgetTester tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSpeedDialTheme(),
        home: Builder(
          builder: (BuildContext c) {
            context = c;
            return const Scaffold();
          },
        ),
      ),
    );
    const TextSelectionToolbarAnchors anchors = TextSelectionToolbarAnchors(
      primaryAnchor: Offset(200, 100),
    );
    Future<String?> result = showReplyPopover(
      context,
      anchors: anchors,
      quote: 'q',
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('reply-popover-field')), 'a');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.enterText(
      find.byKey(const Key('reply-popover-field')),
      '${tester.widget<TextField>(find.byKey(const Key('reply-popover-field'))).controller!.text}b',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(await result, 'a\nb');

    result = showReplyPopover(context, anchors: anchors, quote: 'q');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(await result, isNull);
    expect(find.byKey(const Key('reply-popover')), findsNothing);
  });

  testWidgets('Reply is not offered without a handler', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSpeedDialTheme(),
        home: const Scaffold(
          body: Timeline(
            items: <TimelineItem>[
              AgentMessageItem(text: 'Preheat the oven', forkSeq: 2),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.textContaining('Preheat the oven'));
    await tester.pumpAndSettle();
    expect(find.text('Reply'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('a freshly staged reply chip pops, then settles', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSpeedDialTheme(),
        home: Scaffold(
          body: Center(
            child: ReplyChip(
              reply: const ReplyDraft(id: 1, quote: 'q', reply: 'r'),
              open: false,
              fresh: true,
              onTap: () {},
              onRemove: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('reduced motion lands a fresh reply chip at once', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          theme: buildSpeedDialTheme(),
          home: Scaffold(
            body: Center(
              child: ReplyChip(
                reply: const ReplyDraft(id: 1, quote: 'q', reply: 'r'),
                open: false,
                fresh: true,
                onTap: () {},
                onRemove: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);
  });
}

_RectCounter _paintMarks(WidgetTester tester, Finder finder) {
  final RenderCustomPaint object = tester.renderObject(finder);
  final _RectCounter counter = _RectCounter();
  object.foregroundPainter?.paint(counter, object.size);
  return counter;
}

/// How many runs of text [ReplyMarks] marked: each is a wash and an underline.
int _washes(WidgetTester tester, Finder finder) =>
    _paintMarks(tester, finder).plain ~/ 2;

/// How many of those runs are still flaring.
int _glows(WidgetTester tester, Finder finder) =>
    _paintMarks(tester, finder).glows;

class _RectCounter implements Canvas {
  int plain = 0;
  int glows = 0;

  @override
  void drawRect(Rect rect, Paint paint) {
    if (paint.maskFilter == null) {
      plain++;
    } else {
      glows++;
    }
  }

  @override
  void save() {}

  @override
  void restore() {}

  @override
  void clipRect(
    Rect rect, {
    ClipOp clipOp = ClipOp.intersect,
    bool doAntiAlias = true,
  }) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _timeline(
  List<TimelineItem> items, {
  List<String> staged = const <String>[],
  bool still = false,
}) => MaterialApp(
  theme: buildSpeedDialTheme(),
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: still),
    child: Scaffold(
      body: Timeline(items: items, stagedQuotes: staged),
    ),
  ),
);

Finder _marksOn(String text) => find
    .descendant(
      of: find.ancestor(
        of: find.textContaining(text),
        matching: find.byType(ReplyMarks),
      ),
      matching: find.byType(CustomPaint),
    )
    .first;
