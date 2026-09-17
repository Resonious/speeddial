import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/left/session_search_dialog.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

class SearchClient extends FakeDaemonClient {
  final List<String> queries = <String>[];
  final List<Completer<SessionSearchPage>> replies =
      <Completer<SessionSearchPage>>[];
  bool controlled = false;
  Object? failure;
  int historyCalls = 0;

  @override
  Future<SessionSearchPage> searchSessions({
    required String query,
    String? projectId,
    bool includeArchived = false,
    int limit = 50,
    SessionSearchCursor? cursor,
  }) {
    queries.add(query);
    if (failure != null) return Future<SessionSearchPage>.error(failure!);
    if (controlled) {
      final Completer<SessionSearchPage> reply = Completer<SessionSearchPage>();
      replies.add(reply);
      return reply.future;
    }
    return super.searchSessions(
      query: query,
      projectId: projectId,
      includeArchived: includeArchived,
      limit: limit,
      cursor: cursor,
    );
  }

  @override
  Future<({List<SessionEvent> events, bool hasMore})> history(
    String sessionId, {
    int limit = 200,
    int? beforeSeq,
  }) {
    historyCalls++;
    return super.history(sessionId, limit: limit, beforeSeq: beforeSeq);
  }
}

Future<void> pumpSearch(
  WidgetTester tester,
  SearchClient client, {
  Size size = const Size(1440, 900),
  double keyboard = 0,
  ValueChanged<SessionSearchResult?>? onResult,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
  addTearDown(tester.view.reset);
  addTearDown(client.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildSpeedDialTheme(),
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async {
              final SessionSearchResult? result =
                  await showDialog<SessionSearchResult>(
                    context: context,
                    builder: (_) => SessionSearchDialog(
                      client: client,
                      daemonName: 'Test daemon',
                    ),
                  );
              onResult?.call(result);
            },
            child: const Text('Open search'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open search'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('debounces text, searches unloaded history and opens a result', (
    WidgetTester tester,
  ) async {
    final SearchClient client = SearchClient();
    client.seedHistory('sess-2', const <SessionEvent>[
      UserMessageEvent(text: 'Investigate the release blocker'),
    ]);
    SessionSearchResult? chosen;
    await pumpSearch(tester, client, onResult: (result) => chosen = result);
    final Finder input = find.byKey(const Key('session-search-field'));
    await tester.enterText(input, 're');
    await tester.pump(const Duration(milliseconds: 300));
    expect(client.queries, isEmpty);
    await tester.enterText(input, 'relea');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(input, 'release');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(client.queries, ['release']);
    expect(client.historyCalls, 0);
    expect(find.text('Investigate the release blocker'), findsOneWidget);
    await tester.tap(find.byKey(const Key('search-result-sess-2')));
    await tester.pumpAndSettle();
    expect(chosen?.session.id, 'sess-2');
    expect(find.byType(SessionSearchDialog), findsNothing);
  });

  testWidgets('archive filter, no results, clear and keyboard dismissal', (
    WidgetTester tester,
  ) async {
    final SearchClient client = SearchClient();
    await client.archiveSession('sess-1', true);
    await pumpSearch(tester, client);
    await tester.enterText(find.byType(TextField), 'build');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(find.text('No sessions found.'), findsOneWidget);
    await tester.tap(find.text('Include archived'));
    await tester.pumpAndSettle();
    expect(find.text('Build the feature'), findsOneWidget);
    expect(find.textContaining('Archived'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    expect(find.text('Enter at least 3 characters to search.'), findsOneWidget);
    expect(find.byKey(const Key('search-result-sess-1')), findsNothing);
    await tester.tap(find.byTooltip('Close search'));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'slow requests coalesce and stale responses cannot replace new query',
    (WidgetTester tester) async {
      final SearchClient client = SearchClient()..controlled = true;
      final List<Session> sessions = await client.listSessions();
      await pumpSearch(tester, client);
      await tester.enterText(find.byType(TextField), 'old');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.enterText(find.byType(TextField), 'middle');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.enterText(find.byType(TextField), 'new');
      await tester.pump(const Duration(milliseconds: 250));
      expect(client.queries, ['old']);
      client.replies.first.complete(
        SessionSearchPage(
          results: <SessionSearchResult>[
            SessionSearchResult(
              session: sessions.first,
              projectName: 'demo',
              excerpt: 'Stale result',
            ),
          ],
        ),
      );
      await tester.pump();
      expect(find.text('Stale result'), findsNothing);
      expect(client.queries, ['old', 'new']);
      client.replies.last.complete(
        SessionSearchPage(
          results: <SessionSearchResult>[
            SessionSearchResult(
              session: sessions.last,
              projectName: 'demo',
              excerpt: 'Current result',
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Current result'), findsOneWidget);
      await tester.tap(find.byTooltip('Close search'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('failures are visible and retry succeeds', (
    WidgetTester tester,
  ) async {
    final SearchClient client = SearchClient()
      ..failure = DaemonError(-32601, 'Unknown method');
    await pumpSearch(tester, client);
    await tester.enterText(find.byType(TextField), 'build');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(
      find.text('Update this daemon to search its sessions.'),
      findsOneWidget,
    );
    client.failure = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Build the feature'), findsOneWidget);
    await tester.tap(find.byTooltip('Close search'));
    await tester.pumpAndSettle();
  });

  testWidgets('fits a narrow screen with the software keyboard visible', (
    WidgetTester tester,
  ) async {
    final SearchClient client = SearchClient();
    await pumpSearch(tester, client, size: const Size(320, 568), keyboard: 260);
    await tester.enterText(find.byType(TextField), 'build');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Build the feature'), findsOneWidget);
    await tester.tap(find.byTooltip('Close search'));
    await tester.pumpAndSettle();
  });

  testWidgets('closing during a request ignores its late completion', (
    WidgetTester tester,
  ) async {
    final SearchClient client = SearchClient()..controlled = true;
    await pumpSearch(tester, client);
    await tester.enterText(find.byType(TextField), 'build');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byTooltip('Close search'));
    await tester.pumpAndSettle();
    client.replies.single.complete(
      const SessionSearchPage(results: <SessionSearchResult>[], indexing: true),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(client.queries, ['build']);
    expect(tester.takeException(), isNull);
  });
}
