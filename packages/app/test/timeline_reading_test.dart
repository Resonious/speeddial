import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/chat/thought_line.dart';
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
  testWidgets('trackpad can scroll up and keep reading an idle timeline', (
    tester,
  ) async {
    final List<TimelineItem> items = <TimelineItem>[
      for (int i = 0; i < 60; i++) UserMessageItem(id: i, text: 'Message $i'),
    ];
    await tester.pumpWidget(app(items));
    await tester.pumpAndSettle();
    final Finder timeline = find.byKey(const Key('chat-timeline'));
    final ScrollableState scrollable = tester.state<ScrollableState>(
      find.descendant(of: timeline, matching: find.byType(Scrollable)).first,
    );
    final ScrollPosition position = scrollable.position;
    expect(position.pixels, position.minScrollExtent);
    final TestGesture trackpad = await tester.createGesture(
      pointer: 7,
      kind: PointerDeviceKind.trackpad,
    );
    final Offset location = tester.getCenter(timeline);
    await trackpad.panZoomStart(location);
    await trackpad.panZoomUpdate(location, pan: const Offset(0, 40));
    await tester.pump();
    await trackpad.panZoomUpdate(location, pan: const Offset(0, 240));
    await tester.pump();
    expect(position.pixels, greaterThan(position.minScrollExtent + 100));
    await trackpad.panZoomEnd();
    await tester.pumpAndSettle();
    final double readingOffset = position.pixels;
    await tester.pumpWidget(app(List<TimelineItem>.of(items)));
    await tester.pumpAndSettle();
    expect(scrollable.position.pixels, readingOffset);
    expect(find.byTooltip('Jump to latest event'), findsOneWidget);
    await tester.tap(find.byTooltip('Jump to latest event'));
    await tester.pumpAndSettle();
    expect(scrollable.position.pixels, scrollable.position.minScrollExtent);
  });

  for (final bool reduceMotion in <bool>[false, true]) {
    testWidgets(
      'jumping to the latest event lands instantly'
      '${reduceMotion ? ' and quietly under reduced motion' : ' in sparks'}',
      (tester) async {
        if (reduceMotion) {
          tester.platformDispatcher.accessibilityFeaturesTestValue =
              const FakeAccessibilityFeatures(disableAnimations: true);
          addTearDown(
            tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
          );
        }
        await tester.pumpWidget(
          app(<TimelineItem>[
            for (int i = 0; i < 60; i++)
              UserMessageItem(id: i, text: 'Message $i'),
          ]),
        );
        await tester.pumpAndSettle();
        final Finder timeline = find.byKey(const Key('chat-timeline'));
        final ScrollPosition position = tester
            .state<ScrollableState>(
              find
                  .descendant(of: timeline, matching: find.byType(Scrollable))
                  .first,
            )
            .position;
        await tester.drag(timeline, const Offset(0, 400));
        await tester.pumpAndSettle();
        expect(position.pixels, greaterThan(position.minScrollExtent + 100));

        await tester.tap(find.byTooltip('Jump to latest event'));
        await tester.pump();
        expect(position.pixels, position.minScrollExtent);
        // Embers are still flying well after the button's own feedback.
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.hasRunningAnimations, !reduceMotion);
        await tester.pump(const Duration(seconds: 1));
        expect(tester.hasRunningAnimations, isFalse);
      },
    );
  }

  testWidgets('the jump button rises in and sinks back out', (tester) async {
    await tester.pumpWidget(
      app(<TimelineItem>[
        for (int i = 0; i < 60; i++) UserMessageItem(id: i, text: 'Message $i'),
      ]),
    );
    await tester.pumpAndSettle();
    final Finder button = find.byKey(const Key('latest-button'));
    final Finder tooltip = find.byTooltip('Jump to latest event');
    double opacity() => tester.widget<FadeTransition>(button).opacity.value;
    Future<void> frames() async {
      await tester.pump();
      for (int i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
    }

    expect(button, findsNothing);
    // Reading away from the bottom: it rises in rather than popping up.
    await tester.drag(
      find.byKey(const Key('chat-timeline')),
      const Offset(0, 300),
    );
    await frames();
    expect(opacity(), inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect(opacity(), 1);
    expect(tooltip.hitTestable(), findsOneWidget);

    // Landing: it sinks away and takes no taps on the way out.
    await tester.tap(tooltip);
    await frames();
    expect(opacity(), inExclusiveRange(0, 1));
    expect(tooltip.hitTestable(), findsNothing);
    await tester.pumpAndSettle();
    expect(button, findsNothing);
  });

  testWidgets('scrolling back down to the bottom lands in sparks', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(<TimelineItem>[
        for (int i = 0; i < 60; i++) UserMessageItem(id: i, text: 'Message $i'),
      ]),
    );
    await tester.pumpAndSettle();
    final Finder timeline = find.byKey(const Key('chat-timeline'));
    final Finder sparks = find.byKey(const Key('landing-sparks'));

    // A wiggle that never leaves the bottom is not a landing.
    await tester.drag(timeline, const Offset(0, 16));
    await tester.pumpAndSettle();
    await tester.drag(timeline, const Offset(0, -40));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(sparks, paintsNothing);
    await tester.pumpAndSettle();

    // Reading back up, then scrolling all the way down again, is.
    await tester.drag(timeline, const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Jump to latest event'), findsOneWidget);
    await tester.drag(timeline, const Offset(0, -400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(sparks, paints..line());
    await tester.pumpAndSettle();
    expect(sparks, paintsNothing);
  });

  for (final bool reduceMotion in <bool>[false, true]) {
    testWidgets(
      'activity below ${reduceMotion ? 'leaves the jump button still under '
                'reduced motion' : 'flares the jump button, which then cools'}',
      (tester) async {
        if (reduceMotion) {
          tester.platformDispatcher.accessibilityFeaturesTestValue =
              const FakeAccessibilityFeatures(disableAnimations: true);
          addTearDown(
            tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
          );
        }
        // One theme instance: a fresh one per pump would crossfade themes.
        final ThemeData theme = buildSpeedDialTheme();
        Widget timeline(int activity) => MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Timeline(
              activity: activity,
              items: <TimelineItem>[
                for (int i = 0; i < 60; i++)
                  UserMessageItem(id: i, text: 'Message $i'),
              ],
            ),
          ),
        );
        final Finder flames = find.byKey(const Key('latest-flames'));
        await tester.pumpWidget(timeline(0));
        await tester.pumpAndSettle();
        await tester.drag(
          find.byKey(const Key('chat-timeline')),
          const Offset(0, 400),
        );
        await tester.pumpAndSettle();
        expect(find.byTooltip('Jump to latest event'), findsOneWidget);
        expect(flames, findsNothing);

        await tester.pumpWidget(timeline(1));
        await tester.pump(const Duration(milliseconds: 100));
        expect(flames, reduceMotion ? findsNothing : findsOneWidget);

        await tester.pump(const Duration(seconds: 2));
        expect(flames, findsNothing);
        expect(tester.hasRunningAnimations, isFalse);
      },
    );
  }

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
    final Finder body = find.byKey(const Key('thought-body'));
    String opened() => tester
        .widget<Text>(find.descendant(of: body, matching: find.byType(Text)))
        .data!;
    await tester.pumpWidget(app(timeline(2, 'Reasoning')));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ThoughtLine));
    await tester.pumpAndSettle();
    await tester.pumpWidget(app(timeline(3, 'Reasoning continues')));
    await tester.pumpAndSettle();
    expect(body.hitTestable(), findsOneWidget);
    expect(opened(), 'Reasoning continues');
    await tester.pumpWidget(
      app(timeline(3, 'Reasoning continues', complete: true)),
    );
    await tester.pumpAndSettle();
    expect(body.hitTestable(), findsOneWidget);
    expect(opened(), 'Reasoning continues');
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

  testWidgets('opening the newest row keeps the live end in view', (
    tester,
  ) async {
    final List<TimelineItem> items = <TimelineItem>[
      for (int i = 0; i < 30; i++) UserMessageItem(id: i, text: 'Message $i'),
      tool(ToolCallStatus.completed),
    ];
    await tester.pumpWidget(app(items));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Read a file'));
    await tester.pumpAndSettle();
    expect(find.text('Details to read').hitTestable(), findsOneWidget);

    // Unlike opening an earlier row, this keeps following what comes next.
    await tester.pumpWidget(
      app(<TimelineItem>[
        ...items,
        const UserMessageItem(id: 'new', text: 'New event'),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.text('New event').hitTestable(), findsOneWidget);
    expect(find.byTooltip('Jump to latest event'), findsNothing);
  });

  testWidgets('manual tool expansion survives completion', (tester) async {
    await tester.pumpWidget(app(<TimelineItem>[tool(ToolCallStatus.running)]));
    await tester.pump();
    // A running call stays collapsed until tapped, so nothing jumps.
    expect(find.text('Details to read').hitTestable(), findsNothing);
    await tester.tap(find.text('Read a file'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(
      app(<TimelineItem>[tool(ToolCallStatus.completed)]),
    );
    await tester.pumpAndSettle();
    expect(find.text('Details to read').hitTestable(), findsOneWidget);
  });
}
