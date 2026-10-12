import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/scope.dart';
import 'package:speeddial_app/src/ui/settings/archive_page.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

class _PreviewErrorClient extends FakeDaemonClient {
  @override
  Future<ArchivePreview> previewArchive() async =>
      throw StateError('Storage unavailable');
}

class _PartialFailureClient extends FakeDaemonClient {
  @override
  Future<ClearArchiveResult> clearArchive(List<String> sessionIds) async {
    final ClearArchiveResult result = await super.clearArchive(<String>[
      sessionIds.first,
    ]);
    return ClearArchiveResult(
      deletedSessionIds: result.deletedSessionIds,
      removedWorktreeCount: result.removedWorktreeCount,
      failures: <ArchiveFailure>[
        ArchiveFailure(
          sessionId: sessionIds.last,
          message: 'Worktree is locked',
        ),
      ],
    );
  }
}

Future<AppData> pumpArchive(
  WidgetTester tester,
  FakeDaemonClient client,
) async {
  final AppData data = AppData()..registerClient('daemon', client);
  addTearDown(data.dispose);
  await data.sessions.refresh('daemon');
  await tester.pumpWidget(
    MaterialApp(
      home: AppScope(
        data: data,
        child: const ArchivePage(daemonId: 'daemon', daemonName: 'Test daemon'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return data;
}

void main() {
  testWidgets('preview shows storage and cancellation deletes nothing', (
    WidgetTester tester,
  ) async {
    final FakeDaemonClient client = FakeDaemonClient();
    await client.archiveSession('sess-1', true);
    await pumpArchive(tester, client);
    expect(find.text('1 session ready to delete'), findsOneWidget);
    expect(find.textContaining('Transcripts:'), findsOneWidget);
    expect(find.textContaining('Worktrees ('), findsOneWidget);
    expect(find.textContaining('Attachments:'), findsOneWidget);
    await tester.tap(find.byKey(const Key('clear-archive')));
    await tester.pumpAndSettle();
    expect(find.textContaining('cannot be undone'), findsOneWidget);
    expect(client.clearArchiveCalls, isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(client.clearArchiveCalls, isEmpty);
    expect(await client.listSessions(includeArchived: true), hasLength(2));
  });

  testWidgets(
    'confirmation deletes only the previewed archive and clears selected chat',
    (WidgetTester tester) async {
      final FakeDaemonClient client = FakeDaemonClient();
      await client.archiveSession('sess-1', true);
      final AppData data = await pumpArchive(tester, client);
      data.selection.selectSession(
        daemonId: 'daemon',
        projectId: 'proj-demo',
        sessionId: 'sess-1',
      );
      await tester.tap(find.byKey(const Key('clear-archive')));
      await tester.pumpAndSettle();
      await client.archiveSession(
        'sess-2',
        true,
      ); // Arrives after confirmation opened.
      await tester.tap(find.byKey(const Key('clear-archive-confirm')));
      await tester.pumpAndSettle();
      expect(client.clearArchiveCalls.single, <String>['sess-1']);
      expect(
        (await client.listSessions(includeArchived: true)).single.id,
        'sess-2',
      );
      expect(data.selection.selectedSessionId, isNull);
      expect(data.sessions.sessionOnDaemon('daemon', 'sess-1'), isNull);
    },
  );

  testWidgets(
    'empty archive has no destructive action and fits a small phone',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpArchive(tester, FakeDaemonClient());
      expect(find.text('The archive is empty.'), findsOneWidget);
      expect(find.byKey(const Key('clear-archive')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('preview failures are recorded and allow retry', (
    WidgetTester tester,
  ) async {
    final AppData data = await pumpArchive(tester, _PreviewErrorClient());
    expect(data.sessions.lastError, isA<StateError>());
    expect(data.sessions.archiveErrorFor('daemon'), isA<StateError>());
    expect(find.textContaining('Could not load archive'), findsOneWidget);
    expect(find.byKey(const Key('clear-archive')), findsNothing);
    await tester.tap(find.byKey(const Key('archive-refresh')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not load archive'), findsOneWidget);
  });

  testWidgets(
    'partial failures update caches, keep failed sessions, and show the error',
    (WidgetTester tester) async {
      final _PartialFailureClient client = _PartialFailureClient();
      await client.archiveSession('sess-1', true);
      await client.archiveSession('sess-2', true);
      final AppData data = await pumpArchive(tester, client);
      await tester.tap(find.byKey(const Key('clear-archive')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('clear-archive-confirm')));
      await tester.pumpAndSettle();
      expect(data.sessions.lastError, isA<StateError>());
      expect(find.textContaining('Worktree is locked'), findsOneWidget);
      expect(
        (await client.listSessions(includeArchived: true)).single.id,
        'sess-2',
      );
      expect(data.sessions.sessionOnDaemon('daemon', 'sess-1'), isNull);
      expect(data.sessions.sessionOnDaemon('daemon', 'sess-2'), isNotNull);
    },
  );
}
