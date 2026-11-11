import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/chat/composer.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

final QueuedMessage _queued = QueuedMessage(
  id: 'q1',
  text: 'Also run the tests',
  createdAt: DateTime.utc(2026),
);

class _Harness {
  final List<String> sent = <String>[];
  final List<String> steered = <String>[];
  final List<String> removed = <String>[];
  final List<String> edited = <String>[];
}

Future<_Harness> _pump(
  WidgetTester tester, {
  SessionStatus status = SessionStatus.running,
  SessionQueue? queue,
  bool reduceMotion = false,
  Brightness brightness = Brightness.light,
}) async {
  final _Harness harness = _Harness();
  await tester.pumpWidget(
    MaterialApp(
      theme: brightness == Brightness.dark
          ? buildSpeedDialTheme()
          : buildSpeedDialLightTheme(),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: child!,
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: Composer(
            status: status,
            queue: queue,
            onSend: (String text, _) async => harness.sent.add(text),
            onStop: () {},
            onSendQueued: (QueuedMessage message) async =>
                harness.steered.add(message.id),
            onRemoveQueued: (QueuedMessage message) async =>
                harness.removed.add(message.id),
            onEditQueued: (QueuedMessage message) async {
              harness.edited.add(message.id);
              return (
                text: message.text,
                attachments: const <OutgoingAttachment>[
                  OutgoingAttachment(
                    name: 'notes.txt',
                    mimeType: 'text/plain',
                    data: 'aGk=',
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
  return harness;
}

void main() {
  testWidgets('a message typed during a turn is sent for queueing', (
    WidgetTester tester,
  ) async {
    final _Harness harness = await _pump(tester);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Stop'), findsOneWidget);
    expect(find.byKey(const Key('composer-queue')), findsNothing);

    await tester.enterText(find.byType(TextField), 'Then update the docs');
    await tester.pump();
    expect(find.byKey(const Key('composer-queue')), findsOneWidget);
    expect(find.byTooltip('Stop'), findsOneWidget);
    await tester.tap(find.byKey(const Key('composer-queue')));
    await tester.pumpAndSettle();
    expect(harness.sent, <String>['Then update the docs']);
  });

  testWidgets('steers, edits and removes queued messages', (
    WidgetTester tester,
  ) async {
    final _Harness harness = await _pump(
      tester,
      queue: SessionQueue(
        sessionId: 's',
        messages: <QueuedMessage>[_queued],
        canSteer: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Also run the tests'), findsOneWidget);
    expect(
      find.text('Queued · sends after this turn, or steer it in now'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('queued-steer-q1')));
    await tester.pumpAndSettle();
    expect(harness.steered, <String>['q1']);

    await tester.enterText(find.byType(TextField), 'Draft');
    await tester.tap(find.byKey(const Key('queued-edit-q1')));
    await tester.pumpAndSettle();
    expect(harness.edited, <String>['q1']);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Draft\n\nAlso run the tests',
    );
    expect(find.text('notes.txt'), findsOneWidget);

    await tester.tap(find.byKey(const Key('queued-remove-q1')));
    await tester.pumpAndSettle();
    expect(harness.removed, <String>['q1']);
  });

  testWidgets('no steer without harness support; paused offers Send now', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      queue: SessionQueue(sessionId: 's', messages: <QueuedMessage>[_queued]),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('queued-steer-q1')), findsNothing);
    expect(find.byKey(const Key('queued-send-q1')), findsNothing);
    expect(find.text('Queued · sends after this turn'), findsOneWidget);

    await _pump(
      tester,
      status: SessionStatus.idle,
      queue: SessionQueue(
        sessionId: 's',
        messages: <QueuedMessage>[_queued],
        canSteer: true,
        paused: true,
      ),
      brightness: Brightness.dark,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('queued-send-q1')), findsOneWidget);
    expect(
      find.text('Queue paused · the last turn did not finish'),
      findsOneWidget,
    );
  });

  testWidgets('rows rise in once, then hold still', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      queue: SessionQueue(sessionId: 's', messages: <QueuedMessage>[_queued]),
    );
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('reduced motion shows the queue at once', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      reduceMotion: true,
      queue: SessionQueue(sessionId: 's', messages: <QueuedMessage>[_queued]),
    );
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);
    expect(find.text('Also run the tests'), findsOneWidget);
  });
}
