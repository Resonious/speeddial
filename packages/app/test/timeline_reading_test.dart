import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/chat/timeline.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

void main() {
  Widget app(List<TimelineItem> items) => MaterialApp(
    theme: buildSpeedDialTheme(),
    home: Scaffold(body: Timeline(items: items)),
  );
  ToolCallTimelineItem tool(ToolCallStatus status) => ToolCallTimelineItem(
    id: 'tool',
    toolCall: ToolCall(
      id: 'tool',
      locations: const <String>[],
      title: 'Read a file',
      kind: 'read',
      status: status,
      content: const <ToolCallContent>[ToolCallText(text: 'Details to read')],
    ),
  );
  testWidgets('expanded card and reading position survive incoming events', (
    tester,
  ) async {
    final List<TimelineItem> items = <TimelineItem>[
      for (int i = 0; i < 30; i++) UserMessageItem(id: i, text: 'Message $i'),
      tool(ToolCallStatus.completed),
      const UserMessageItem(id: 30, text: 'After tool'),
    ];
    await tester.pumpWidget(app(items));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Read a file'));
    await tester.pumpAndSettle();
    final Offset before = tester.getTopLeft(find.text('Details to read'));
    await tester.pumpWidget(
      app(<TimelineItem>[
        ...items,
        const UserMessageItem(id: 'new', text: 'New event'),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.text('Details to read').hitTestable(), findsOneWidget);
    expect(tester.getTopLeft(find.text('Details to read')), before);
    expect(find.byTooltip('Jump to latest event'), findsOneWidget);
    await tester.tap(find.byTooltip('Jump to latest event'));
    await tester.pumpAndSettle();
    expect(find.text('New event').hitTestable(), findsOneWidget);
    expect(find.byTooltip('Jump to latest event'), findsNothing);
  });
  testWidgets('scrolling up holds position through chunks and history paging', (
    tester,
  ) async {
    List<TimelineItem> items = <TimelineItem>[
      for (int i = 10; i < 60; i++) UserMessageItem(id: i, text: 'Message $i'),
      const AgentMessageItem(id: 'stream', text: 'Starting'),
    ];
    await tester.pumpWidget(app(items));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const Key('chat-timeline')),
      const Offset(0, 350),
    );
    await tester.pumpAndSettle();
    final Finder visibleMessage = find
        .byWidgetPredicate(
          (Widget w) => w is Text && (w.data?.startsWith('Message ') ?? false),
        )
        .hitTestable()
        .first;
    final Finder anchor = find.text(tester.widget<Text>(visibleMessage).data!);
    final Offset before = tester.getTopLeft(anchor);
    items = <TimelineItem>[
      for (int i = 0; i < 10; i++) UserMessageItem(id: i, text: 'Message $i'),
      ...items.take(items.length - 1),
      AgentMessageItem(
        id: 'stream',
        text: List<String>.filled(20, 'More output').join('\n\n'),
      ),
      const UserMessageItem(id: 'new', text: 'Latest event'),
    ];
    await tester.pumpWidget(app(items));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(anchor), before);
    await tester.tap(find.byTooltip('Jump to latest event'));
    await tester.pumpAndSettle();
    expect(find.text('Latest event').hitTestable(), findsOneWidget);
    await tester.pumpWidget(
      app(<TimelineItem>[
        ...items,
        const UserMessageItem(id: 'newer', text: 'Even newer'),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.text('Even newer').hitTestable(), findsOneWidget);
  });
  testWidgets('thought stays expanded when merged chunks change sequence', (
    tester,
  ) async {
    List<TimelineItem> timeline(
      int seq,
      String thought, {
      bool complete = false,
    }) => deriveTimelineItems(<SessionEvent>[
      const UserMessageEvent(text: 'Question', seq: 1),
      AgentThoughtChunkEvent(text: thought, messageId: 'thought', seq: seq),
      const AgentMessageChunkEvent(
        text: 'Answer',
        messageId: 'answer',
        seq: 20,
      ),
      if (complete) const TurnCompleteEvent(stopReason: 'end_turn', seq: 21),
    ]);
    await tester.pumpWidget(app(timeline(2, 'Reasoning')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Thought'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(app(timeline(3, 'Reasoning continues')));
    await tester.pumpAndSettle();
    expect(find.text('Reasoning continues').hitTestable(), findsOneWidget);
    await tester.pumpWidget(
      app(timeline(3, 'Reasoning continues', complete: true)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Reasoning continues').hitTestable(), findsOneWidget);
  });

  testWidgets('expansion survives virtualization and incoming events', (
    tester,
  ) async {
    final List<TimelineItem> items = <TimelineItem>[
      for (int i = 0; i < 80; i++) UserMessageItem(id: i, text: 'Message $i'),
      const AgentActivityItem(
        id: 'activity',
        activity: AgentActivity(
          id: 'activity',
          kind: 'info',
          title: 'Activity',
          status: AgentActivityStatus.completed,
          details: <String>['Activity details'],
        ),
      ),
      tool(ToolCallStatus.completed),
      const UserMessageItem(id: 'end', text: 'End'),
    ];
    await tester.pumpWidget(app(items));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Activity'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Read a file'));
    await tester.pumpAndSettle();
    final ScrollPosition position = tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byKey(const Key('chat-timeline')),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text('Read a file'), findsNothing);
    await tester.pumpWidget(
      app(<TimelineItem>[
        ...items,
        const UserMessageItem(id: 'appended', text: 'Appended'),
      ]),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Jump to latest event'));
    await tester.pumpAndSettle();
    expect(find.text('Details to read').hitTestable(), findsOneWidget);
    expect(find.text('Activity details').hitTestable(), findsOneWidget);
  });

  testWidgets('manual tool expansion survives completion', (tester) async {
    await tester.pumpWidget(app(<TimelineItem>[tool(ToolCallStatus.running)]));
    await tester.pump();
    await tester.tap(find.text('Read a file'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Read a file'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(
      app(<TimelineItem>[tool(ToolCallStatus.completed)]),
    );
    await tester.pumpAndSettle();
    expect(find.text('Details to read').hitTestable(), findsOneWidget);
  });
}
