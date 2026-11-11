import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('SessionQueue round-trips with queued messages', () {
    final SessionQueue queue = SessionQueue(
      sessionId: 's1',
      canSteer: true,
      paused: true,
      messages: <QueuedMessage>[
        QueuedMessage(
          id: 'q1',
          text: 'next',
          attachments: const <Attachment>[
            Attachment(
              id: 'a1',
              name: 'a.txt',
              mimeType: 'text/plain',
              size: 2,
            ),
          ],
          createdAt: DateTime.utc(2026, 1, 2, 3),
        ),
      ],
    );
    final Map<String, Object?> json = queue.toJson();
    expect((json['messages']! as List).single, <String, Object?>{
      'id': 'q1',
      'text': 'next',
      'attachments': <Object?>[
        <String, Object?>{
          'id': 'a1',
          'name': 'a.txt',
          'mimeType': 'text/plain',
          'size': 2,
        },
      ],
      'createdAt': '2026-01-02T03:00:00.000Z',
    });
    final SessionQueue decoded = SessionQueue.fromJson(json);
    expect(decoded.sessionId, 's1');
    expect(decoded.canSteer, isTrue);
    expect(decoded.paused, isTrue);
    expect(decoded.messages.single.attachments.single.name, 'a.txt');
    expect(decoded.messages.single.createdAt, DateTime.utc(2026, 1, 2, 3));
  });

  test('SessionQueue tolerates missing optional fields', () {
    final SessionQueue queue = SessionQueue.fromJson(<String, Object?>{
      'sessionId': 's1',
    });
    expect(queue.messages, isEmpty);
    expect(queue.canSteer, isFalse);
    expect(queue.paused, isFalse);
  });
}
