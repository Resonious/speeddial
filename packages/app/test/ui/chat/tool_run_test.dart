import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/chat/tail_text.dart';
import 'package:speeddial_app/src/ui/chat/thought_line.dart';
import 'package:speeddial_app/src/ui/chat/timeline.dart';
import 'package:speeddial_app/src/ui/chat/tool_run.dart';
import 'package:speeddial_app/src/ui/chat/typed_text.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

ToolCall _call(
  String id,
  String title, {
  ToolCallStatus status = ToolCallStatus.completed,
}) => ToolCall(
  id: id,
  title: title,
  kind: 'read',
  status: status,
  content: const <ToolCallContent>[ToolCallText(text: 'output')],
  locations: const <String>[],
);

Future<void> frames(WidgetTester tester, int count) async {
  for (int i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  group('tool runs', () {
    test('back-to-back calls fold into one run that keeps its identity', () {
      final List<SessionEvent> events = <SessionEvent>[
        const UserMessageEvent(text: 'go'),
        ToolCallEvent(toolCall: _call('a', 'Read a')),
        ToolCallEvent(toolCall: _call('b', 'Read b')),
        const AgentMessageChunkEvent(text: 'Now this:'),
        ToolCallEvent(toolCall: _call('c', 'Read c')),
      ];
      List<List<String>> runs(List<TimelineItem> items) => <List<String>>[
        for (final ToolRunItem run in items.whereType<ToolRunItem>())
          <String>[
            for (final ToolCallTimelineItem call in run.calls) call.toolCall.id,
          ],
      ];

      final List<TimelineItem> items = deriveTimelineItems(events);
      // Anything in between (here a message) starts a new run.
      expect(runs(items), <List<String>>[
        <String>['a', 'b'],
        <String>['c'],
      ]);
      expect(items.whereType<ToolCallTimelineItem>(), isEmpty);

      final List<TimelineItem> grown = deriveTimelineItems(<SessionEvent>[
        ...events,
        ToolCallEvent(toolCall: _call('d', 'Read d')),
      ]);
      expect(runs(grown).last, <String>['c', 'd']);
      expect(grown.last.id, items.last.id);
    });

    Widget app(List<ToolCallTimelineItem> calls) => MaterialApp(
      theme: buildSpeedDialTheme(),
      home: Scaffold(
        body: Timeline(
          items: <TimelineItem>[ToolRunItem(id: 'run', steps: calls)],
        ),
      ),
    );
    ToolCallTimelineItem item(ToolCall call) =>
        ToolCallTimelineItem(id: call.id, toolCall: call);
    final Finder header = find.byKey(const Key('tool-run-header'));
    double height(WidgetTester tester) =>
        tester.getSize(find.byType(ToolRunCard)).height;

    testWidgets('a run shows its latest call under a count of them all', (
      WidgetTester tester,
    ) async {
      final ToolCallTimelineItem config = item(_call('a', 'Read the config'));
      final ToolCallTimelineItem search = item(
        _call('b', 'Search for retries'),
      );
      final ToolCallTimelineItem tests = item(
        _call('c', 'Run the tests', status: ToolCallStatus.failed),
      );

      await tester.pumpWidget(app(<ToolCallTimelineItem>[config]));
      expect(find.text('Read the config'), findsOneWidget);
      expect(header, findsNothing);

      await tester.pumpWidget(app(<ToolCallTimelineItem>[config, search]));
      await tester.pumpAndSettle();
      expect(header, findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      // Only the latest shows; the one before it is counted.
      expect(find.text('Search for retries'), findsOneWidget);
      expect(find.text('Read the config'), findsNothing);
      final double counted = height(tester);

      await tester.pumpWidget(
        app(<ToolCallTimelineItem>[config, search, tests]),
      );
      await tester.pumpAndSettle();
      expect(find.text('3'), findsOneWidget);
      expect(find.text(' · 1 failed'), findsOneWidget);
      expect(find.text('Run the tests'), findsOneWidget);
      // However many calls come, the run keeps its height.
      expect(height(tester), counted);

      await tester.tap(header);
      await tester.pumpAndSettle();
      expect(find.text('Read the config'), findsOneWidget);
      expect(find.text('Search for retries'), findsOneWidget);
      expect(find.text('Run the tests'), findsOneWidget);
      await tester.tap(header);
      await tester.pumpAndSettle();
      expect(find.text('Read the config'), findsNothing);
      expect(height(tester), counted);
    });

    testWidgets('the latest line opens on its call\'s command and output', (
      WidgetTester tester,
    ) async {
      final ToolCall shell = ToolCall(
        id: 'shell',
        title: 'flutter test',
        kind: 'execute',
        status: ToolCallStatus.completed,
        content: const <ToolCallContent>[ToolCallText(text: 'All passed')],
        locations: const <String>[],
        rawInput: const <String, Object?>{
          'command': 'flutter test',
          'description': 'Run the app tests',
        },
      );
      await tester.pumpWidget(app(<ToolCallTimelineItem>[item(shell)]));
      // Collapsed, the line is the description alone.
      expect(find.text('Run the app tests'), findsOneWidget);
      expect(find.text('flutter test').hitTestable(), findsNothing);

      await tester.tap(find.text('Run the app tests'));
      await tester.pumpAndSettle();
      expect(find.text('flutter test').hitTestable(), findsOneWidget);
      expect(find.text('All passed').hitTestable(), findsOneWidget);
    });
  });

  group('thinking in runs', () {
    test('thoughts join the run instead of breaking it', () {
      final List<TimelineItem> items = deriveTimelineItems(<SessionEvent>[
        const UserMessageEvent(text: 'go'),
        const AgentThoughtChunkEvent(
          text: 'First, the config.',
          messageId: 't1',
        ),
        ToolCallEvent(toolCall: _call('a', 'Read a')),
        const AgentThoughtChunkEvent(text: 'Now the tests.', messageId: 't2'),
        ToolCallEvent(toolCall: _call('b', 'Read b')),
        const AgentMessageChunkEvent(text: 'Found it.'),
        const AgentThoughtChunkEvent(text: 'Anything else?', messageId: 't3'),
      ]);
      String kind(TimelineItem step) =>
          step is AgentThoughtItem ? 'thought' : 'call';
      expect(
        <List<String>>[
          for (final ToolRunItem run in items.whereType<ToolRunItem>())
            run.steps.map(kind).toList(),
        ],
        <List<String>>[
          <String>['thought', 'call', 'thought', 'call'],
          <String>['thought'],
        ],
      );
      expect(items.whereType<AgentThoughtItem>(), isEmpty);
    });

    Widget app(List<TimelineItem> steps) => MaterialApp(
      theme: buildSpeedDialTheme(),
      home: Scaffold(
        body: Timeline(
          items: <TimelineItem>[ToolRunItem(id: 'run', steps: steps)],
        ),
      ),
    );
    const AgentThoughtItem thinking = AgentThoughtItem(
      id: 't',
      text: 'The loop gives up on the first error, so retry it.',
      active: true,
    );
    const AgentThoughtItem thought = AgentThoughtItem(
      id: 't',
      text: 'The loop gives up on the first error, so retry it.',
    );
    final ToolCallTimelineItem edit = ToolCallTimelineItem(
      id: 'e',
      active: true,
      toolCall: _call('e', 'Edit sync.dart', status: ToolCallStatus.pending),
    );

    const AgentThoughtItem next = AgentThoughtItem(
      id: 't2',
      text: 'Tests next.',
      active: true,
    );
    final Finder header = find.byKey(const Key('tool-run-header'));

    testWidgets('thinking keeps a line beside the call it led to', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(app(const <TimelineItem>[thinking]));
      await frames(tester, 40);
      expect(find.byType(ThoughtLine), findsOneWidget);
      expect(find.textContaining('so retry it.'), findsOneWidget);

      // Providers think in a burst just before calling: the call takes a
      // line of its own instead of the thought's. Nothing is out of sight,
      // so nothing is counted.
      await tester.pumpWidget(app(<TimelineItem>[thought, edit]));
      await frames(tester, 40);
      expect(find.textContaining('so retry it.'), findsOneWidget);
      expect(find.text('Edit sync.dart'), findsOneWidget);
      expect(header, findsNothing);

      // A newer thought takes over the thinking line; the first is counted.
      await tester.pumpWidget(app(<TimelineItem>[thought, edit, next]));
      await frames(tester, 40);
      expect(find.textContaining('Tests next.'), findsOneWidget);
      expect(find.textContaining('so retry it.'), findsNothing);
      expect(find.text('Edit sync.dart'), findsOneWidget);
      expect(find.text(' tool call'), findsOneWidget);
      expect(find.text(' thoughts'), findsOneWidget);

      // Every step shows in the list.
      await tester.tap(header);
      await frames(tester, 40);
      expect(find.byType(ThoughtLine), findsNWidgets(2));
      expect(find.text('Edit sync.dart'), findsOneWidget);
    });

    testWidgets('a growing run holds still under reduced motion', (
      WidgetTester tester,
    ) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpWidget(app(const <TimelineItem>[thinking]));
      await tester.pumpWidget(app(<TimelineItem>[thought, edit]));
      await tester.pumpWidget(app(<TimelineItem>[thought, edit, next]));
      expect(tester.takeException(), isNull);
      // Everything shows at once; only the card's own cross-fade (which
      // ignores reduced motion) settles over the next frames.
      expect(header, findsOneWidget);
      expect(find.textContaining('Tests next.'), findsOneWidget);
      expect(find.text('Edit sync.dart'), findsOneWidget);
      await frames(tester, 20);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('a long thought opens at once', (WidgetTester tester) async {
      // Past the length that animates (see animateHistoryText).
      final String long = List<String>.filled(
        80,
        'Weighing the retry.',
      ).join(' ');
      await tester.pumpWidget(
        app(<TimelineItem>[AgentThoughtItem(id: 'long', text: long)]),
      );
      await tester.tap(find.byType(ThoughtLine));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('thought-body')), findsOneWidget);
    });
  });

  group('tail text', () {
    Widget host(String text, {bool live = false, double width = 200}) =>
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                child: TailText(text, live: live, background: Colors.white),
              ),
            ),
          ),
        );
    String shown(WidgetTester tester) =>
        tester.widget<Text>(find.byType(Text)).data!;
    final Finder line = find.byType(TailText);
    final Finder text = find.byType(Text);

    testWidgets('a line too long shows its end, the start cut off', (
      WidgetTester tester,
    ) async {
      const String long =
          'The sync loop gives up after the first network error, so a '
          'flaky connection stalls everything until a restart.';
      await tester.pumpWidget(host(long));
      expect(shown(tester), long);
      // Shifted left so the end sits at the line's end.
      expect(tester.getTopLeft(text).dx, lessThan(tester.getTopLeft(line).dx));
      expect(
        tester.getTopRight(text).dx,
        moreOrLessEquals(tester.getTopRight(line).dx),
      );
    });

    testWidgets('a short line sits at the start', (WidgetTester tester) async {
      await tester.pumpWidget(host('Short.'));
      expect(tester.getTopLeft(text).dx, tester.getTopLeft(line).dx);
    });

    testWidgets('a live text runs on from its start', (
      WidgetTester tester,
    ) async {
      const String thought = 'Let me check how the retries back off first.';
      await tester.pumpWidget(host(thought, live: true));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(shown(tester).length, lessThan(thought.length));
      expect(thought.startsWith(shown(tester)), isTrue);
      await tester.pumpAndSettle();
      expect(shown(tester), thought);
    });

    testWidgets('line breaks and markdown fold into one plain line', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host('**Planning**\n\nRetry `pump()` with backoff'),
      );
      expect(shown(tester), 'Planning Retry pump() with backoff');
    });
  });

  group('typed text', () {
    Widget host(String text, {bool typeIn = false}) => MaterialApp(
      home: Scaffold(body: TypedText(text, typeIn: typeIn)),
    );
    String shown(WidgetTester tester) =>
        tester.widget<Text>(find.byType(Text)).data!;

    testWidgets('backspaces to what the texts share, then types the rest', (
      WidgetTester tester,
    ) async {
      const String before = 'Read timeline.dart';
      const String after = 'Read tool_run.dart';
      await tester.pumpWidget(host(before, typeIn: true));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(shown(tester).length, lessThan(before.length));
      await tester.pumpAndSettle();
      expect(shown(tester), before);

      await tester.pumpWidget(host(after));
      final List<String> seen = <String>[];
      for (int i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        seen.add(shown(tester));
      }
      expect(seen.last, after);
      // Backspaced through the old text, typed through the new, and never
      // past what the two share.
      expect(
        seen.every(
          (String text) => before.startsWith(text) || after.startsWith(text),
        ),
        isTrue,
      );
      expect(
        seen.map((String text) => text.length).reduce(math.min),
        'Read t'.length,
      );
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('shows at once unless asked to type in', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(host('Search for retries'));
      expect(shown(tester), 'Search for retries');
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('changes at once under reduced motion', (
      WidgetTester tester,
    ) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpWidget(host('Read a', typeIn: true));
      expect(shown(tester), 'Read a');
      await tester.pumpWidget(host('Search b'));
      await tester.pump();
      expect(shown(tester), 'Search b');
      expect(tester.hasRunningAnimations, isFalse);
    });
  });
}
