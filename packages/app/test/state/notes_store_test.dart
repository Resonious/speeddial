import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/state/notes_store.dart';

Future<void> _flush() => Future<void>.delayed(Duration.zero);

class _FlakyNotesFake extends FakeDaemonClient {
  bool failList = false;
  bool failUpdate = false;
  bool failDelete = false;
  int listCalls = 0;

  @override
  Future<List<SessionNote>> listNotes({
    String? sessionId,
    bool open = false,
  }) async {
    listCalls++;
    if (failList) throw const DaemonConnectionError('peer closed');
    return super.listNotes(sessionId: sessionId, open: open);
  }

  @override
  Future<SessionNote> updateNote(
    String noteId, {
    String? text,
    bool? done,
  }) async {
    if (failUpdate) throw const DaemonError(-32603, 'disk full');
    return super.updateNote(noteId, text: text, done: done);
  }

  @override
  Future<void> deleteNote(String noteId) async {
    if (failDelete) throw const DaemonError(-32603, 'disk full');
    return super.deleteNote(noteId);
  }
}

void main() {
  late _FlakyNotesFake fake;
  late NotesStore store;
  bool canLoad = true;

  setUp(() {
    fake = _FlakyNotesFake();
    canLoad = true;
    store = NotesStore(clientFor: (_) => fake, canLoad: (_) => canLoad);
  });

  tearDown(() async {
    store.dispose();
    await fake.dispose();
  });

  test('loads once and counts notes per session', () async {
    store.ensureLoaded('d');
    store.ensureLoaded('d');
    await _flush();
    expect(fake.listCalls, 1);
    expect(store.hasLoaded('d'), isTrue);
    expect(store.countsFor('d', 'sess-1'), (done: 1, total: 2));
    expect(store.countsFor('d', 'sess-2'), (done: 0, total: 1));
    expect(store.countsFor('other', 'sess-1'), (done: 0, total: 0));
    expect(store.openCount, 2);
    expect(store.sessionsWithOpenNotes().toSet(), <DaemonSessionKey>{
      (daemonId: 'd', sessionId: 'sess-1'),
      (daemonId: 'd', sessionId: 'sess-2'),
    });
  });

  test('follows note notifications and session removal', () async {
    store.ensureLoaded('d');
    await _flush();
    int notifications = 0;
    store.addListener(() => notifications++);

    // Another client adds and checks off notes.
    final SessionNote added = await fake.createNote('sess-2', 'Elsewhere');
    await _flush();
    expect(store.countsFor('d', 'sess-2'), (done: 0, total: 2));
    await fake.updateNote(added.id, done: true);
    await _flush();
    expect(store.countsFor('d', 'sess-2'), (done: 1, total: 2));
    await fake.deleteNote(added.id);
    await _flush();
    expect(store.countsFor('d', 'sess-2'), (done: 0, total: 1));
    expect(notifications, 3);

    await fake.deleteSession('sess-2');
    await _flush();
    expect(store.notesFor('d', 'sess-2'), isEmpty);
  });

  test('check-off applies at once and rolls back on failure', () async {
    store.ensureLoaded('d');
    await _flush();
    final SessionNote note = store.notesFor('d', 'sess-2').single;

    final Future<void> checking = store.setDone('d', note.id, true);
    expect(store.notesFor('d', 'sess-2').single.done, isTrue);
    await checking;
    expect(store.notesFor('d', 'sess-2').single.doneAt, isNotNull);

    fake.failUpdate = true;
    final Future<void> reopening = store.setDone('d', note.id, false);
    expect(store.notesFor('d', 'sess-2').single.done, isFalse);
    await expectLater(reopening, throwsA(isA<DaemonError>()));
    expect(store.notesFor('d', 'sess-2').single.done, isTrue);
    expect(store.lastError, isA<DaemonError>());
  });

  test('delete applies at once and restores on failure', () async {
    store.ensureLoaded('d');
    await _flush();
    final SessionNote note = store.notesFor('d', 'sess-2').single;
    fake.failDelete = true;
    final Future<void> deleting = store.remove('d', note.id);
    expect(store.notesFor('d', 'sess-2'), isEmpty);
    await expectLater(deleting, throwsA(isA<DaemonError>()));
    expect(store.notesFor('d', 'sess-2').single.id, note.id);
  });

  test(
    'a failed or premature load retries when the connection changes',
    () async {
      canLoad = false;
      store.ensureLoaded('d');
      await _flush();
      expect(fake.listCalls, 0);

      canLoad = true;
      fake.failList = true;
      store.onConnectionChanged();
      await _flush();
      expect(fake.listCalls, 1);
      expect(store.errorFor('d'), isA<DaemonConnectionError>());
      expect(store.hasLoaded('d'), isFalse);
      // A failure is not retried on every build.
      store.ensureLoaded('d');
      await _flush();
      expect(fake.listCalls, 1);

      fake.failList = false;
      store.onConnectionChanged();
      await _flush();
      expect(store.errorFor('d'), isNull);
      expect(store.hasLoaded('d'), isTrue);
    },
  );

  test('a resync reloads notes', () async {
    store.ensureLoaded('d');
    await _flush();
    fake.triggerResync();
    await _flush();
    expect(fake.listCalls, 2);
  });

  test('forgets daemons that are no longer configured', () async {
    store.ensureLoaded('d');
    await _flush();
    store.retainDaemons(<String>{});
    expect(store.hasLoaded('d'), isFalse);
    expect(store.openCount, 0);
    unawaited(fake.createNote('sess-1', 'Ignored'));
    await _flush();
    expect(store.notesFor('d', 'sess-1'), isEmpty);
  });
}
