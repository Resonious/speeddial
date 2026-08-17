import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import 'package:speeddial_app/src/api/daemon_client.dart';
import 'package:speeddial_app/src/api/fake_daemon.dart';

/// Polls until [condition] holds, failing the test after [timeout].
Future<void> _waitUntil(
  Future<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('implements every DaemonClient member', () async {
    // Static conformance: a fake must be usable wherever a DaemonClient is.
    final DaemonClient client = FakeDaemonClient();
    expect(client.isConnected, isTrue);

    // Daemon / projects.
    final DaemonInfo info = await client.info();
    expect(info.version, '0.0.0-fake');
    expect(info.protocolVersion, 1);
    expect(info.providers, hasLength(2));
    final List<Project> projects = await client.listProjects();
    expect(projects, hasLength(1));
    expect(projects.single.name, 'Demo Project');
    expect(projects.single.path, '/demo');

    // Sessions.
    final List<Session> sessions = await client.listSessions();
    expect(sessions, hasLength(2));
    expect(sessions.map((Session s) => s.title),
        <String>['Build the feature', 'Plan the refactor']);
    expect(sessions[0].mode, SessionMode.build);
    expect(sessions[1].mode, SessionMode.plan);

    // Files.
    final List<FileEntry> root = await client.listFiles(projects.single.id);
    expect(root.map((FileEntry e) => e.name),
        <String>['lib', 'main.dart', 'pubspec.yaml']);
    final List<FileEntry> lib = await client.listFiles(projects.single.id, 'lib');
    expect(lib.single.name, 'main.dart');
    final FileReadResult read = await client.readFile(projects.single.id, 'lib/main.dart');
    expect(read.content, contains('runApp'));
    expect(read.isBinary, isFalse);
    final FileReadResult truncated = await client.readFile(projects.single.id, 'lib/main.dart', maxBytes: 6);
    expect(truncated.content, 'import');
    expect(truncated.truncated, isTrue);

    // Git.
    final GitStatus status = await client.gitStatus(projects.single.id);
    expect(status.branch, 'main');
    expect(status.files, hasLength(1));
    final List<GitDiff> diffs = await client.gitDiff(projects.single.id);
    expect(diffs.single.path, 'lib/main.dart');
    final List<Branch> branches = await client.gitBranches(projects.single.id);
    expect(branches.map((Branch b) => b.name), <String>['main', 'feature/x']);
    await client.gitCheckout(projects.single.id, 'feature/x');
    expect((await client.gitStatus(projects.single.id)).branch, 'feature/x');
    final String hash = await client.gitCommit(projects.single.id, 'fix things');
    expect(hash, 'deadbeef');
    expect((await client.gitStatus(projects.single.id)).files, isEmpty);
    await client.gitPush(projects.single.id);
    final String prUrl = await client.gitCreatePr(projects.single.id, title: 'T');
    expect(prUrl, 'https://github.com/speeddial/demo/pull/1');

    await client.dispose();
    expect(client.isConnected, isFalse);
  });

  test('gitCommit rejects an empty message with a git DaemonError', () async {
    final FakeDaemonClient fake = FakeDaemonClient();
    final String projectId = (await fake.listProjects()).single.id;
    await expectLater(
      fake.gitCommit(projectId, ''),
      throwsA(isA<DaemonError>()
          .having((DaemonError e) => e.code, 'code', kErrGit)
          .having((DaemonError e) => e.message, 'message', 'commit message is empty')),
    );
  });

  test('sendMessage streams the documented event sequence', () async {
    final FakeDaemonClient fake = FakeDaemonClient(eventDelay: const Duration(milliseconds: 1));
    final List<SessionEvent> events = <SessionEvent>[];
    final List<Session> updates = <Session>[];
    final StreamSubscription<SessionEvent> eventSub =
        fake.sessionEvents('sess-1').listen(events.add);
    final StreamSubscription<Session> updateSub =
        fake.sessionUpdates.listen(updates.add);

    await fake.sendMessage('sess-1', 'hello');
    await _waitUntil(
        () => Future<bool>.value(events.any((SessionEvent e) => e is TurnCompleteEvent)));

    // Exactly the documented sequence: the user's own message, 3 chunk
    // deltas, tool call (running → completed via a second event), plan
    // (2 entries), usage, turn complete.
    expect(events.map((SessionEvent e) => e.runtimeType).toList(), <Type>[
      UserMessageEvent,
      AgentMessageChunkEvent,
      AgentMessageChunkEvent,
      AgentMessageChunkEvent,
      ToolCallEvent,
      ToolCallEvent,
      PlanEvent,
      UsageEvent,
      TurnCompleteEvent,
    ]);
    expect(
      events.whereType<AgentMessageChunkEvent>().map((AgentMessageChunkEvent e) => e.text).toList(),
      <String>['Working on it…', '```dart\nvoid main() {}\n```', 'Done.'],
    );
    final List<ToolCallEvent> toolCalls = events.whereType<ToolCallEvent>().toList();
    expect(toolCalls, hasLength(2));
    expect(toolCalls[0].toolCall.kind, 'execute');
    expect(toolCalls[0].toolCall.status, ToolCallStatus.running);
    expect(toolCalls[1].toolCall.id, toolCalls[0].toolCall.id);
    expect(toolCalls[1].toolCall.status, ToolCallStatus.completed);
    expect(events.whereType<PlanEvent>().single.entries, hasLength(2));
    expect(events.whereType<UsageEvent>().single.usage.totalTokens, 1500);
    expect(events.last, isA<TurnCompleteEvent>());

    // Status: running at turn start, idle at the end.
    expect(updates.map((Session s) => s.status).toList(),
        <SessionStatus>[SessionStatus.running, SessionStatus.idle]);

    await eventSub.cancel();
    await updateSub.cancel();

    // History reflects the same events, ascending seq starting at 1.
    final List<SessionEvent> history = await fake.history('sess-1');
    expect(history, hasLength(events.length));
    expect(history.map((SessionEvent e) => e.seq).toList(),
        List<int?>.generate(history.length, (int i) => i + 1));
  });

  test('permission script parks until respondPermission', () async {
    final FakeDaemonClient fake = FakeDaemonClient(eventDelay: const Duration(milliseconds: 1));
    final List<SessionEvent> events = <SessionEvent>[];
    final List<Session> updates = <Session>[];
    final StreamSubscription<SessionEvent> eventSub =
        fake.sessionEvents('sess-1').listen(events.add);
    final StreamSubscription<Session> updateSub =
        fake.sessionUpdates.listen(updates.add);

    await fake.sendMessage('sess-1', 'please grant permission');
    await _waitUntil(() => Future<bool>.value(
        events.any((SessionEvent e) => e is PermissionRequestEvent)));

    // Parked: no usage/turnComplete yet; the session is waiting.
    expect(events.any((SessionEvent e) => e is TurnCompleteEvent), isFalse);
    expect(updates.last.status, SessionStatus.waitingPermission);

    final PermissionRequestEvent request = events
        .singleWhere((SessionEvent e) => e is PermissionRequestEvent)
        as PermissionRequestEvent;
    final String requestId = request.request.requestId;
    final String optionId = request.request.options.first.optionId;

    // Resolving with the wrong request id fails like the daemon would.
    await expectLater(
      fake.respondPermission('sess-1', 'nope', optionId),
      throwsA(isA<DaemonError>().having((DaemonError e) => e.code, 'code', kErrNotFound)),
    );

    await fake.respondPermission('sess-1', requestId, optionId);
    await _waitUntil(() => Future<bool>.value(
        events.any((SessionEvent e) => e is TurnCompleteEvent)));

    expect(events.whereType<PermissionResolvedEvent>().single.requestId, requestId);
    expect(events.whereType<PermissionResolvedEvent>().single.optionId, optionId);
    expect(events.whereType<UsageEvent>(), hasLength(1));
    expect(updates.last.status, SessionStatus.idle);

    await eventSub.cancel();
    await updateSub.cancel();
  });

  test('history backfill shows a completed turn without a live listener', () async {
    final FakeDaemonClient fake = FakeDaemonClient(eventDelay: const Duration(milliseconds: 1));

    await fake.sendMessage('sess-1', 'hello');
    // Even with no subscription the events are recorded for history().
    await _waitUntil(() async =>
        (await fake.history('sess-1')).any((SessionEvent e) => e is TurnCompleteEvent));
    final List<SessionEvent> history = await fake.history('sess-1');
    expect(history, hasLength(9));
    expect(history.last, isA<TurnCompleteEvent>());

    // beforeSeq excludes newer events; limit pages from the end.
    final List<SessionEvent> page = await fake.history('sess-1', limit: 3);
    expect(page, hasLength(3));
    expect(page.last, isA<TurnCompleteEvent>());
    final List<SessionEvent> older = await fake.history('sess-1', beforeSeq: 4);
    expect(older.map((SessionEvent e) => e.seq).toList(), <int>[1, 2, 3]);
  });

  test('sendMessage while a turn is running throws a conflict error', () async {
    final FakeDaemonClient fake = FakeDaemonClient(eventDelay: const Duration(milliseconds: 1));
    fake.sessionEvents('sess-1'); // create the live controller eagerly.
    await fake.sendMessage('sess-1', 'hello');
    await expectLater(
      fake.sendMessage('sess-1', 'second turn'),
      throwsA(isA<DaemonError>().having((DaemonError e) => e.code, 'code', kErrConflict)),
    );
    await fake.cancelSession('sess-1');
  });

  test('cancelSession ends the turn with a cancelled stop reason', () async {
    final FakeDaemonClient fake = FakeDaemonClient(eventDelay: const Duration(milliseconds: 25));
    final List<SessionEvent> events = <SessionEvent>[];
    fake.sessionEvents('sess-1').listen(events.add);

    await fake.sendMessage('sess-1', 'hello');
    // Cancel while the script is still streaming its first chunk.
    await Future<void>.delayed(const Duration(milliseconds: 1));
    await fake.cancelSession('sess-1');
    await _waitUntil(() => Future<bool>.value(
        events.any((SessionEvent e) => e is TurnCompleteEvent)));

    expect(events.whereType<TurnCompleteEvent>(), hasLength(1));
    expect(events.whereType<TurnCompleteEvent>().single.stopReason, 'cancelled');
    expect((await fake.listSessions(projectId: 'proj-demo')).singleWhere(
        (Session s) => s.id == 'sess-1').status, SessionStatus.idle);
  });

  test('create/rename/archive/setMode/setModel/delete mutate sessions', () async {
    final FakeDaemonClient fake = FakeDaemonClient();
    final String projectId = (await fake.listProjects()).single.id;

    final Session created = await fake.createSession(
      projectId: projectId,
      providerId: 'omp',
      title: 'Fresh',
    );
    expect(created.status, SessionStatus.idle);
    expect(created.cwd, '/demo');
    expect((await fake.listSessions()), hasLength(3));

    final Session renamed = await fake.renameSession(created.id, 'Renamed');
    expect(renamed.title, 'Renamed');

    final Session planned = await fake.setMode(created.id, SessionMode.plan);
    expect(planned.mode, SessionMode.plan);
    final Session modelled = await fake.setModel(created.id, 'claude-sonnet');
    expect(modelled.model, 'claude-sonnet');

    final Session archived =
        await fake.archiveSession(created.id, true);
    expect(archived.archived, isTrue);
    expect(await fake.listSessions(), hasLength(2)); // archived hidden
    expect(await fake.listSessions(includeArchived: true), hasLength(3));

    await fake.deleteSession(created.id);
    expect(await fake.listSessions(includeArchived: true), hasLength(2));
  });

  test('unknown resources fail with not-found DaemonErrors', () async {
    final FakeDaemonClient fake = FakeDaemonClient();
    final String projectId = (await fake.listProjects()).single.id;
    await expectLater(
      fake.listFiles(projectId, 'nope'),
      throwsA(isA<DaemonError>().having((DaemonError e) => e.code, 'code', kErrNotFound)),
    );
    await expectLater(
      fake.readFile(projectId, 'missing.txt'),
      throwsA(isA<DaemonError>().having((DaemonError e) => e.code, 'code', kErrNotFound)),
    );
    await expectLater(
      fake.addProject('/other'),
      completion(isA<Project>()),
    );
    await expectLater(
      fake.removeProject('does-not-exist'),
      throwsA(isA<DaemonError>().having((DaemonError e) => e.code, 'code', kErrNotFound)),
    );
  });
}
