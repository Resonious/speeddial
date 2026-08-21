import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/chat/timeline.dart';
import 'package:speeddial_app/src/ui/chat/tool_call_card.dart';

import 'package:speeddial_protocol/speeddial_protocol.dart';

void main() {
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
