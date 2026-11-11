import 'dart:convert';

import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('session note round-trips open and checked-off notes', () {
    final SessionNote open = SessionNote(
      id: 'n1',
      sessionId: 's1',
      projectId: 'p1',
      text: 'Write the migration',
      done: false,
      createdAt: DateTime.utc(2026, 11, 1),
      updatedAt: DateTime.utc(2026, 11, 2),
    );
    final SessionNote done = open.copyWith(
      done: true,
      doneAt: () => DateTime.utc(2026, 11, 3),
    );
    for (final SessionNote note in <SessionNote>[open, done]) {
      final SessionNote decoded = SessionNote.fromJson(
        (jsonDecode(jsonEncode(note.toJson())) as Map).cast<String, Object?>(),
      );
      expect(decoded, note);
    }
    expect(open.toJson()['doneAt'], isNull);
    expect(done.copyWith(done: false, doneAt: () => null).doneAt, isNull);
  });
}
