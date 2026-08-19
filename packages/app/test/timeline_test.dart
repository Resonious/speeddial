import 'package:flutter_test/flutter_test.dart';

import 'package:speeddial_app/src/ui/chat/timeline.dart';

import 'package:speeddial_protocol/speeddial_protocol.dart';

void main() {
  group('deriveTimelineItems active thought', () {
    test('trailing thought chunk is active while running', () {
      final List<TimelineItem> items = deriveTimelineItems(
        <SessionEvent>[
          const UserMessageEvent(text: 'hi'),
          const AgentThoughtChunkEvent(text: 'let me '),
          const AgentThoughtChunkEvent(text: 'think'),
        ],
        running: true,
      );
      final AgentThoughtItem thought = items.last as AgentThoughtItem;
      expect(thought.text, 'let me think');
      expect(thought.active, isTrue);
    });

    test('trailing thought chunk is not active when not running', () {
      final List<TimelineItem> items = deriveTimelineItems(
        <SessionEvent>[const AgentThoughtChunkEvent(text: 'done')],
      );
      expect((items.single as AgentThoughtItem).active, isFalse);
    });

    test('thought closes once a message chunk follows', () {
      final List<TimelineItem> items = deriveTimelineItems(
        <SessionEvent>[
          const AgentThoughtChunkEvent(text: 'hmm'),
          const AgentMessageChunkEvent(text: 'answer'),
        ],
        running: true,
      );
      final AgentThoughtItem thought =
          items.whereType<AgentThoughtItem>().single;
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
      final AgentThoughtItem thought =
          items.whereType<AgentThoughtItem>().single;
      expect(thought.active, isFalse);
    });
  });

  group('deriveTimelineItems user attachments', () {
    test('attachment metadata carries into the user message item', () {
      final List<TimelineItem> items = deriveTimelineItems(
        <SessionEvent>[
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
        ],
      );
      final UserMessageItem item = items.single as UserMessageItem;
      expect(item.text, 'files');
      expect(item.attachments, hasLength(2));
      expect(item.attachments.map((Attachment a) => a.id),
          <String>['att-1', 'att-2']);
    });
  });
}
