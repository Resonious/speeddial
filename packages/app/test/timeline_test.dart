import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/chat/message_view.dart';
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
      expect(userCopy.center.dx, closeTo(userFork.center.dx, 0.1));
      expect(agentCopy.center.dx, closeTo(agentFork.center.dx, 0.1));
      expect(userFork.top, greaterThanOrEqualTo(userCopy.bottom));
      expect(agentFork.top, greaterThanOrEqualTo(agentCopy.bottom));
    });
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
        const AgentMessageChunkEvent(text: 'answer'),
        const AgentActivityEvent(
          activity: AgentActivity(
            id: 'warmup',
            kind: 'extensions',
            title: 'Extensions ready',
            status: AgentActivityStatus.completed,
            details: <String>['4 tools registered'],
          ),
        ),
      ]);

      expect(items.whereType<AgentActivityItem>(), hasLength(1));
      final AgentActivity activity = items
          .whereType<AgentActivityItem>()
          .single
          .activity;
      expect(activity.title, 'Extensions ready');
      expect(activity.status, AgentActivityStatus.completed);
      expect(activity.details, ['4 tools registered']);
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

  group('tool call details', () {
    testWidgets(
      'uses the execute command as the heading and renders raw details',
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
}
