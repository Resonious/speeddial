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

/// What Ante sends per subagent: launched with its type, later settled with
/// its report under the same id.
AgentActivityEvent _anteSubagent(
  String call,
  String title, {
  AgentActivityStatus status = AgentActivityStatus.running,
  String? report,
}) => AgentActivityEvent(
  activity: AgentActivity(
    id: 'ante-subagent-$call',
    kind: 'subagent',
    title: title,
    status: status,
    details: <String>['explore', ?report],
  ),
);

/// What Ante sends per action a subagent takes.
AgentActivityEvent _anteStep(
  String call,
  int step,
  String title, [
  String? arguments,
]) => AgentActivityEvent(
  activity: AgentActivity(
    id: 'ante-subagent-$call-step-$step',
    kind: 'subagent',
    title: title,
    status: AgentActivityStatus.completed,
    details: <String>[?arguments],
  ),
);

/// Two subagents of one type at work, one of them done.
final List<SessionEvent> _anteTurn = <SessionEvent>[
  const UserMessageEvent(text: 'Look into the cutover'),
  _anteSubagent('a', 'Assess resume safety'),
  _anteSubagent('b', 'Map the reset guards'),
  _anteStep('a', 0, 'I’ll start from the importer.'),
  _anteStep('a', 1, 'Grep', 'pattern="checkpoint"'),
  _anteStep('b', 0, 'Grep', 'pattern="checkpoint"'),
  _anteStep('a', 2, 'Read', 'file_path="src/import.rs"'),
  _anteSubagent(
    'a',
    'Assess resume safety',
    status: AgentActivityStatus.completed,
    report: 'Resuming is safe.',
  ),
];

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

    test('each Ante subagent gathers its own actions', () {
      final SubagentCrewItem crew = deriveTimelineItems(
        _anteTurn,
        running: true,
      ).whereType<SubagentCrewItem>().single;
      expect(crew.live, isTrue);
      // Two subagents of one type, however many actions they took.
      expect(crew.subagents.map((Subagent s) => s.name), <String>[
        'Assess resume safety',
        'Map the reset guards',
      ]);
      expect(crew.subagents.map((Subagent s) => s.kind), <String>[
        'explore',
        'explore',
      ]);
      expect(
        crew.subagents.first.updates.map((AgentActivity u) => u.title),
        <String>['I’ll start from the importer.', 'Grep', 'Read'],
      );
      expect(crew.subagents.last.updates, hasLength(1));
      // One settled with its report while the other works on.
      final Subagent done = crew.subagents.first;
      expect(done.finished, isTrue);
      expect(done.status, AgentActivityStatus.completed);
      expect(done.report, 'Resuming is safe.');
      final Subagent working = crew.subagents.last;
      expect(working.finished, isFalse);
      expect(working.status, AgentActivityStatus.running);
      expect(working.report, isNull);
    });

    test('an Ante subagent launched before the loaded page still gathers', () {
      // The page starts after its launch; its settled snapshot names it.
      final SubagentCrewItem crew = deriveTimelineItems(<SessionEvent>[
        _anteStep('a', 7, 'Grep', 'pattern="checkpoint"'),
        _anteStep('a', 8, 'Read', 'file_path="src/import.rs"'),
        _anteSubagent(
          'a',
          'Assess resume safety',
          status: AgentActivityStatus.failed,
          report: 'Interrupted',
        ),
        const TurnCompleteEvent(stopReason: 'end_turn'),
      ]).whereType<SubagentCrewItem>().single;
      final Subagent subagent = crew.subagents.single;
      expect(subagent.name, 'Assess resume safety');
      expect(subagent.kind, 'explore');
      expect(subagent.updates, hasLength(2));
      expect(subagent.status, AgentActivityStatus.failed);
      expect(subagent.finished, isTrue);
    });

    Widget app(
      List<TimelineItem> items, {
      TurnHeat heat = TurnHeat.off,
      String? cwd,
    }) => MaterialApp(
      theme: buildSpeedDialTheme(),
      home: Scaffold(
        body: Timeline(items: items, heat: heat, cwd: cwd),
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

    testWidgets('Ante\'s crew line counts subagents, not their actions', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        app(
          deriveTimelineItems(<SessionEvent>[
            ..._anteTurn,
            _anteSubagent(
              'b',
              'Map the reset guards',
              status: AgentActivityStatus.completed,
              report: 'Two guards stand.',
            ),
            const TurnCompleteEvent(stopReason: 'end_turn'),
          ]),
        ),
      );
      expect(find.text('2 subagents · 4 updates'), findsOneWidget);

      await tester.tap(row);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Assess resume safety'));
      await tester.pumpAndSettle();
      // Its actions, read like tool rows, then its report.
      expect(find.text('Search “checkpoint”'), findsOneWidget);
      expect(find.text('Read import.rs'), findsOneWidget);
      expect(find.text('Resuming is safe.'), findsOneWidget);
      expect(find.text('Two guards stand.'), findsNothing);
    });

    testWidgets('an Ante subagent\'s actions read like tool rows', (
      WidgetTester tester,
    ) async {
      const String cwd = '/home/nigel/p/app';
      await tester.pumpWidget(
        app(
          deriveTimelineItems(<SessionEvent>[
            const UserMessageEvent(text: 'Why is the drawer slow?'),
            _anteSubagent('a', 'Investigate the drawer'),
            _anteStep('a', 0, 'I’ll search the app for the drawer.'),
            _anteStep('a', 1, '… ^[[1mimport^[[0m with mode: Restart'),
            // A long message: its opening line, then the whole of it.
            _anteStep(
              'a',
              5,
              'Findings so far:',
              'Findings so far:\n- The sheet reloads every session.',
            ),
            _anteStep(
              'a',
              2,
              'Grep',
              'output_mode="files_with_matches", path="$cwd/lib", '
                  'pattern="NewSession"',
            ),
            _anteStep('a', 3, 'Read', 'file_path="$cwd/lib/sheet.dart"'),
            _anteStep(
              'a',
              4,
              'Bash',
              'command="cd $cwd && git log --oneline -5", '
                  'description="Shows recent commits", max_wait_ms=10000',
            ),
            _anteSubagent(
              'a',
              'Investigate the drawer',
              status: AgentActivityStatus.completed,
              report: 'It reloads every session.',
            ),
            const TurnCompleteEvent(stopReason: 'end_turn'),
          ]),
          cwd: cwd,
        ),
      );
      await tester.tap(row);
      await tester.pumpAndSettle();
      // Its summary names its latest action as plainly.
      expect(find.text('6 updates · Shows recent commits'), findsOneWidget);

      await tester.tap(find.textContaining('Investigate the drawer'));
      await tester.pumpAndSettle();
      expect(find.text('Search “NewSession” in lib'), findsOneWidget);
      expect(find.byIcon(Icons.search), findsOneWidget);
      expect(find.text('Read sheet.dart'), findsOneWidget);
      expect(find.text('lib/sheet.dart'), findsOneWidget);
      expect(find.byIcon(Icons.description_outlined), findsOneWidget);
      expect(find.text('Shows recent commits'), findsOneWidget);
      expect(find.text('git log --oneline -5'), findsOneWidget);
      expect(find.byIcon(Icons.terminal), findsOneWidget);
      // Its own words once each, without the log's styling.
      expect(find.text('I’ll search the app for the drawer.'), findsOneWidget);
      expect(find.text('… import with mode: Restart'), findsOneWidget);
      expect(
        find.text('Findings so far:\n- The sheet reloads every session.'),
        findsOneWidget,
      );
      expect(find.text('It reloads every session.'), findsOneWidget);
      expect(find.textContaining('pattern'), findsNothing);

      // Tapping an action shows everything it was given.
      await tester.tap(find.text('Search “NewSession” in lib'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'output_mode: files_with_matches\n'
          'path: $cwd/lib\n'
          'pattern: NewSession',
        ),
        findsOneWidget,
      );
    });

    // A subagent with more to show than the screen holds: opening it grows
    // the timeline past the screen while it follows the bottom, which
    // rebuilds the rows there from what they kept.
    final List<SessionEvent> busyTurn = <SessionEvent>[
      const UserMessageEvent(text: 'Look into the cutover'),
      _anteSubagent('a', 'Assess resume safety'),
      _anteSubagent('b', 'Map the reset guards'),
      for (int i = 0; i < 40; i++)
        _anteStep('a', i, 'Grep', 'pattern="step $i"'),
    ];
    void smallScreen(WidgetTester tester) {
      tester.view.physicalSize = const Size(400, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    testWidgets('a subagent opened in a finished crew stays open past the '
        'screen', (WidgetTester tester) async {
      smallScreen(tester);
      await tester.pumpWidget(
        app(
          deriveTimelineItems(<SessionEvent>[
            ...busyTurn,
            _anteSubagent(
              'a',
              'Assess resume safety',
              status: AgentActivityStatus.completed,
              report: 'Resuming is safe.',
            ),
            const TurnCompleteEvent(stopReason: 'end_turn'),
          ]),
        ),
      );
      await tester.tap(row);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Assess resume safety'));
      await tester.pumpAndSettle();
      expect(find.text('Resuming is safe.'), findsOneWidget);
      expect(find.text('Search “step 39”'), findsOneWidget);
    });

    testWidgets('a subagent opened in a live crew stays open past the screen', (
      WidgetTester tester,
    ) async {
      smallScreen(tester);
      await tester.pumpWidget(
        app(
          deriveTimelineItems(busyTurn, running: true),
          heat: TurnHeat.cooking,
        ),
      );
      await _frames(tester, 40);
      await tester.tap(spot);
      await _frames(tester, 30);
      await tester.tap(find.textContaining('Assess resume safety'));
      await _frames(tester, 30);
      expect(find.text('Search “step 39”'), findsOneWidget);
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
