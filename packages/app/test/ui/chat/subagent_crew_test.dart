import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/chat/oven.dart';
import 'package:speeddial_app/src/ui/chat/timeline.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

/// What Codex sends per subagent interaction: settled as it lands, naming
/// the subagent by path and an opaque id.
AgentActivityEvent _codex(String call, String title, String path) =>
    AgentActivityEvent(
      activity: AgentActivity(
        id: 'codex-subagent-$call',
        kind: 'subagent',
        title: title,
        status: AgentActivityStatus.completed,
        details: <String>[path, '01a0f964-25bc-71b1-8048-0538d00f2b35'],
      ),
    );

final List<SessionEvent> _turn = <SessionEvent>[
  const UserMessageEvent(text: 'Audit the references'),
  _codex('1', 'Sub-agent launch', '/root/audit_references'),
  _codex('2', 'Sub-agent interaction', '/root/checkin_guard'),
  _codex('3', 'Sub-agent interaction', '/root/audit_references'),
  const AgentActivityEvent(
    activity: AgentActivity(
      id: 'mcp',
      kind: 'mcp',
      title: 'MCP · codex_apps',
      status: AgentActivityStatus.completed,
    ),
  ),
  const AgentMessageChunkEvent(text: 'All references check out.'),
];

Future<void> _frames(WidgetTester tester, int count) async {
  for (int i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  group('subagent crews', () {
    test('a turn gathers its subagents into one crew at its end', () {
      final List<TimelineItem> items = deriveTimelineItems(<SessionEvent>[
        ..._turn,
        const TurnCompleteEvent(stopReason: 'end_turn'),
      ]);
      // Ahead of the divider; other activities keep their cards.
      expect(items.map((TimelineItem item) => item.runtimeType), <Type>[
        UserMessageItem,
        AgentActivityItem,
        AgentMessageItem,
        SubagentCrewItem,
        TurnCompleteItem,
      ]);
      final SubagentCrewItem crew = items.whereType<SubagentCrewItem>().single;
      expect(crew.live, isFalse);
      expect(crew.subagents.map((Subagent s) => s.name), <String>[
        'audit_references',
        'checkin_guard',
      ]);
      expect(crew.subagents.first.updates, hasLength(2));
      expect(crew.updates, 3);
    });

    test('the running turn\'s crew is live until its turn closes', () {
      expect(
        deriveTimelineItems(_turn, running: true).last,
        isA<SubagentCrewItem>().having(
          (SubagentCrewItem crew) => crew.live,
          'live',
          isTrue,
        ),
      );
      // The closing event settles it even while the status lags.
      expect(
        deriveTimelineItems(<SessionEvent>[
          ..._turn,
          const TurnCompleteEvent(stopReason: 'end_turn'),
        ], running: true).whereType<SubagentCrewItem>().single.live,
        isFalse,
      );
    });

    test('each turn keeps its own crew', () {
      final List<TimelineItem> items = deriveTimelineItems(<SessionEvent>[
        ..._turn,
        const TurnCompleteEvent(stopReason: 'end_turn'),
        const UserMessageEvent(text: 'Again'),
        _codex('4', 'Sub-agent interaction', '/root/audit_references'),
      ]);
      expect(items.whereType<SubagentCrewItem>().map((c) => c.updates), <int>[
        3,
        1,
      ]);
    });

    Widget app(List<TimelineItem> items, {TurnHeat heat = TurnHeat.off}) =>
        MaterialApp(
          theme: buildSpeedDialTheme(),
          home: Scaffold(
            body: Timeline(items: items, heat: heat),
          ),
        );
    final Finder spot = find.byKey(const Key('crew-spot'));
    final Finder row = find.byKey(const Key('crew-row'));

    testWidgets('while the turn runs the crew is a spot in its flame row', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        app(deriveTimelineItems(_turn, running: true), heat: TurnHeat.cooking),
      );
      await _frames(tester, 40);
      expect(row, findsNothing);
      expect(spot, findsOneWidget);
      expect(
        find.descendant(of: spot, matching: find.text('2 subagents')),
        findsOneWidget,
      );
      expect(find.text('audit_references'), findsNothing);

      await tester.tap(spot);
      await _frames(tester, 30);
      expect(find.text('audit_references').hitTestable(), findsOneWidget);
      expect(find.text('checkin_guard').hitTestable(), findsOneWidget);
      // Opened at the live end, the list grows into view.
      final ScrollPosition position = tester
          .widget<CustomScrollView>(find.byKey(const Key('chat-timeline')))
          .controller!
          .position;
      expect(position.pixels, moreOrLessEquals(position.minScrollExtent));
    });

    testWidgets('a subagent\'s flame flares when it reports', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        app(deriveTimelineItems(_turn, running: true), heat: TurnHeat.cooking),
      );
      await _frames(tester, 40);
      double flare() => tester
          .widget<ScaleTransition>(
            find
                .descendant(of: spot, matching: find.byType(ScaleTransition))
                .first,
          )
          .scale
          .value;
      expect(flare(), 1);

      await tester.pumpWidget(
        app(
          deriveTimelineItems(<SessionEvent>[
            ..._turn,
            _codex('5', 'Sub-agent activity', '/root/audit_references'),
          ], running: true),
          heat: TurnHeat.cooking,
        ),
      );
      await _frames(tester, 8);
      expect(flare(), greaterThan(1));
      await _frames(tester, 40);
      expect(flare(), 1);
    });

    testWidgets('a finished turn\'s crew takes one line that opens', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        app(
          deriveTimelineItems(<SessionEvent>[
            ..._turn,
            const TurnCompleteEvent(stopReason: 'end_turn'),
          ]),
        ),
      );
      expect(spot, findsNothing);
      expect(find.text('2 subagents · 3 updates'), findsOneWidget);
      expect(find.text('audit_references'), findsNothing);

      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.text('audit_references'), findsOneWidget);
      // Each update by title; the opaque id never shows.
      await tester.tap(find.text('audit_references'));
      await tester.pumpAndSettle();
      expect(find.text('Sub-agent launch'), findsOneWidget);
      expect(find.textContaining('01a0f964'), findsNothing);
    });

    testWidgets('the newest row is the one above a live crew', (
      WidgetTester tester,
    ) async {
      // Opening the latest visible row keeps following, as it would with
      // no crew gathering below it.
      final List<TimelineItem> items = <TimelineItem>[
        for (int i = 0; i < 30; i++) UserMessageItem(id: i, text: 'Message $i'),
        const AgentThoughtItem(id: 'thought', text: 'Weighing the retry.'),
        ...deriveTimelineItems(
          _turn,
          running: true,
        ).whereType<SubagentCrewItem>(),
      ];
      await tester.pumpWidget(app(items, heat: TurnHeat.cooking));
      await _frames(tester, 40);
      await tester.tap(find.text('Thought'));
      await _frames(tester, 30);
      await tester.pumpWidget(
        app(<TimelineItem>[
          ...items,
          const UserMessageItem(id: 'new', text: 'New event'),
        ], heat: TurnHeat.cooking),
      );
      await _frames(tester, 30);
      final ScrollPosition position = tester
          .widget<CustomScrollView>(find.byKey(const Key('chat-timeline')))
          .controller!
          .position;
      expect(position.pixels, moreOrLessEquals(position.minScrollExtent));
      expect(find.text('New event').hitTestable(), findsOneWidget);
    });
  });
}
