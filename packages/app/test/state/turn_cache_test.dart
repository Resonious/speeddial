import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/state/turn_cache.dart';
import 'package:speeddial_app/src/ui/chat/timeline.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

void main() {
  test('streaming does not revisit completed history', () {
    int visited = 0;
    final TurnCache<TimelineItem> cache = TurnCache<TimelineItem>((
      events,
      running,
    ) {
      visited += events.length;
      return deriveTimelineItems(events, running: running);
    });
    final List<SessionEvent> events = <SessionEvent>[
      for (int i = 0; i < 1000; i++) ...<SessionEvent>[
        UserMessageEvent(text: 'question $i'),
        AgentMessageChunkEvent(text: 'answer $i', messageId: 'same-id'),
        TurnCompleteEvent(stopReason: 'end_turn'),
      ],
      UserMessageEvent(text: 'new question'),
      AgentMessageChunkEvent(text: 'a', messageId: 'same-id'),
    ];
    final List<TimelineItem> first = cache.update(events, running: true);
    final TimelineItem firstRow = first.first;
    visited = 0;
    events[events.length - 1] = AgentMessageChunkEvent(
      text: 'abc',
      messageId: 'same-id',
    );
    final List<TimelineItem> next = cache.update(events, running: true);
    expect(visited, 2);
    expect(identical(firstRow, next.first), isTrue);
    expect((next.last as AgentMessageItem).text, 'abc');
    expect((next.last as AgentMessageItem).streaming, isTrue);
    expect((next[1] as AgentMessageItem).streaming, isFalse);
    expect(next.length, 3002);
    events.add(TurnCompleteEvent(stopReason: 'end_turn'));
    final List<TimelineItem> done = cache.update(events);
    expect((done[done.length - 2] as AgentMessageItem).streaming, isFalse);
    expect(() => done.clear(), throwsUnsupportedError);
    expect(first.length, 3002);
    expect((first.last as AgentMessageItem).text, 'a');
  });

  test('prepend, refetch, and empty history discard stale cached turns', () {
    final TurnCache<TimelineItem> cache = TurnCache<TimelineItem>(
      (events, running) => deriveTimelineItems(events, running: running),
    );
    final List<SessionEvent> events = <SessionEvent>[
      UserMessageEvent(text: 'recent'),
      TurnCompleteEvent(stopReason: 'end_turn'),
    ];
    cache.update(events);
    events.insertAll(0, <SessionEvent>[
      UserMessageEvent(text: 'older'),
      TurnCompleteEvent(stopReason: 'end_turn'),
    ]);
    expect(
      cache.update(events).whereType<UserMessageItem>().map((e) => e.text),
      <String>['older', 'recent'],
    );
    expect(
      cache
          .update(<SessionEvent>[UserMessageEvent(text: 'refetched')])
          .whereType<UserMessageItem>()
          .single
          .text,
      'refetched',
    );
    expect(cache.update(<SessionEvent>[]), isEmpty);
  });

  test(
    'a new user message seals an interrupted turn and resets message IDs',
    () {
      final TurnCache<TimelineItem> cache = TurnCache<TimelineItem>(
        (events, running) => deriveTimelineItems(events, running: running),
      );
      final List<SessionEvent> events = <SessionEvent>[
        AgentMessageChunkEvent(text: 'old', messageId: 'id'),
      ];
      cache.update(events, running: true);
      events.addAll(<SessionEvent>[
        UserMessageEvent(text: 'next'),
        AgentMessageChunkEvent(text: 'new', messageId: 'id'),
      ]);
      final List<AgentMessageItem> messages = cache
          .update(events, running: true)
          .whereType<AgentMessageItem>()
          .toList();
      expect(messages.map((e) => e.text), <String>['old', 'new']);
      expect(messages.map((e) => e.streaming), <bool>[false, true]);
    },
  );
}
