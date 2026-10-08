import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/chat/message_view.dart';
import 'package:speeddial_app/src/ui/chat/oven.dart';
import 'package:speeddial_app/src/ui/chat/timeline.dart';
import 'package:speeddial_app/src/ui/chat/tool_call_card.dart';

import 'package:speeddial_protocol/speeddial_protocol.dart';

void main() {
  group('message alignment', () {
    testWidgets('user messages sit right and agent messages sit left', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSpeedDialTheme(),
          home: Scaffold(
            body: Timeline(
              items: const <TimelineItem>[
                UserMessageItem(text: 'My message', forkSeq: 1),
                AgentMessageItem(text: 'Agent message', forkSeq: 2),
              ],
              onFork: (_) {},
            ),
          ),
        ),
      );

      final Rect userMessage = tester.getRect(find.byType(UserMessageBubble));
      final Rect agentMessage = tester.getRect(find.byType(AgentMessageView));
      final Rect userCopy = tester.getRect(
        find.byKey(const ValueKey<String>('copy-message-1')),
      );
      final Rect agentCopy = tester.getRect(
        find.byKey(const ValueKey<String>('copy-message-2')),
      );
      final Rect userFork = tester.getRect(
        find.byKey(const ValueKey<String>('fork-message-1')),
      );
      final Rect agentFork = tester.getRect(
        find.byKey(const ValueKey<String>('fork-message-2')),
      );

      expect(userMessage.right, 390);
      expect(agentMessage.left, 0);
      // Actions stay toward the conversation's center instead of displacing
      // either bubble from its speaker's conventional outer edge.
      expect(userCopy.center.dx, lessThan(userMessage.left));
      expect(agentCopy.center.dx, greaterThan(agentMessage.right));
      expect(userCopy.center.dy, closeTo(userFork.center.dy, 0.1));
      expect(agentCopy.center.dy, closeTo(agentFork.center.dy, 0.1));
      expect(userFork.left, greaterThanOrEqualTo(userCopy.right));
      expect(agentFork.left, greaterThanOrEqualTo(agentCopy.right));
    });
  });

  testWidgets('actions adapt as bubbles wrap and grow', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final double width in <double>[240, 1440]) {
      tester.view.physicalSize = Size(width, 900);
      for (final String text in <String>[
        'Short message',
        'A message that wraps on the phone.',
        'First line\n\nSecond line\n\nThird line\n\nFourth line',
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildSpeedDialTheme(),
            home: Scaffold(
              body: Timeline(
                items: <TimelineItem>[
                  UserMessageItem(text: text, forkSeq: 1),
                  AgentMessageItem(text: text, forkSeq: 2),
                ],
                onFork: (_) {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final int seq in <int>[1, 2]) {
          final Rect copy = tester.getRect(
            find.byKey(ValueKey<String>('copy-message-$seq')),
          );
          final Rect fork = tester.getRect(
            find.byKey(ValueKey<String>('fork-message-$seq')),
          );
          final bool short =
              text == 'Short message' ||
              (!text.contains('\n') && width == 1440);
          if (short) {
            expect(
              copy.center.dy,
              closeTo(fork.center.dy, 0.1),
              reason: '$width / $seq / $text',
            );
            expect(fork.left, greaterThanOrEqualTo(copy.right));
          } else {
            expect(copy.center.dx, closeTo(fork.center.dx, 0.1));
            expect(fork.top, greaterThanOrEqualTo(copy.bottom));
          }
        }
        expect(tester.takeException(), isNull);
      }
    }
  });

  group('deriveTimelineItems active thought', () {
    test('trailing thought chunk is active while running', () {
      final List<TimelineItem> items = deriveTimelineItems(<SessionEvent>[
        const UserMessageEvent(text: 'hi'),
        const AgentThoughtChunkEvent(text: 'let me '),
        const AgentThoughtChunkEvent(text: 'think'),
      ], running: true);
      final AgentThoughtItem thought = items.last as AgentThoughtItem;
      expect(thought.text, 'let me think');
      expect(thought.active, isTrue);
    });

    test('trailing thought chunk is not active when not running', () {
      final List<TimelineItem> items = deriveTimelineItems(<SessionEvent>[
        const AgentThoughtChunkEvent(text: 'done'),
      ]);
      expect((items.single as AgentThoughtItem).active, isFalse);
    });

    test('thought closes once a message chunk follows', () {
      final List<TimelineItem> items = deriveTimelineItems(<SessionEvent>[
        const AgentThoughtChunkEvent(text: 'hmm'),
        const AgentMessageChunkEvent(text: 'answer'),
      ], running: true);
      final AgentThoughtItem thought = items
          .whereType<AgentThoughtItem>()
          .single;
      expect(thought.active, isFalse);
    });

    test('thought closes when the turn completes', () {
      final List<TimelineItem> items = deriveTimelineItems(
        <SessionEvent>[
          const AgentThoughtChunkEvent(text: 'hmm'),
          const TurnCompleteEvent(stopReason: 'end_turn'),
        ],
        // Status can lag the event stream by a frame; the trailing event
        // alone must settle the thought.
        running: true,
      );
      final AgentThoughtItem thought = items
          .whereType<AgentThoughtItem>()
          .single;
      expect(thought.active, isFalse);
    });
  });

  group('deriveTimelineItems provider activities', () {
    test('later snapshots replace the activity in place', () {
      final List<TimelineItem> items = deriveTimelineItems(<SessionEvent>[
        const AgentActivityEvent(
          activity: AgentActivity(
            id: 'warmup',
            kind: 'extensions',
            title: 'Warming extensions',
            status: AgentActivityStatus.running,
          ),
        ),
        const AgentMessageChunkEvent(text: 'answer '),
        const AgentActivityEvent(
          activity: AgentActivity(
            id: 'warmup',
            kind: 'extensions',
            title: 'Extensions ready',
            status: AgentActivityStatus.completed,
            details: <String>['4 tools registered'],
          ),
        ),
        const AgentMessageChunkEvent(text: 'continues'),
      ]);

      expect(items.whereType<AgentActivityItem>(), hasLength(1));
      final AgentActivity activity = items
          .whereType<AgentActivityItem>()
          .single
          .activity;
      expect(activity.title, 'Extensions ready');
      expect(activity.status, AgentActivityStatus.completed);
      expect(activity.details, ['4 tools registered']);
      final AgentMessageItem message = items
          .whereType<AgentMessageItem>()
          .single;
      expect(message.text, 'answer continues');
    });

    testWidgets(
      'flattens legacy Ante Agent progress into tagged top-level actions',
      (WidgetTester tester) async {
        const String intro = 'I’ll inspect the deployment workflow.';
        const String read =
            'Read(file_path="/workspace/.github/workflows/deploy.yml")';
        final List<TimelineItem> items = deriveTimelineItems(<SessionEvent>[
          const ToolCallEvent(
            toolCall: ToolCall(
              id: 'agent-1',
              title: 'Agent',
              kind: 'other',
              status: ToolCallStatus.running,
              content: <ToolCallContent>[],
              locations: <String>[],
              rawInput: <String, Object?>{
                'description': 'Trace the deployment graph',
                'subagent_type': 'explore',
              },
            ),
          ),
          const ToolCallEvent(
            toolCall: ToolCall(
              id: 'agent-1',
              title: 'Agent',
              kind: 'other',
              status: ToolCallStatus.running,
              content: <ToolCallContent>[ToolCallText(text: intro)],
              locations: <String>[],
            ),
          ),
          const ToolCallEvent(
            toolCall: ToolCall(
              id: 'agent-1',
              title: 'Agent',
              kind: 'other',
              status: ToolCallStatus.running,
              content: <ToolCallContent>[ToolCallText(text: '$intro\n$read')],
              locations: <String>[],
            ),
          ),
          const ToolCallEvent(
            toolCall: ToolCall(
              id: 'agent-1',
              title: 'Agent',
              kind: 'other',
              status: ToolCallStatus.completed,
              content: <ToolCallContent>[],
              locations: <String>[],
              rawOutput: <String, Object?>{
                'report': 'The workflow has three entry points.',
              },
            ),
          ),
        ]);

        expect(items.whereType<ToolCallTimelineItem>(), isEmpty);
        final List<AgentActivityItem> activities = items
            .whereType<AgentActivityItem>()
            .toList();
        expect(activities, hasLength(3));
        expect(activities.first.activity.status, AgentActivityStatus.completed);
        expect(
          activities.first.activity.details,
          contains('The workflow has three entry points.'),
        );

        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildSpeedDialTheme(),
            home: Scaffold(body: Timeline(items: items)),
          ),
        );

        expect(find.text('SUBAGENT'), findsNWidgets(3));
        expect(find.text('Trace the deployment graph'), findsOneWidget);
        expect(find.text(intro), findsOneWidget);
        expect(find.text('Read'), findsOneWidget);
        expect(
          find.text('file_path="/workspace/.github/workflows/deploy.yml"'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('deriveTimelineItems tool calls', () {
    testWidgets('message identity survives interleaved tool snapshots', (
      WidgetTester tester,
    ) async {
      final List<TimelineItem> items = deriveTimelineItems(const <SessionEvent>[
        AgentMessageChunkEvent(text: 'Stable ', messageId: 'message-1'),
        ToolCallEvent(
          toolCall: ToolCall(
            id: 'shell-1',
            title: 'Running tests',
            kind: 'execute',
            status: ToolCallStatus.running,
            content: <ToolCallContent>[],
            locations: <String>[],
          ),
        ),
        AgentMessageChunkEvent(text: 'across ', messageId: 'message-1'),
        ToolCallEvent(
          toolCall: ToolCall(
            id: 'shell-1',
            title: 'Running tests',
            kind: 'execute',
            status: ToolCallStatus.completed,
            content: <ToolCallContent>[],
            locations: <String>[],
          ),
        ),
        AgentMessageChunkEvent(text: 'snapshots.', messageId: 'message-1'),
      ]);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildSpeedDialTheme(),
          home: Scaffold(body: Timeline(items: items)),
        ),
      );

      expect(find.byType(AgentMessageView), findsOneWidget);
      expect(find.text('Stable across snapshots.'), findsOneWidget);
      expect(find.byType(ToolCallCard), findsOneWidget);
    });

    testWidgets('adjacent distinct message identities render separately', (
      WidgetTester tester,
    ) async {
      final List<TimelineItem> items = deriveTimelineItems(const <SessionEvent>[
        AgentMessageChunkEvent(text: 'First item', messageId: 'message-1'),
        AgentMessageChunkEvent(text: 'Second item', messageId: 'message-2'),
      ]);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildSpeedDialTheme(),
          home: Scaffold(body: Timeline(items: items)),
        ),
      );

      expect(find.byType(AgentMessageView), findsNWidgets(2));
      expect(find.text('First item'), findsOneWidget);
      expect(find.text('Second item'), findsOneWidget);
    });

    testWidgets('tool progress snapshots do not split one assistant message', (
      WidgetTester tester,
    ) async {
      const ToolCall running = ToolCall(
        id: 'shell-1',
        title: 'Running tests',
        kind: 'execute',
        status: ToolCallStatus.running,
        content: <ToolCallContent>[],
        locations: <String>[],
      );
      const ToolCall completed = ToolCall(
        id: 'shell-1',
        title: 'Running tests',
        kind: 'execute',
        status: ToolCallStatus.completed,
        content: <ToolCallContent>[],
        locations: <String>[],
      );
      final List<TimelineItem> items = deriveTimelineItems(const <SessionEvent>[
        ToolCallEvent(toolCall: running),
        AgentMessageChunkEvent(text: 'One response '),
        ToolCallEvent(toolCall: running),
        AgentMessageChunkEvent(text: 'across progress '),
        ToolCallEvent(toolCall: completed),
        AgentMessageChunkEvent(text: 'updates.'),
        TurnCompleteEvent(stopReason: 'end_turn'),
      ]);

      expect(items.whereType<ToolCallTimelineItem>(), hasLength(1));
      final AgentMessageItem message = items
          .whereType<AgentMessageItem>()
          .single;
      expect(message.text, 'One response across progress updates.');

      await tester.pumpWidget(
        MaterialApp(
          theme: buildSpeedDialTheme(),
          home: Scaffold(body: Timeline(items: items)),
        ),
      );

      expect(find.byType(AgentMessageView), findsOneWidget);
    });

    testWidgets('keeps later calls when a provider reuses a tool id', (
      WidgetTester tester,
    ) async {
      final List<TimelineItem> items = deriveTimelineItems(<SessionEvent>[
        const AgentMessageChunkEvent(text: 'First check:'),
        const ToolCallEvent(
          toolCall: ToolCall(
            id: 'reused-id',
            title: 'First grep',
            kind: 'search',
            status: ToolCallStatus.running,
            content: <ToolCallContent>[],
            locations: <String>[],
          ),
        ),
        const ToolCallEvent(
          toolCall: ToolCall(
            id: 'reused-id',
            title: 'First grep',
            kind: 'search',
            status: ToolCallStatus.completed,
            content: <ToolCallContent>[],
            locations: <String>[],
          ),
        ),
        const AgentMessageChunkEvent(text: 'Second check:'),
        const ToolCallEvent(
          toolCall: ToolCall(
            id: 'reused-id',
            title: 'Second grep',
            kind: 'search',
            status: ToolCallStatus.running,
            content: <ToolCallContent>[],
            locations: <String>[],
          ),
        ),
        const ToolCallEvent(
          toolCall: ToolCall(
            id: 'reused-id',
            title: 'Second grep',
            kind: 'search',
            status: ToolCallStatus.completed,
            content: <ToolCallContent>[],
            locations: <String>[],
          ),
        ),
      ]);

      expect(items.whereType<ToolCallTimelineItem>(), hasLength(2));
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSpeedDialTheme(),
          home: Scaffold(body: Timeline(items: items)),
        ),
      );

      expect(find.byType(ToolCallCard), findsNWidgets(2));
      expect(find.text('First grep'), findsOneWidget);
      expect(find.text('Second grep'), findsOneWidget);
    });
  });

  group('active action pulse', () {
    testWidgets('running tool call pulses and completed call is static', (
      WidgetTester tester,
    ) async {
      const ToolCall running = ToolCall(
        id: 'tool-1',
        title: 'Searching files',
        kind: 'search',
        status: ToolCallStatus.running,
        content: <ToolCallContent>[],
        locations: <String>[],
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSpeedDialTheme(),
          home: const Scaffold(body: ToolCallCard(toolCall: running)),
        ),
      );

      final Finder pulse = find.byKey(
        const ValueKey<String>('tool-pulse-tool-1'),
      );
      expect(pulse, findsNWidgets(2));
      expect(
        tester.widget<FadeTransition>(pulse.first).opacity.status,
        anyOf(AnimationStatus.forward, AnimationStatus.reverse),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildSpeedDialTheme(),
          home: const Scaffold(
            body: ToolCallCard(
              toolCall: ToolCall(
                id: 'tool-1',
                title: 'Searched files',
                kind: 'search',
                status: ToolCallStatus.completed,
                content: <ToolCallContent>[],
                locations: <String>[],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(pulse, findsNothing);
    });

    testWidgets('running activity pulses and completed activity is static', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSpeedDialTheme(),
          home: const Scaffold(
            body: Timeline(
              items: <TimelineItem>[
                AgentActivityItem(
                  activity: AgentActivity(
                    id: 'warmup',
                    kind: 'extensions',
                    title: 'Warming extensions',
                    status: AgentActivityStatus.running,
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      final Finder pulse = find.byKey(
        const ValueKey<String>('activity-pulse-warmup'),
      );
      expect(pulse, findsNWidgets(2));
      expect(
        tester.widget<FadeTransition>(pulse.first).opacity.status,
        anyOf(AnimationStatus.forward, AnimationStatus.reverse),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildSpeedDialTheme(),
          home: const Scaffold(
            body: Timeline(
              items: <TimelineItem>[
                AgentActivityItem(
                  activity: AgentActivity(
                    id: 'warmup',
                    kind: 'extensions',
                    title: 'Extensions ready',
                    status: AgentActivityStatus.completed,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      expect(pulse, findsNothing);
    });
  });

  group('lazy history', () {
    testWidgets('requests older history when the first page underfills', (
      WidgetTester tester,
    ) async {
      int loads = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSpeedDialTheme(),
          home: Scaffold(
            body: Timeline(
              hasOlder: true,
              onLoadOlder: () => loads++,
              items: const <TimelineItem>[
                AgentMessageItem(text: 'partial latest response'),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      expect(loads, 1);
    });

    testWidgets('requests older history near the top edge', (
      WidgetTester tester,
    ) async {
      int loads = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSpeedDialTheme(),
          home: Scaffold(
            body: Timeline(
              hasOlder: true,
              onLoadOlder: () => loads++,
              items: <TimelineItem>[
                for (var i = 0; i < 80; i++)
                  UserMessageItem(text: 'message $i'),
              ],
            ),
          ),
        ),
      );

      final ScrollableState scrollable = tester.state(
        find.descendant(
          of: find.byKey(const Key('chat-timeline')),
          matching: find.byType(Scrollable),
        ),
      );
      scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
      await tester.pump();

      expect(loads, 1);
    });
  });

  testWidgets('collapsing a large history item keeps the timeline visible', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSpeedDialTheme(),
        home: Scaffold(
          body: Timeline(
            items: <TimelineItem>[
              AgentThoughtItem(
                text: List<String>.filled(500, 'long thought').join('\n'),
              ),
              const UserMessageItem(text: 'Latest message'),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.text('Thought'));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(AgentThoughtView)).height,
      greaterThan(500),
    );
    final ScrollController controller = tester
        .widget<CustomScrollView>(find.byKey(const Key('chat-timeline')))
        .controller!;
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    await tester.tap(find.text('Thought'));
    await tester.pump();
    expect(tester.getSize(find.byType(AgentThoughtView)).height, lessThan(100));
    await tester.pumpAndSettle();

    expect(
      controller.position.pixels,
      lessThanOrEqualTo(controller.position.maxScrollExtent),
    );
    expect(
      tester
          .getRect(find.text('Thought'))
          .overlaps(tester.getRect(find.byKey(const Key('chat-timeline')))),
      isTrue,
    );
  });

  testWidgets('collapsing a large tool call removes its height immediately', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSpeedDialTheme(),
        home: Scaffold(
          body: Timeline(
            items: <TimelineItem>[
              ToolCallTimelineItem(
                toolCall: ToolCall(
                  id: 'large-output',
                  title: 'Long command',
                  kind: 'execute',
                  status: ToolCallStatus.completed,
                  content: <ToolCallContent>[
                    ToolCallText(
                      text: List<String>.filled(500, 'output line').join('\n'),
                    ),
                  ],
                  locations: const <String>[],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.text('Long command'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(ToolCallCard)).height, greaterThan(500));
    await tester.ensureVisible(find.text('Long command'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Long command'));
    await tester.pump();
    expect(tester.getSize(find.byType(ToolCallCard)).height, lessThan(100));
    await tester.pumpAndSettle();
  });

  testWidgets('collapsing a large activity removes its height immediately', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSpeedDialTheme(),
        home: Scaffold(
          body: Timeline(
            items: <TimelineItem>[
              AgentActivityItem(
                activity: AgentActivity(
                  id: 'large-activity',
                  kind: 'info',
                  title: 'Long activity',
                  status: AgentActivityStatus.completed,
                  details: <String>[
                    List<String>.filled(500, 'activity detail').join('\n'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.text('Long activity'));
    await tester.pumpAndSettle();
    final Finder tile = find.byKey(
      const ValueKey<String>('activity-large-activity'),
    );
    expect(tester.getSize(tile).height, greaterThan(500));
    await tester.ensureVisible(find.text('Long activity'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Long activity'));
    await tester.pump();
    expect(tester.getSize(tile).height, lessThan(100));
  });

  testWidgets('short thought and tool details still collapse with animation', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSpeedDialTheme(),
        home: Scaffold(
          body: Timeline(
            items: <TimelineItem>[
              AgentThoughtItem(
                text: List<String>.filled(10, 'short thought').join('\n'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('Thought'));
    await tester.pumpAndSettle();
    final double expandedThought = tester
        .getSize(find.byType(AgentThoughtView))
        .height;
    await tester.tap(find.text('Thought'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      tester.getSize(find.byType(AgentThoughtView)).height,
      inInclusiveRange(100, expandedThought),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(AgentThoughtView)).height, lessThan(100));

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSpeedDialTheme(),
        home: Scaffold(
          body: Timeline(
            items: <TimelineItem>[
              ToolCallTimelineItem(
                toolCall: ToolCall(
                  id: 'short-output',
                  title: 'Short command',
                  kind: 'execute',
                  status: ToolCallStatus.completed,
                  content: <ToolCallContent>[
                    ToolCallText(
                      text: List<String>.filled(8, 'output line').join('\n'),
                    ),
                  ],
                  locations: const <String>[],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('Short command'));
    await tester.pumpAndSettle();
    final double expandedTool = tester
        .getSize(find.byType(ToolCallCard))
        .height;
    await tester.tap(find.text('Short command'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      tester.getSize(find.byType(ToolCallCard)).height,
      inInclusiveRange(100, expandedTool),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(ToolCallCard)).height, lessThan(100));
  });

  testWidgets('a large running tool releases its height when it completes', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final String output = List<String>.filled(500, 'output line').join('\n');
    Widget card(ToolCallStatus status, String text) => MaterialApp(
      theme: buildSpeedDialTheme(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: ToolCallCard(
            toolCall: ToolCall(
              id: 'running-output',
              title: 'Long command',
              kind: 'execute',
              status: status,
              content: <ToolCallContent>[ToolCallText(text: text)],
              locations: const <String>[],
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(card(ToolCallStatus.running, output));
    expect(tester.getSize(find.byType(ToolCallCard)).height, greaterThan(500));
    await tester.pumpWidget(card(ToolCallStatus.completed, output));
    expect(tester.getSize(find.byType(ToolCallCard)).height, lessThan(100));

    await tester.pumpWidget(card(ToolCallStatus.running, 'Working'));
    await tester.pumpWidget(card(ToolCallStatus.completed, output));
    expect(tester.getSize(find.byType(ToolCallCard)).height, lessThan(100));
  });

  group('tool call details', () {
    testWidgets(
      "titles a shell call with the agent's description over its command",
      (WidgetTester tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildSpeedDialTheme(),
            home: const Scaffold(
              body: SizedBox(
                width: 600,
                child: ToolCallCard(
                  toolCall: ToolCall(
                    id: 'bash-1',
                    title: 'Bash',
                    kind: 'execute',
                    status: ToolCallStatus.completed,
                    content: <ToolCallContent>[],
                    locations: <String>[],
                    rawInput: <String, Object?>{
                      'command': 'git status --short',
                      'description': 'Shows working tree status',
                    },
                    rawOutput: <String, Object?>{
                      'Completed': <String, Object?>{
                        'exit_code': 0,
                        'stdout': ' M lib/main.dart',
                      },
                    },
                  ),
                ),
              ),
            ),
          ),
        );

        expect(find.text('Shows working tree status'), findsOneWidget);
        expect(find.text('git status --short'), findsOneWidget);
        expect(find.text('Bash'), findsNothing);

        await tester.tap(find.text('git status --short'));
        await tester.pumpAndSettle();

        expect(find.text('Input'), findsOneWidget);
        expect(find.text('Output'), findsOneWidget);
        expect(find.textContaining('git status --short'), findsWidgets);
        expect(find.textContaining('M lib/main.dart'), findsOneWidget);
        expect(find.text('No output'), findsNothing);
      },
    );

    testWidgets('accepts argv-style cmd input and falls back to the title', (
      WidgetTester tester,
    ) async {
      Future<void> pump(ToolCall toolCall) => tester.pumpWidget(
        MaterialApp(
          theme: buildSpeedDialTheme(),
          home: Scaffold(
            body: SizedBox(width: 600, child: ToolCallCard(toolCall: toolCall)),
          ),
        ),
      );

      await pump(
        const ToolCall(
          id: 'shell-1',
          title: 'Shell',
          kind: 'execute',
          status: ToolCallStatus.completed,
          content: <ToolCallContent>[],
          locations: <String>[],
          rawInput: <String, Object?>{
            'cmd': <Object?>['dart', 'test'],
          },
        ),
      );
      expect(find.text('dart test'), findsOneWidget);
      expect(find.text('Shell'), findsNothing);

      await pump(
        const ToolCall(
          id: 'shell-2',
          title: 'Bash',
          kind: 'execute',
          status: ToolCallStatus.completed,
          content: <ToolCallContent>[],
          locations: <String>[],
        ),
      );
      expect(find.text('Bash'), findsOneWidget);
    });

    testWidgets('loads and renders attachment-backed image output', (
      WidgetTester tester,
    ) async {
      const String imageData =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhf'
          'DwAChwGA60e6kgAAAABJRU5ErkJggg==';
      const Attachment attachment = Attachment(
        id: 'tool-image-1',
        name: 'sheet.png',
        mimeType: 'image/png',
        size: 70,
      );
      String? loadedId;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSpeedDialTheme(),
          home: Scaffold(
            body: Timeline(
              items: const <TimelineItem>[
                ToolCallTimelineItem(
                  toolCall: ToolCall(
                    id: 'view-1',
                    title: 'View sheet screenshot',
                    kind: 'read',
                    status: ToolCallStatus.completed,
                    content: <ToolCallContent>[
                      ToolCallText(text: 'Read image file [image/png]'),
                      ToolCallImage(attachment: attachment),
                    ],
                    locations: <String>['sheet.png'],
                  ),
                ),
              ],
              attachmentLoader: (String attachmentId) async {
                loadedId = attachmentId;
                return AttachmentData(
                  id: attachment.id,
                  name: attachment.name,
                  mimeType: attachment.mimeType,
                  size: base64Decode(imageData).length,
                  data: imageData,
                );
              },
            ),
          ),
        ),
      );

      expect(loadedId, isNull);
      await tester.tap(find.text('View sheet screenshot'));
      await tester.pumpAndSettle();

      expect(loadedId, attachment.id);
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('Read image file [image/png]'), findsOneWidget);
    });
    testWidgets('bounds oversized raw output before text layout', (
      WidgetTester tester,
    ) async {
      final String payload = 'A' * 50000;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSpeedDialTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 600,
              child: ToolCallCard(
                toolCall: ToolCall(
                  id: 'read-image',
                  title: 'Read image',
                  kind: 'read',
                  status: ToolCallStatus.completed,
                  content: const <ToolCallContent>[],
                  locations: const <String>[],
                  rawOutput: <String, Object?>{'data': payload},
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Read image'));
      await tester.pumpAndSettle();

      expect(find.textContaining('characters omitted'), findsOneWidget);
      expect(find.text(payload), findsNothing);
    });
  });

  group('tool call native patches', () {
    testWidgets('renders an Ante Edit result as a diff on a narrow screen', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSpeedDialTheme(),
          home: const Scaffold(
            body: ToolCallCard(
              toolCall: ToolCall(
                id: 'ante-edit',
                title: 'Edit',
                kind: 'edit',
                status: ToolCallStatus.completed,
                content: <ToolCallContent>[],
                locations: <String>['crates/agent-host/src/config.rs'],
                rawInput: <String, Object?>{
                  'file_path':
                      '/home/nigel/r/project/crates/agent-host/src/config.rs',
                },
                rawOutput: <String, Object?>{
                  'patch': <String, Object?>{
                    'hunks': <Object?>[
                      <String, Object?>{
                        'old_start': 30,
                        'new_start': 30,
                        'lines': <String>[
                          ' /// Existing comment',
                          '-let old_value = 1;',
                          '+let new_value = 2;',
                        ],
                      },
                    ],
                  },
                },
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();

      expect(find.text('Input'), findsNothing);
      expect(find.text('Output'), findsNothing);
      expect(find.textContaining('+1 -1', findRichText: true), findsOneWidget);
      expect(
        find.textContaining('- let old_value = 1;', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('+ let new_value = 2;', findRichText: true),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders a provider-native unified diff', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSpeedDialTheme(),
          home: const Scaffold(
            body: SizedBox(
              width: 600,
              child: ToolCallCard(
                toolCall: ToolCall(
                  id: 'patch-1',
                  title: 'Applied patch',
                  kind: 'edit',
                  status: ToolCallStatus.completed,
                  content: <ToolCallContent>[
                    ToolCallPatch(
                      path: 'lib/src/native.dart',
                      diff: '@@ -1 +1 @@\n-old line\n+new line',
                    ),
                  ],
                  locations: <String>['lib/src/native.dart'],
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Applied patch'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('lib/src/native.dart', findRichText: true),
        findsWidgets,
      );
      expect(
        find.textContaining('-old line', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('+new line', findRichText: true),
        findsOneWidget,
      );
    });
  });

  group('deriveTimelineItems user attachments', () {
    test('attachment metadata carries into the user message item', () {
      final List<TimelineItem> items = deriveTimelineItems(<SessionEvent>[
        const UserMessageEvent(
          text: 'files',
          attachments: <Attachment>[
            Attachment(
              id: 'att-1',
              name: 'shot.png',
              mimeType: 'image/png',
              size: 5,
            ),
            Attachment(
              id: 'att-2',
              name: 'notes.txt',
              mimeType: 'text/plain',
              size: 2,
            ),
          ],
        ),
      ]);
      final UserMessageItem item = items.single as UserMessageItem;
      expect(item.text, 'files');
      expect(item.attachments, hasLength(2));
      expect(item.attachments.map((Attachment a) => a.id), <String>[
        'att-1',
        'att-2',
      ]);
    });
  });

  group('turn oven', () {
    const List<TimelineItem> asked = <TimelineItem>[
      UserMessageItem(text: 'go', forkSeq: 7),
    ];
    const List<TimelineItem> answering = <TimelineItem>[
      UserMessageItem(text: 'go', forkSeq: 7),
      AgentThoughtItem(text: 'hmm', active: true),
    ];

    test('heat follows the turn from send to output to waiting', () {
      expect(turnHeatFor(SessionStatus.idle, asked), TurnHeat.off);
      expect(
        turnHeatFor(SessionStatus.idle, asked, sending: true),
        TurnHeat.preheating,
      );
      expect(turnHeatFor(SessionStatus.running, asked), TurnHeat.preheating);
      expect(turnHeatFor(SessionStatus.running, answering), TurnHeat.cooking);
      expect(
        turnHeatFor(SessionStatus.waitingPermission, answering),
        TurnHeat.keepingWarm,
      );
      expect(turnHeatFor(SessionStatus.error, answering), TurnHeat.off);
    });

    test('a turn keeps one cooking verb, chosen by its message', () {
      expect(latestTurnSeed(answering), 7);
      expect(latestTurnSeed(const <TimelineItem>[]), 0);
      final String label = turnHeatLabel(TurnHeat.cooking, 7);
      expect(label, endsWith('…'));
      expect(turnHeatLabel(TurnHeat.cooking, 7), label);
      expect(turnHeatLabel(TurnHeat.cooking, 8), isNot(label));
      expect(turnHeatLabel(TurnHeat.preheating, 7), 'Preheating…');
      expect(turnHeatLabel(TurnHeat.keepingWarm, 7), 'Keeping warm…');
    });

    testWidgets('a delivered message pops once, not again on rebuild', (
      WidgetTester tester,
    ) async {
      Widget timeline(int revision) => MaterialApp(
        theme: buildSpeedDialTheme(),
        home: Scaffold(
          body: Timeline(
            key: const ValueKey<String>('timeline'),
            items: <TimelineItem>[
              const UserMessageItem(text: 'fresh', forkSeq: 3),
              AgentMessageItem(text: 'reply $revision', forkSeq: 4),
            ],
            delivered: const <int>{3},
          ),
        ),
      );
      double scale() => tester
          .widget<ScaleTransition>(
            find.descendant(
              of: find.byKey(const Key('delivered-pop')),
              matching: find.byType(ScaleTransition),
            ),
          )
          .scale
          .value;

      await tester.pumpWidget(timeline(0));
      await tester.pump(const Duration(milliseconds: 80));
      expect(scale(), isNot(1));

      await tester.pumpAndSettle();
      expect(scale(), 1);
      await tester.pumpWidget(timeline(1));
      await tester.pump(const Duration(milliseconds: 80));
      expect(scale(), 1);
    });
  });

  group('tool approvals', () {
    const PermissionRequest request = PermissionRequest(
      requestId: 'req-1',
      toolCallId: 'tool-1',
      title: 'git push',
      options: <PermissionOption>[
        PermissionOption(
          optionId: 'allow-once',
          name: 'Yes',
          kind: PermissionKind.allowOnce,
        ),
        PermissionOption(
          optionId: 'reject',
          name: 'No',
          kind: PermissionKind.rejectOnce,
        ),
      ],
    );
    const ToolCall push = ToolCall(
      id: 'tool-1',
      title: 'git push',
      kind: 'execute',
      status: ToolCallStatus.completed,
      content: <ToolCallContent>[],
      locations: <String>[],
    );

    test('a request settles into the tool call it gates', () {
      final List<TimelineItem> items = deriveTimelineItems(<SessionEvent>[
        const UserMessageEvent(text: 'Push it', seq: 1),
        const ToolCallEvent(toolCall: push, seq: 2),
        const PermissionRequestEvent(request: request, seq: 3),
        const PermissionResolvedEvent(
          requestId: 'req-1',
          optionId: 'allow-once',
          seq: 4,
        ),
      ]);
      expect(items.whereType<PermissionRequestItem>(), isEmpty);
      expect(items.whereType<PermissionResolvedItem>(), isEmpty);
      final ToolApproval? approval = items
          .whereType<ToolCallTimelineItem>()
          .single
          .approval;
      expect(approval?.state, ToolApprovalState.allowed);
      expect(approval?.choice, 'Yes');

      final List<TimelineItem> waiting = deriveTimelineItems(<SessionEvent>[
        const ToolCallEvent(toolCall: push, seq: 2),
        const PermissionRequestEvent(request: request, seq: 3),
      ]);
      expect(waiting, hasLength(1));
      expect(
        (waiting.single as ToolCallTimelineItem).approval?.state,
        ToolApprovalState.pending,
      );
    });

    test('other requests keep one row that carries their answer', () {
      final List<TimelineItem> items = deriveTimelineItems(<SessionEvent>[
        const PermissionRequestEvent(
          request: PermissionRequest(
            requestId: 'req-2',
            toolCallId: null,
            title: 'Allow network access?',
            options: <PermissionOption>[
              PermissionOption(
                optionId: 'allow-once',
                name: 'Yes',
                kind: PermissionKind.allowOnce,
              ),
            ],
          ),
          seq: 1,
        ),
        const PermissionResolvedEvent(
          requestId: 'req-2',
          optionId: 'allow-once',
          seq: 2,
        ),
        // Its request is on an older page: the answer still shows.
        const PermissionResolvedEvent(
          requestId: 'older',
          optionId: 'reject',
          seq: 3,
        ),
      ]);
      expect(
        items.whereType<PermissionRequestItem>().single.answer,
        'allow-once',
      );
      expect(
        items.whereType<PermissionResolvedItem>().single.requestId,
        'older',
      );
    });

    testWidgets('the tool row flags what needs a glance', (tester) async {
      Future<void> pump(ToolApproval approval) => tester.pumpWidget(
        MaterialApp(
          theme: buildSpeedDialTheme(),
          home: Scaffold(
            body: ToolCallCard(toolCall: push, approval: approval),
          ),
        ),
      );

      await pump(const ToolApproval(ToolApprovalState.pending));
      expect(find.text('Needs approval'), findsOneWidget);
      await pump(const ToolApproval(ToolApprovalState.denied, choice: 'No'));
      expect(find.text('Denied'), findsOneWidget);

      // An approval goes unflagged on the row; its details tell the choice.
      await pump(
        const ToolApproval(
          ToolApprovalState.allowed,
          choice: "Yes, and don't ask again",
        ),
      );
      expect(find.text('Denied'), findsNothing);
      expect(find.text('Needs approval'), findsNothing);
      await tester.tap(find.text('git push'));
      await tester.pumpAndSettle();
      expect(
        find.text("Approved · Yes, and don't ask again").hitTestable(),
        findsOneWidget,
      );
    });
  });
}
