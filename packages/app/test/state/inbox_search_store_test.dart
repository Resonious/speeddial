import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/state/inbox_search_store.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

/// Answers each search only when the test completes its reply.
class GatedClient extends FakeDaemonClient {
  final List<Completer<SessionSearchPage>> replies =
      <Completer<SessionSearchPage>>[];
  final List<bool> archivedFlags = <bool>[];

  @override
  Future<SessionSearchPage> searchSessions({
    required String query,
    String? projectId,
    bool includeArchived = false,
    int limit = 50,
    SessionSearchCursor? cursor,
  }) {
    archivedFlags.add(includeArchived);
    final Completer<SessionSearchPage> reply = Completer<SessionSearchPage>();
    replies.add(reply);
    return reply.future;
  }
}

void main() {
  late GatedClient a;
  late GatedClient b;
  late InboxSearchStore store;
  late Session session;

  setUp(() async {
    a = GatedClient();
    b = GatedClient();
    store = InboxSearchStore(
      (String id) => switch (id) {
        'a' => a,
        'b' => b,
        _ => throw StateError(id),
      },
    );
    session = (await a.listSessions()).first;
  });

  tearDown(() {
    store.dispose();
    a.dispose();
    b.dispose();
  });

  SessionSearchPage page({bool indexing = false}) => SessionSearchPage(
    results: <SessionSearchResult>[
      SessionSearchResult(session: session, projectName: 'P', excerpt: 'hit'),
    ],
    indexing: indexing,
  );

  test('searches every daemon at once and shows each as it replies', () async {
    store.update(query: '  needle ', includeArchived: true);
    expect(store.query, 'needle');
    final Future<void> done = store.search(<String>['a', 'b']);
    expect(a.replies, hasLength(1));
    expect(b.replies, hasLength(1));
    expect(a.archivedFlags.single, isTrue);
    expect(store.searching, isTrue);

    b.replies.single.complete(page(indexing: true));
    await pumpEventQueue();
    expect(store.results.keys, <String>['b']);
    expect(store.searching, isTrue);
    expect(store.indexing, isTrue);

    a.replies.single.complete(page());
    await done;
    expect(store.results.keys, containsAll(<String>['a', 'b']));
    expect(store.searching, isFalse);
  });

  test('records a failing daemon, keeps the others, and rethrows', () async {
    store.update(query: 'needle');
    final Future<void> done = store.search(<String>['a', 'b']);
    a.replies.single.completeError(DaemonError(-32603, 'boom'));
    b.replies.single.complete(page());
    await expectLater(done, throwsA(isA<DaemonError>()));
    expect(store.errorFor('a'), isA<DaemonError>());
    expect(store.errorFor('b'), isNull);
    expect(store.results.keys, <String>['b']);
    expect(store.searching, isFalse);
  });

  test('drops replies to a query that has since changed', () async {
    store.update(query: 'first');
    final Future<void> stale = store.search(<String>['a']);
    store.update(query: 'second');
    final Future<void> fresh = store.search(<String>['a']);
    a.replies.first.complete(page());
    await stale;
    expect(store.results, isEmpty);
    expect(store.searching, isTrue);
    a.replies.last.complete(const SessionSearchPage(results: []));
    await fresh;
    expect(store.results['a'], isEmpty);
  });

  test('short queries are left to the caller', () async {
    store.update(query: 'ab');
    expect(store.canSearch, isFalse);
    await store.search(<String>['a']);
    expect(a.replies, isEmpty);
  });
}
