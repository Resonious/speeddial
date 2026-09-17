import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/state/session_search_store.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

class PagedClient extends FakeDaemonClient {
  final List<SessionSearchCursor?> cursors = <SessionSearchCursor?>[];
  final List<Completer<SessionSearchPage>> replies =
      <Completer<SessionSearchPage>>[];

  @override
  Future<SessionSearchPage> searchSessions({
    required String query,
    String? projectId,
    bool includeArchived = false,
    int limit = 50,
    SessionSearchCursor? cursor,
  }) {
    cursors.add(cursor);
    final Completer<SessionSearchPage> reply = Completer<SessionSearchPage>();
    replies.add(reply);
    return reply.future;
  }
}

void main() {
  test(
    'pages without duplicates and invalidates an old page after filter changes',
    () async {
      final PagedClient client = PagedClient();
      final SessionSearchStore store = SessionSearchStore(client);
      addTearDown(client.dispose);
      addTearDown(store.dispose);
      final List<SessionSearchResult> results = (await client.listSessions())
          .map(
            (Session session) => SessionSearchResult(
              session: session,
              projectName: 'Demo',
              excerpt: 'needle',
            ),
          )
          .toList();
      final SessionSearchCursor cursor = SessionSearchCursor(
        lastActivityAt: DateTime.utc(2026),
        id: 's',
      );
      store.update(query: 'needle');
      final Future<void> first = store.search();
      client.replies.last.complete(
        SessionSearchPage(
          results: <SessionSearchResult>[results.first],
          nextCursor: cursor,
        ),
      );
      await first;
      final Future<void> more = store.search(more: true);
      expect(client.cursors.last, cursor);
      client.replies.last.complete(SessionSearchPage(results: results));
      await more;
      expect(store.results, hasLength(2));
      expect(store.hasMore, isFalse);

      final Future<void> stale = store.search();
      store.update(includeArchived: true);
      client.replies.last.complete(SessionSearchPage(results: results));
      await stale;
      expect(store.results, isEmpty);
      expect(store.includeArchived, isTrue);
    },
  );

  test(
    'records and rethrows current failures without exposing stale errors',
    () async {
      final PagedClient client = PagedClient();
      final SessionSearchStore store = SessionSearchStore(client);
      addTearDown(client.dispose);
      addTearDown(store.dispose);
      store.update(query: 'first');
      final StateError failure = StateError('offline');
      final Future<void> first = store.search();
      final Future<void> expectation = expectLater(
        first,
        throwsA(same(failure)),
      );
      client.replies.last.completeError(failure);
      await expectation;
      expect(store.lastError, same(failure));
      expect(store.loading, isFalse);

      final Future<void> stale = store.search();
      final Future<void> staleExpectation = expectLater(
        stale,
        throwsA(same(failure)),
      );
      store.update(query: 'second');
      client.replies.last.completeError(failure);
      await staleExpectation;
      expect(store.lastError, isNull);
      expect(store.query, 'second');
    },
  );
}
