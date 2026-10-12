import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/chat/catching_up.dart';
import 'package:speeddial_app/src/ui/chat/timeline.dart';
import 'package:speeddial_app/src/ui/chat/tool_run.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

void main() {
  // One theme instance: a fresh one per pump would crossfade themes.
  final ThemeData theme = buildSpeedDialTheme();

  void stillMotion(WidgetTester tester) {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  }

  group('catching-up strip', () {
    Widget strip({required bool active}) => MaterialApp(
      theme: theme,
      home: Scaffold(
        body: Column(
          children: <Widget>[
            const Expanded(child: SizedBox()),
            CatchingUpStrip(active: active),
          ],
        ),
      ),
    );
    final Finder label = find.text('Catching up…');
    double risen(WidgetTester tester) => tester
        .widget<SizeTransition>(
          find.descendant(
            of: find.byKey(const Key('catching-up')),
            matching: find.byType(SizeTransition),
          ),
        )
        .sizeFactor
        .value;

    testWidgets('a catch-up quicker than a blink never shows', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(strip(active: true));
      await tester.pump(
        CatchingUpStrip.patience - const Duration(milliseconds: 30),
      );
      expect(label, findsNothing);
      await tester.pumpWidget(strip(active: false));
      await tester.pump(const Duration(milliseconds: 300));
      expect(label, findsNothing);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('a longer one rises in, then folds away as it lands', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(strip(active: true));
      await tester.pump(CatchingUpStrip.patience);
      await tester.pump(const Duration(milliseconds: 100));
      expect(label, findsOneWidget);
      expect(risen(tester), inExclusiveRange(0, 1));
      await tester.pump(const Duration(milliseconds: 300));
      expect(risen(tester), 1);

      await tester.pumpWidget(strip(active: false));
      await tester.pump(const Duration(milliseconds: 100));
      expect(risen(tester), inExclusiveRange(0, 1));
      await tester.pump(const Duration(milliseconds: 600));
      expect(label, findsNothing);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('reduced motion shows and hides it at once, still', (
      WidgetTester tester,
    ) async {
      stillMotion(tester);
      await tester.pumpWidget(strip(active: true));
      await tester.pump();
      expect(label, findsOneWidget);
      expect(risen(tester), 1);
      expect(tester.hasRunningAnimations, isFalse);

      await tester.pumpWidget(strip(active: false));
      await tester.pump();
      expect(label, findsNothing);
    });
  });

  group('arrival rise', () {
    final Finder rise = find.byKey(const Key('arrival-rise'));
    Widget row(Duration? delay) => Directionality(
      textDirection: TextDirection.ltr,
      child: ArrivalRise(delay: delay, child: const Text('row')),
    );
    double shown(WidgetTester tester) =>
        tester.widget<FadeTransition>(rise).opacity.value;

    testWidgets('a row with a delay waits its turn, then rises into place', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(row(const Duration(milliseconds: 120)));
      expect(shown(tester), 0);
      await tester.pump(const Duration(milliseconds: 100));
      expect(shown(tester), 0);
      await tester.pump(const Duration(milliseconds: 150));
      expect(shown(tester), inExclusiveRange(0, 1));
      // Rebuilt without its delay partway, it carries on.
      await tester.pumpWidget(row(null));
      await tester.pump(const Duration(milliseconds: 400));
      expect(shown(tester), 1);
    });

    testWidgets('a row without one just shows, and stays put', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(row(null));
      expect(rise, findsNothing);
      await tester.pumpWidget(row(const Duration(milliseconds: 120)));
      await tester.pump(const Duration(milliseconds: 200));
      expect(rise, findsNothing);
    });
  });

  group('a timeline catching up', () {
    final List<SessionEvent> stale = <SessionEvent>[
      const UserMessageEvent(text: 'Why is the drawer slow?'),
      const AgentMessageChunkEvent(text: 'Looking into it.', messageId: 'm1'),
    ];
    final List<SessionEvent> missed = <SessionEvent>[
      const ToolCallEvent(
        toolCall: ToolCall(
          id: 'read',
          title: 'Read',
          kind: 'read',
          status: ToolCallStatus.completed,
          content: <ToolCallContent>[],
          locations: <String>[],
          rawInput: <String, Object?>{'file_path': 'lib/sheet.dart'},
        ),
      ),
      const AgentMessageChunkEvent(text: 'Found it.', messageId: 'm2'),
    ];
    Widget app(List<SessionEvent> events, {required bool catchingUp}) =>
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Timeline(
              items: deriveTimelineItems(events),
              catchingUp: catchingUp,
            ),
          ),
        );
    Finder riseOf(Finder content) => find.descendant(
      of: find.ancestor(of: content, matching: find.byType(ArrivalRise)),
      matching: find.byKey(const Key('arrival-rise')),
    );
    double shown(WidgetTester tester, Finder content) =>
        tester.widget<FadeTransition>(riseOf(content)).opacity.value;
    final Finder before = find.text('Looking into it.', findRichText: true);
    final Finder reply = find.text('Found it.', findRichText: true);
    final Finder run = find.byType(ToolRunCard);
    final Finder sparks = find.byKey(const Key('landing-sparks'));

    Future<void> catchUp(WidgetTester tester, List<SessionEvent> landed) async {
      await tester.pumpWidget(app(stale, catchingUp: false));
      await tester.pumpAndSettle();
      await tester.pumpWidget(app(stale, catchingUp: true));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpWidget(app(landed, catchingUp: false));
    }

    testWidgets('the rows it brings rise in turn and land in sparks', (
      WidgetTester tester,
    ) async {
      await catchUp(tester, <SessionEvent>[...stale, ...missed]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // In reading order: the older row first, the newest after it.
      expect(shown(tester, run), greaterThan(shown(tester, reply)));
      expect(shown(tester, reply), lessThan(1));
      // What showed before stays as it was.
      expect(riseOf(before), findsNothing);
      expect(sparks, paints..line());

      await tester.pumpAndSettle();
      expect(shown(tester, reply), 1);
      expect(sparks, paintsNothing);
    });

    testWidgets('one that brings nothing new moves nothing', (
      WidgetTester tester,
    ) async {
      await catchUp(tester, stale);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('arrival-rise')), findsNothing);
      expect(sparks, paintsNothing);
    });

    testWidgets('under reduced motion its rows just show', (
      WidgetTester tester,
    ) async {
      stillMotion(tester);
      await catchUp(tester, <SessionEvent>[...stale, ...missed]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(reply, findsOneWidget);
      expect(find.byKey(const Key('arrival-rise')), findsNothing);
      expect(sparks, paintsNothing);
    });
  });
}
