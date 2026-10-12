import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/chat/compaction.dart';
import 'package:speeddial_app/src/ui/chat/timeline.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

UsageEvent _usage(int used) => UsageEvent(
  usage: UsageInfo(
    inputTokens: 0,
    outputTokens: 0,
    totalTokens: used,
    contextUsedTokens: used,
  ),
);

/// How Codex and Ante report one.
AgentActivityEvent _activity(
  String id,
  AgentActivityStatus status, {
  List<String> details = const <String>[],
}) => AgentActivityEvent(
  activity: AgentActivity(
    id: id,
    kind: 'compaction',
    title: 'Compact conversation context',
    status: status,
    details: details,
  ),
);

/// How Claude reports one: a call, its counts in the output once done.
ToolCallEvent _claude(ToolCallStatus status) => ToolCallEvent(
  toolCall: ToolCall(
    id: 'compact-1',
    title: 'Compact conversation',
    kind: 'think',
    status: status,
    content: const <ToolCallContent>[],
    locations: const <String>[],
    rawOutput: status == ToolCallStatus.completed
        ? const <String, Object?>{
            'trigger': 'automatic',
            'preTokens': 967280,
            'postTokens': 12018,
          }
        : null,
  ),
);

ToolCallEvent _read(String id) => ToolCallEvent(
  toolCall: ToolCall(
    id: id,
    title: 'Read',
    kind: 'read',
    status: ToolCallStatus.completed,
    content: const <ToolCallContent>[],
    locations: const <String>[],
    rawInput: <String, Object?>{'file_path': 'lib/$id.dart'},
  ),
);

const UserMessageEvent _ask = UserMessageEvent(text: 'Merge and push.');

CompactionItem _only(List<TimelineItem> items) =>
    items.whereType<CompactionItem>().single;

void main() {
  group('deriving', () {
    test(
      'Codex and Ante report it as an activity, sized by usage around it',
      () {
        final List<SessionEvent> events = <SessionEvent>[
          _ask,
          _usage(312932),
          _activity('codex-compaction-1', AgentActivityStatus.running),
        ];
        final CompactionItem reducing = _only(
          deriveTimelineItems(events, running: true),
        );
        expect(reducing.status, AgentActivityStatus.running);
        expect(reducing.active, isTrue);
        expect(reducing.before, 312932);
        expect(reducing.after, isNull);
        // A running one in a turn that is not is not reducing any more.
        expect(_only(deriveTimelineItems(events)).active, isFalse);

        final CompactionItem done = _only(
          deriveTimelineItems(<SessionEvent>[
            ...events,
            // Read before it took hold: not what it came down to.
            _usage(312932),
            _activity('codex-compaction-1', AgentActivityStatus.completed),
            _usage(48211),
            _usage(51000),
          ]),
        );
        expect(done.status, AgentActivityStatus.completed);
        expect((done.before, done.after), (312932, 48211));
      },
    );

    test('Ante settles its own with the summary, or fails', () {
      final List<CompactionItem> compactions = deriveTimelineItems(
        <SessionEvent>[
          _ask,
          _activity(
            'ante-compact-evt_1',
            AgentActivityStatus.completed,
            details: <String>['The commits are merged; docs next.'],
          ),
          _activity('ante-compact-evt_2', AgentActivityStatus.failed),
        ],
      ).whereType<CompactionItem>().toList();
      expect(compactions.first.summary, 'The commits are merged; docs next.');
      expect(compactions.last.status, AgentActivityStatus.failed);
      expect(compactions.last.summary, isNull);
    });

    test('Claude reports it as a call: a divider, not a tool call', () {
      final List<TimelineItem> items = deriveTimelineItems(<SessionEvent>[
        _ask,
        _read('a'),
        _claude(ToolCallStatus.running),
        _claude(ToolCallStatus.completed),
        _read('b'),
      ]);
      // It splits the calls around it into runs of their own.
      expect(items.map((TimelineItem item) => item.runtimeType), <Type>[
        UserMessageItem,
        ToolRunItem,
        CompactionItem,
        ToolRunItem,
      ]);
      final CompactionItem compaction = _only(items);
      expect(compaction.status, AgentActivityStatus.completed);
      expect((compaction.before, compaction.after), (967280, 12018));
      expect(compaction.automatic, isTrue);
    });

    test('tokens read short', () {
      expect(<int>[812, 12018, 967280, 1234567].map(compactTokens), <String>[
        '812',
        '12k',
        '967k',
        '1.2M',
      ]);
    });
  });

  group('the divider', () {
    // One theme instance: a fresh one per pump would crossfade themes.
    final ThemeData theme = buildSpeedDialTheme();
    Widget app(List<SessionEvent> events, {bool running = false}) =>
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Timeline(
              items: deriveTimelineItems(events, running: running),
            ),
          ),
        );

    testWidgets('simmers while reducing, then says what it came down to', (
      WidgetTester tester,
    ) async {
      final List<SessionEvent> events = <SessionEvent>[
        _ask,
        _usage(312932),
        _activity('codex-compaction-1', AgentActivityStatus.running),
      ];
      await tester.pumpWidget(app(events, running: true));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Reducing the conversation…'), findsOneWidget);
      expect(
        find.byKey(const Key('compaction-row')),
        paints..circle(style: PaintingStyle.stroke),
      );

      await tester.pumpWidget(
        app(<SessionEvent>[
          ...events,
          _activity('codex-compaction-1', AgentActivityStatus.completed),
          _usage(48211),
          const TurnCompleteEvent(stopReason: 'end_turn'),
        ]),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Conversation reduced · 313k → 48k tokens'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('compaction-row')),
        isNot(paints..circle(style: PaintingStyle.stroke)),
      );
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('opens to the summary when the harness gave one', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        app(<SessionEvent>[
          _ask,
          _activity(
            'ante-compact-evt_1',
            AgentActivityStatus.completed,
            details: <String>['The commits are merged; docs next.'],
          ),
        ]),
      );
      final Finder summary = find.text(
        'The commits are merged; docs next.',
        findRichText: true,
      );
      expect(summary, findsNothing);
      await tester.tap(find.text('Conversation reduced'));
      await tester.pumpAndSettle();
      expect(summary, findsOneWidget);
    });

    testWidgets('says when it failed', (WidgetTester tester) async {
      await tester.pumpWidget(
        app(<SessionEvent>[
          _ask,
          _activity('ante-compact-evt_2', AgentActivityStatus.failed),
        ]),
      );
      expect(find.text('Couldn’t reduce the conversation'), findsOneWidget);
    });

    testWidgets('holds still under reduced motion', (
      WidgetTester tester,
    ) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpWidget(
        app(<SessionEvent>[
          _ask,
          _activity('codex-compaction-1', AgentActivityStatus.running),
        ], running: true),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Reducing the conversation…'), findsOneWidget);
      expect(
        find.byKey(const Key('compaction-row')),
        isNot(paints..circle(style: PaintingStyle.stroke)),
      );
    });
  });
}
