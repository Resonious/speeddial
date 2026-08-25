import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/state/session_timeline.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

void main() {
  group('foldSessionEvents', () {
    test('folds identified messages across interleaved snapshots', () {
      const ToolCall runningTool = ToolCall(
        id: 'tool-1',
        title: 'Inspect',
        kind: 'read',
        status: ToolCallStatus.running,
        content: <ToolCallContent>[],
        locations: <String>[],
      );
      const ToolCall completedTool = ToolCall(
        id: 'tool-1',
        title: 'Inspect',
        kind: 'read',
        status: ToolCallStatus.completed,
        content: <ToolCallContent>[],
        locations: <String>[],
      );
      final List<FoldedSessionEntry> entries = foldSessionEvents(
        const <SessionEvent>[
          UserMessageEvent(text: 'What happened?'),
          AgentMessageChunkEvent(
            text: 'One response ',
            messageId: 'message-1',
            seq: 2,
          ),
          ToolCallEvent(toolCall: runningTool),
          AgentActivityEvent(
            activity: AgentActivity(
              id: 'activity-1',
              kind: 'mcp',
              title: 'Connecting',
              status: AgentActivityStatus.running,
            ),
          ),
          AgentMessageChunkEvent(
            text: 'across ',
            messageId: 'message-1',
            seq: 5,
          ),
          ToolCallEvent(toolCall: completedTool),
          AgentActivityEvent(
            activity: AgentActivity(
              id: 'activity-1',
              kind: 'mcp',
              title: 'Connected',
              status: AgentActivityStatus.completed,
            ),
          ),
          AgentMessageChunkEvent(
            text: 'updates.',
            messageId: 'message-1',
            seq: 8,
          ),
          TurnCompleteEvent(stopReason: 'end_turn'),
        ],
      );

      final FoldedAgentMessage message = entries
          .whereType<FoldedAgentMessage>()
          .single;
      expect(message.text, 'One response across updates.');
      expect(message.messageId, 'message-1');
      expect(message.seq, 8);

      final FoldedToolCall tool = entries.whereType<FoldedToolCall>().single;
      expect(tool.snapshots, <ToolCall>[runningTool, completedTool]);
      expect(tool.latest.status, ToolCallStatus.completed);

      final AgentActivity activity = entries
          .whereType<FoldedAgentActivity>()
          .single
          .activity;
      expect(activity.title, 'Connected');
      expect(activity.status, AgentActivityStatus.completed);
    });

    test('keeps distinct adjacent message identities separate', () {
      final List<FoldedAgentMessage> messages = foldSessionEvents(
        const <SessionEvent>[
          AgentMessageChunkEvent(text: 'First', messageId: 'message-1'),
          AgentMessageChunkEvent(text: 'Second', messageId: 'message-2'),
        ],
      ).whereType<FoldedAgentMessage>().toList();

      expect(messages.map((FoldedAgentMessage item) => item.text), <String>[
        'First',
        'Second',
      ]);
    });

    test('scopes provider identities to one turn', () {
      final List<FoldedAgentMessage> messages = foldSessionEvents(
        const <SessionEvent>[
          UserMessageEvent(text: 'First turn'),
          AgentMessageChunkEvent(text: 'First answer', messageId: 'm1'),
          TurnCompleteEvent(stopReason: 'end_turn'),
          UserMessageEvent(text: 'Second turn'),
          AgentMessageChunkEvent(text: 'Second answer', messageId: 'm1'),
          TurnCompleteEvent(stopReason: 'end_turn'),
        ],
      ).whereType<FoldedAgentMessage>().toList();

      expect(messages, hasLength(2));
      expect(messages.first.text, 'First answer');
      expect(messages.last.text, 'Second answer');
    });

    test('keeps legacy chunks together across replacement snapshots', () {
      final List<FoldedSessionEntry> entries = foldSessionEvents(
        const <SessionEvent>[
          ToolCallEvent(
            toolCall: ToolCall(
              id: 'tool-1',
              title: 'Run',
              kind: 'execute',
              status: ToolCallStatus.running,
              content: <ToolCallContent>[],
              locations: <String>[],
            ),
          ),
          AgentMessageChunkEvent(text: 'Legacy '),
          AgentMessageChunkEvent(text: 'message '),
          ToolCallEvent(
            toolCall: ToolCall(
              id: 'tool-1',
              title: 'Run',
              kind: 'execute',
              status: ToolCallStatus.completed,
              content: <ToolCallContent>[],
              locations: <String>[],
            ),
          ),
          AgentMessageChunkEvent(text: 'continues.'),
        ],
      );

      expect(
        entries.whereType<FoldedAgentMessage>().single.text,
        'Legacy message continues.',
      );
      expect(entries.whereType<FoldedToolCall>(), hasLength(1));
    });

    test('starts a new tool generation when a terminal id is reused', () {
      final List<FoldedToolCall> tools = foldSessionEvents(const <SessionEvent>[
        ToolCallEvent(
          toolCall: ToolCall(
            id: 'reused',
            title: 'First',
            kind: 'search',
            status: ToolCallStatus.completed,
            content: <ToolCallContent>[],
            locations: <String>[],
          ),
        ),
        ToolCallEvent(
          toolCall: ToolCall(
            id: 'reused',
            title: 'Second',
            kind: 'search',
            status: ToolCallStatus.running,
            content: <ToolCallContent>[],
            locations: <String>[],
          ),
        ),
      ]).whereType<FoldedToolCall>().toList();

      expect(tools, hasLength(2));
      expect(tools.first.latest.title, 'First');
      expect(tools.last.latest.title, 'Second');
    });
  });
}
