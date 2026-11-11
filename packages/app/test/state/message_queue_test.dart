
import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/scope.dart';

Future<void> _waitUntil(bool Function() condition) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not met in time');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late FakeDaemonClient fake;
  late AppData app;
  const String session = 'sess-1';

  setUp(() {
    fake = FakeDaemonClient(eventDelay: const Duration(milliseconds: 10));
    app = AppData()..registerClient('fake', fake);
    app.chat.watchSession('fake', session);
  });

  tearDown(() => app.dispose());

  List<String> userTexts() => <String>[
    for (final SessionEvent event in app.chat.eventsFor(session))
      if (event is UserMessageEvent) event.text,
  ];

  Future<void> startTurn() async {
    await app.chat.send('fake', session, 'first');
    await _waitUntil(() => app.chat.statusOf(session) == SessionStatus.running);
  }

  test('a send during a turn queues and runs after it', () async {
    await _waitUntil(() => app.chat.queueFor(session) != null);
    await startTurn();
    await app.chat.send('fake', session, 'second');

    // Queued, not in flight: no outgoing bubble, one tray entry.
    expect(app.chat.outgoingFor(session), isEmpty);
    expect(
      app.chat.queueFor(session)!.messages.map((QueuedMessage m) => m.text),
      <String>['second'],
    );

    await _waitUntil(() => userTexts().length == 2);
    expect(userTexts(), <String>['first', 'second']);
    expect(app.chat.queueFor(session)!.messages, isEmpty);
    // The delivered queued message pops like a confirmed send.
    final int seq = app.chat
        .eventsFor(session)
        .whereType<UserMessageEvent>()
        .last
        .seq!;
    expect(app.chat.deliveredSeqsFor(session), contains(seq));
    await _waitUntil(() => app.chat.statusOf(session) == SessionStatus.idle);
  });

  test('steering delivers a queued message into the running turn', () async {
    await startTurn();
    await app.chat.send('fake', session, 'go left');
    final QueuedMessage queued = app.chat.queueFor(session)!.messages.single;
    expect(app.chat.queueFor(session)!.canSteer, isTrue);

    expect(await app.chat.sendQueued('fake', session, queued.id), isTrue);
    await _waitUntil(() => userTexts().length == 2);
    expect(app.chat.queueFor(session)!.messages, isEmpty);
    expect(app.chat.statusOf(session), SessionStatus.running);
    await _waitUntil(() => app.chat.statusOf(session) == SessionStatus.idle);
    // One turn: the steered message did not start another.
    expect(
      app.chat.eventsFor(session).whereType<TurnCompleteEvent>(),
      hasLength(1),
    );
  });

  test('cancelling pauses the queue; unqueue removes a message', () async {
    await startTurn();
    await app.chat.send('fake', session, 'later');
    await app.chat.cancel('fake', session);
    await _waitUntil(() => app.chat.queueFor(session)?.paused ?? false);
    expect(app.chat.statusOf(session), SessionStatus.idle);

    final QueuedMessage queued = app.chat.queueFor(session)!.messages.single;
    final QueuedMessage removed = await app.chat.unqueue(
      'fake',
      session,
      queued.id,
    );
    expect(removed.text, 'later');
    expect(app.chat.queueFor(session)!.messages, isEmpty);
    expect(userTexts(), <String>['first']);
  });

  test('a rejected steer records the error and rethrows', () async {
    fake.steering = false;
    await startTurn();
    await app.chat.send('fake', session, 'go left');
    final QueuedMessage queued = app.chat.queueFor(session)!.messages.single;
    await expectLater(
      app.chat.sendQueued('fake', session, queued.id),
      throwsA(isA<DaemonError>()),
    );
    expect(app.chat.lastError, isA<DaemonError>());
    expect(app.chat.queueFor(session)!.messages, hasLength(1));
    await _waitUntil(() => userTexts().length == 2);
  });
}
