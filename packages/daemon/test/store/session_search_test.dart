@TestOn('vm')
library;

import 'dart:io';

import 'package:speeddial_daemon/src/store/daemon_store.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;
import 'package:test/test.dart';

import 'daemon_store_test.dart' show project, session;

Future<SessionSearchPage> indexedSearch(
  DaemonStore store,
  String query, {
  bool includeArchived = false,
  String? projectId,
  int limit = 50,
  SessionSearchCursor? cursor,
}) async {
  final Stopwatch timeout = Stopwatch()..start();
  while (true) {
    final SessionSearchPage page = await store.searchSessionText(
      query: query,
      includeArchived: includeArchived,
      projectId: projectId,
      limit: limit,
      cursor: cursor,
    );
    if (!page.indexing) return page;
    if (timeout.elapsed.inSeconds > 10) fail('Index did not finish');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late Directory directory;
  late String path;
  late DaemonStore store;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('session-search-');
    path = '${directory.path}/store.db';
    store = DaemonStore(path)..insertProject(project());
  });
  tearDown(() {
    store.dispose();
    directory.deleteSync(recursive: true);
  });

  test(
    'finds literal title and conversation text, with bounded excerpts',
    () async {
      store.insertSession(session(id: 'title', title: 'Release Planning'));
      store.insertSession(session(id: 'history'));
      store.appendEvent(
        'history',
        1,
        UserMessageEvent(
          text: '${'context ' * 1000}RELEASE blocker ${'tail ' * 1000}',
        ),
      );
      final SessionSearchPage page = await indexedSearch(store, 'release');
      expect(page.results.map((r) => r.session.id), {'title', 'history'});
      final SessionSearchResult match = page.results.last;
      expect(match.excerpt, contains('RELEASE blocker'));
      expect(match.excerpt.length, lessThanOrEqualTo(322));
      expect(match.projectName, 'Project p1');
      expect((await indexedSearch(store, 'userMessage')).results, isEmpty);

      for (final String query in <String>[
        'a OR b',
        '100%_done',
        'say "yes"',
        '日本語',
        'CAFÉ',
      ]) {
        store.appendEvent(
          'history',
          store.nextSeq('history'),
          UserMessageEvent(text: query),
        );
        expect(
          (await indexedSearch(store, query)).results.single.session.id,
          'history',
        );
      }
      expect((await indexedSearch(store, 'absent')).results, isEmpty);
    },
  );

  test('joins identified chunks across interleaving, without joining turns or messages', () async {
    store.insertSession(session(id: 'chunks'));
    final List<SessionEvent> events = <SessionEvent>[
      const UserMessageEvent(text: 'start'),
      const AgentMessageChunkEvent(text: 'relea', messageId: 'a'),
      const AgentThoughtChunkEvent(text: 'thinking', messageId: 't'),
      const AgentMessageChunkEvent(text: 'different', messageId: 'b'),
      const AgentMessageChunkEvent(text: 'se blocker', messageId: 'a'),
      const TurnCompleteEvent(stopReason: 'end_turn'),
      const AgentMessageChunkEvent(text: 'another turn', messageId: 'a'),
      const AgentMessageChunkEvent(text: 'legacy'),
      const AgentMessageChunkEvent(text: ' continuation'),
    ];
    for (final SessionEvent event in events) {
      store.appendEvent('chunks', store.nextSeq('chunks'), event);
    }
    expect(
      (await indexedSearch(store, 'release blocker')).results,
      hasLength(1),
    );
    expect(
      (await indexedSearch(store, 'legacy continuation')).results,
      hasLength(1),
    );
    expect((await indexedSearch(store, 'releadifferent')).results, isEmpty);
    expect((await indexedSearch(store, 'blockeranother')).results, isEmpty);
    expect((await indexedSearch(store, 'turnlegacy')).results, isEmpty);
  });

  test('long messages match across block boundaries and resume tails after restart', () async {
    store.insertSession(session(id: 'long'));
    store.appendEvent(
      'long',
      1,
      AgentMessageChunkEvent(
        text: '${'x' * 4090}boundary phrase ${'y' * 15000}stream',
        messageId: 'm',
      ),
    );
    expect(
      (await indexedSearch(store, 'boundary phrase')).results,
      hasLength(1),
    );
    store.dispose();
    store = DaemonStore(path);
    store.appendEvent(
      'long',
      2,
      const AgentMessageChunkEvent(text: 'ing needle', messageId: 'm'),
    );
    expect(
      (await indexedSearch(store, 'streaming needle')).results,
      hasLength(1),
    );
    final Database db = sqlite3.open(path);
    try {
      expect(
        db
            .select(
              'SELECT MAX(length(text)) AS size FROM session_search_documents',
            )
            .first['size'],
        lessThanOrEqualTo(4096),
      );
    } finally {
      db.close();
    }
  });

  test(
    'pages distinct sessions by activity with archive and project filters',
    () async {
      store.insertProject(project(id: 'p2'));
      for (int i = 0; i < 6; i++) {
        store.insertSession(
          session(
            id: 's$i',
            title: 'needle $i',
            projectId: i == 5 ? 'p2' : 'p1',
            archived: i == 4,
            lastActivityAt: DateTime.utc(2026, 1, 1, i),
          ),
        );
        store.appendEvent(
          's$i',
          1,
          const UserMessageEvent(text: 'needle again'),
        );
      }
      final SessionSearchPage first = await indexedSearch(
        store,
        'needle',
        limit: 2,
      );
      expect(first.results.map((r) => r.session.id), ['s5', 's3']);
      final SessionSearchPage second = await indexedSearch(
        store,
        'needle',
        limit: 2,
        cursor: first.nextCursor,
      );
      expect(second.results.map((r) => r.session.id), ['s2', 's1']);
      final SessionSearchPage third = await indexedSearch(
        store,
        'needle',
        limit: 2,
        cursor: second.nextCursor,
      );
      expect(third.results.single.session.id, 's0');
      expect(third.nextCursor, isNull);
      expect(
        (await indexedSearch(
          store,
          'needle',
          projectId: 'p2',
        )).results.single.session.id,
        's5',
      );
      expect(
        (await indexedSearch(store, 'needle', includeArchived: true)).results,
        hasLength(6),
      );
    },
  );

  test('renames, deletes, removed projects and fork rollback keep index consistent', () async {
    store.insertSession(session(id: 's', title: 'original title'));
    await indexedSearch(store, 'original');
    store.updateSession(session(id: 's', title: 'replacement'));
    expect((await indexedSearch(store, 'original')).results, isEmpty);
    expect((await indexedSearch(store, 'replacement')).results, hasLength(1));
    expect(
      () => store.insertFork(session(id: 'fork', title: 'failed fork'), 1, () {
        store.appendEvent(
          'fork',
          1,
          const UserMessageEvent(text: 'phantom needle'),
        );
        throw StateError('rollback');
      }),
      throwsStateError,
    );
    expect((await indexedSearch(store, 'phantom')).results, isEmpty);
    store.removeProject('p1');
    final SessionSearchResult removed = (await indexedSearch(
      store,
      'replacement',
      includeArchived: true,
    )).results.single;
    expect(removed.projectName, isNull);
    expect(removed.session.archived, isTrue);
    store.deleteSession('s');
    expect(
      (await indexedSearch(
        store,
        'replacement',
        includeArchived: true,
      )).results,
      isEmpty,
    );
  });

  test('backfills pre-index databases and persists work across interrupted indexing', () async {
    store.insertSession(session(id: 'old', title: 'Old title'));
    store.appendEvent(
      'old',
      1,
      const AgentMessageChunkEvent(text: 'saved nee', messageId: 'm'),
    );
    store.dispose();
    final Database db = sqlite3.open(path);
    for (final Row row in db.select(
      "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'session_search_%'",
    )) {
      db.execute('DROP TRIGGER ${row['name']}');
    }
    db.execute(
      'DROP TABLE session_search_fts; DROP TABLE session_search_documents; '
      'DROP TABLE session_search_state; DROP INDEX session_search_activity;',
    );
    db.close();
    store = DaemonStore(path);
    // Stop before the first batch, then resume with newly persisted content.
    store.dispose();
    store = DaemonStore(path);
    store.appendEvent(
      'old',
      2,
      const AgentMessageChunkEvent(text: 'dle', messageId: 'm'),
    );
    store.insertSession(session(id: 'new', title: 'new needle'));
    final SessionSearchPage page = await indexedSearch(store, 'needle');
    expect(page.results.map((r) => r.session.id), {'old', 'new'});
    store.dispose();
    store = DaemonStore(path);
    expect((await store.searchSessionText(query: 'needle')).indexing, isFalse);
  });

  test('resumes indexing partway through a single huge message', () async {
    store.insertSession(session(id: 'huge'));
    store.appendEvent(
      'huge',
      1,
      AgentMessageChunkEvent(
        text: '${'context ' * 150000}saved needle',
        messageId: 'huge',
      ),
    );
    final Database db = sqlite3.open(path);
    try {
      // Observe a committed partial batch rather than relying on a fixed
      // delay or allowing the index to finish before exercising restart.
      while (true) {
        final Row state = db
            .select(
              "SELECT indexed_seq, event_offset FROM session_search_state WHERE session_id = 'huge'",
            )
            .first;
        expect(state['indexed_seq'], 0);
        if ((state['event_offset'] as int) > 0) break;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    } finally {
      db.close();
    }
    store.dispose();
    store = DaemonStore(path);
    store.appendEvent(
      'huge',
      2,
      const AgentMessageChunkEvent(text: ' continued', messageId: 'huge'),
    );
    expect(
      (await indexedSearch(store, 'saved needle continued')).results,
      hasLength(1),
    );
  });

  test('common-query plan preserves ordering and falls back for older-only matches', () async {
    for (int i = 0; i < 700; i++) {
      store.insertSession(
        session(
          id: 's$i',
          title: 'common title ${i < 40 ? 'oldmatch' : ''}',
          lastActivityAt: DateTime.utc(2026).add(Duration(seconds: i)),
        ),
      );
    }
    final SessionSearchPage common = await indexedSearch(
      store,
      'common',
      limit: 5,
    );
    expect(common.results.map((r) => r.session.id), [
      's699',
      's698',
      's697',
      's696',
      's695',
    ]);
    final SessionSearchPage older = await indexedSearch(
      store,
      'oldmatch',
      limit: 5,
    );
    expect(older.results.map((r) => r.session.id), [
      's39',
      's38',
      's37',
      's36',
      's35',
    ]);
    expect(
      (await indexedSearch(
        store,
        'common',
        projectId: 'missing',
        limit: 5,
      )).results,
      isEmpty,
    );
  });

  test(
    'rejects short, oversized and invalid queries and unbounded pages',
    () async {
      for (final String query in <String>[
        '',
        '  ',
        'ab',
        '😀a',
        'x' * 257,
        'ab\u0000cd',
      ]) {
        await expectLater(
          store.searchSessionText(query: query),
          throwsA(isA<DaemonError>()),
        );
      }
      for (final int limit in <int>[0, -1, 101]) {
        await expectLater(
          store.searchSessionText(query: 'needle', limit: limit),
          throwsA(isA<DaemonError>()),
        );
      }
    },
  );
}
