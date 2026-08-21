import 'dart:async';
import 'dart:convert';

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
    expect(sessions.map((Session s) => s.title), <String>[
      'Build the feature',
      'Plan the refactor',
    ]);
    expect(sessions[0].mode, SessionMode.build);
    expect(sessions[1].mode, SessionMode.plan);

    // Files.
    final List<FileEntry> root = await client.listFiles(projects.single.id);
    expect(root.map((FileEntry e) => e.name), <String>[
      'lib',
      'main.dart',
      'pubspec.yaml',
    ]);
    final List<FileEntry> lib = await client.listFiles(
      projects.single.id,
      'lib',
    );
    expect(lib.single.name, 'main.dart');
    final FileReadResult read = await client.readFile(
      projects.single.id,
      'lib/main.dart',
    );
    expect(read.content, contains('runApp'));
    expect(read.isBinary, isFalse);
    final FileReadResult truncated = await client.readFile(
      projects.single.id,
      'lib/main.dart',
      maxBytes: 6,
    );
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
    final String hash = await client.gitCommit(
      projects.single.id,
      'fix things',
    );
    expect(hash, 'deadbeef');
    expect((await client.gitStatus(projects.single.id)).files, isEmpty);
    await client.gitPush(projects.single.id);
    final String prUrl = await client.gitCreatePr(
      projects.single.id,
      title: 'T',
    );
    expect(prUrl, 'https://github.com/speeddial/demo/pull/1');

    await client.dispose();
    expect(client.isConnected, isFalse);
  });

  test('gitCommit rejects an empty message with a git DaemonError', () async {
    final FakeDaemonClient fake = FakeDaemonClient();
    final String projectId = (await fake.listProjects()).single.id;
    await expectLater(
      fake.gitCommit(projectId, ''),
      throwsA(
        isA<DaemonError>()
            .having((DaemonError e) => e.code, 'code', kErrGit)
            .having(
              (DaemonError e) => e.message,
              'message',
              'commit message is empty',
            ),
      ),
    );
  });

  test('gitMergeToBase merges into the session base branch', () async {
    final FakeDaemonClient fake = FakeDaemonClient();
    final String projectId = (await fake.listProjects()).single.id;

    // sess-1 is seeded with baseBranch 'main'.
    final MergeResult merged = await fake.gitMergeToBase(
      projectId,
      sessionId: 'sess-1',
    );
    expect(merged.baseBranch, 'main');
    expect(merged.sessionBranch, 'main');
    expect(merged.baseFastForwarded, isFalse);
    expect(merged.alreadyUpToDate, isFalse);
    expect(merged.fastForward, isTrue);
    expect(merged.commit, 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef');

    // sess-2 has no base branch: invalid-params DaemonError.
    await expectLater(
      fake.gitMergeToBase(projectId, sessionId: 'sess-2'),
      throwsA(
        isA<DaemonError>()
            .having((DaemonError e) => e.code, 'code', -32602)
            .having(
              (DaemonError e) => e.message,
              'message',
              'session has no base branch',
            ),
      ),
    );
  });

  test('gitRebaseOntoBase rebases onto the session base branch', () async {
    final FakeDaemonClient fake = FakeDaemonClient();
    final String projectId = (await fake.listProjects()).single.id;

    // sess-1 is seeded with baseBranch 'main'.
    final RebaseResult rebased = await fake.gitRebaseOntoBase(
      projectId,
      sessionId: 'sess-1',
    );
    expect(rebased.baseBranch, 'main');
    expect(rebased.sessionBranch, 'main');
    expect(rebased.baseFastForwarded, isFalse);
    expect(rebased.alreadyUpToDate, isFalse);
    expect(rebased.commit, 'feedfacefeedfacefeedfacefeedfacefeedface');

    // sess-2 has no base branch: invalid-params DaemonError.
    await expectLater(
      fake.gitRebaseOntoBase(projectId, sessionId: 'sess-2'),
      throwsA(
        isA<DaemonError>()
            .having((DaemonError e) => e.code, 'code', -32602)
            .having(
              (DaemonError e) => e.message,
              'message',
              'session has no base branch',
            ),
      ),
    );
  });

  test('sendMessage streams the documented event sequence', () async {
    final FakeDaemonClient fake = FakeDaemonClient(
      eventDelay: const Duration(milliseconds: 1),
    );
    final List<SessionEvent> events = <SessionEvent>[];
    final List<Session> updates = <Session>[];
    final StreamSubscription<SessionEvent> eventSub = fake
        .sessionEvents('sess-1')
        .listen(events.add);
    final StreamSubscription<Session> updateSub = fake.sessionUpdates.listen(
      updates.add,
    );

    await fake.sendMessage('sess-1', 'hello');
    await _waitUntil(
      () => Future<bool>.value(
        events.any((SessionEvent e) => e is TurnCompleteEvent),
      ),
    );

    // Exactly the documented sequence: the user's own message, 2 thought
    // deltas, 3 chunk deltas, tool call (running → completed via a second
    // event), plan (2 entries), provider activity, usage, turn complete.
    expect(events.map((SessionEvent e) => e.runtimeType).toList(), <Type>[
      UserMessageEvent,
      AgentThoughtChunkEvent,
      AgentThoughtChunkEvent,
      AgentMessageChunkEvent,
      AgentMessageChunkEvent,
      AgentMessageChunkEvent,
      ToolCallEvent,
      ToolCallEvent,
      PlanEvent,
      AgentActivityEvent,
      UsageEvent,
      TurnCompleteEvent,
    ]);
    expect(
      events
          .whereType<AgentThoughtChunkEvent>()
          .map((AgentThoughtChunkEvent e) => e.text)
          .join(),
      'The user asked a question. I should answer with a short demo response.',
    );
    expect(
      events
          .whereType<AgentMessageChunkEvent>()
          .map((AgentMessageChunkEvent e) => e.text)
          .toList(),
      <String>[
        'Working on it…\n\n',
        '```dart\nvoid main() {}\n```\n\n',
        'Done.',
      ],
    );
    final List<ToolCallEvent> toolCalls = events
        .whereType<ToolCallEvent>()
        .toList();
    expect(toolCalls, hasLength(2));
    expect(toolCalls[0].toolCall.kind, 'execute');
    expect(toolCalls[0].toolCall.status, ToolCallStatus.running);
    expect(toolCalls[1].toolCall.id, toolCalls[0].toolCall.id);
    expect(toolCalls[1].toolCall.status, ToolCallStatus.completed);
    expect(events.whereType<PlanEvent>().single.entries, hasLength(2));
    expect(events.whereType<UsageEvent>().single.usage.totalTokens, 1500);
    expect(events.last, isA<TurnCompleteEvent>());

    // Status: running at turn start, idle at the end.
    expect(updates.map((Session s) => s.status).toList(), <SessionStatus>[
      SessionStatus.running,
      SessionStatus.idle,
    ]);

    await eventSub.cancel();
    await updateSub.cancel();

    // History reflects the same events, ascending seq starting at 1.
    final ({List<SessionEvent> events, bool hasMore}) page0 = await fake
        .history('sess-1');
    expect(page0.hasMore, isFalse);
    expect(page0.events, hasLength(events.length));
    expect(
      page0.events.map((SessionEvent e) => e.seq).toList(),
      List<int?>.generate(page0.events.length, (int i) => i + 1),
    );
  });

  test('permission script parks until respondPermission', () async {
    final FakeDaemonClient fake = FakeDaemonClient(
      eventDelay: const Duration(milliseconds: 1),
    );
    final List<SessionEvent> events = <SessionEvent>[];
    final List<Session> updates = <Session>[];
    final StreamSubscription<SessionEvent> eventSub = fake
        .sessionEvents('sess-1')
        .listen(events.add);
    final StreamSubscription<Session> updateSub = fake.sessionUpdates.listen(
      updates.add,
    );

    await fake.sendMessage('sess-1', 'please grant permission');
    await _waitUntil(
      () => Future<bool>.value(
        events.any((SessionEvent e) => e is PermissionRequestEvent),
      ),
    );

    // Parked: no usage/turnComplete yet; the session is waiting.
    expect(events.any((SessionEvent e) => e is TurnCompleteEvent), isFalse);
    expect(updates.last.status, SessionStatus.waitingPermission);

    final PermissionRequestEvent request = events.singleWhere(
      (SessionEvent e) => e is PermissionRequestEvent,
    ) as PermissionRequestEvent;
    final String requestId = request.request.requestId;
    final String optionId = request.request.options.first.optionId;

    // Resolving with the wrong request id fails like the daemon would.
    await expectLater(
      fake.respondPermission('sess-1', 'nope', optionId),
      throwsA(
        isA<DaemonError>().having(
          (DaemonError e) => e.code,
          'code',
          kErrNotFound,
        ),
      ),
    );

    await fake.respondPermission('sess-1', requestId, optionId);
    await _waitUntil(
      () => Future<bool>.value(
        events.any((SessionEvent e) => e is TurnCompleteEvent),
      ),
    );

    expect(
      events.whereType<PermissionResolvedEvent>().single.requestId,
      requestId,
    );
    expect(
      events.whereType<PermissionResolvedEvent>().single.optionId,
      optionId,
    );
    expect(events.whereType<UsageEvent>(), hasLength(1));
    expect(updates.last.status, SessionStatus.idle);

    await eventSub.cancel();
    await updateSub.cancel();
  });

  test('yolo sessions auto-resolve the permission script', () async {
    final FakeDaemonClient fake = FakeDaemonClient(
      eventDelay: const Duration(milliseconds: 1),
    );
    final Session session = await fake.createSession(
      projectId: (await fake.listProjects()).single.id,
      providerId: 'omp',
      yolo: true,
    );
    expect(session.yolo, isTrue);

    final List<SessionEvent> events = <SessionEvent>[];
    final List<Session> updates = <Session>[];
    final StreamSubscription<SessionEvent> eventSub = fake
        .sessionEvents(session.id)
        .listen(events.add);
    final StreamSubscription<Session> updateSub = fake.sessionUpdates.listen(
      updates.add,
    );

    // The turn completes without respondPermission: the fake resolves the
    // request with the allow option, mirroring the daemon's yolo mode.
    await fake.sendMessage(session.id, 'please grant permission');
    await _waitUntil(
      () => Future<bool>.value(
        events.any((SessionEvent e) => e is TurnCompleteEvent),
      ),
    );

    final PermissionRequestEvent request = events
        .whereType<PermissionRequestEvent>()
        .single;
    final PermissionResolvedEvent resolved = events
        .whereType<PermissionResolvedEvent>()
        .single;
    expect(resolved.requestId, request.request.requestId);
    expect(resolved.optionId, 'allow-once');
    expect(
      updates.map((Session s) => s.status),
      isNot(contains(SessionStatus.waitingPermission)),
      reason: 'a yolo session never parks on the request',
    );

    await eventSub.cancel();
    await updateSub.cancel();
  });

  test(
    'history backfill shows a completed turn without a live listener',
    () async {
      final FakeDaemonClient fake = FakeDaemonClient(
        eventDelay: const Duration(milliseconds: 1),
      );

      await fake.sendMessage('sess-1', 'hello');
      // Even with no subscription the events are recorded for history().
      await _waitUntil(
        () async =>
            (await fake.history('sess-1')).events
                .any((SessionEvent e) => e is TurnCompleteEvent),
      );
      final ({List<SessionEvent> events, bool hasMore}) all = await fake
          .history('sess-1');
      expect(all.hasMore, isFalse);
      expect(all.events, hasLength(12));
      expect(all.events.last, isA<TurnCompleteEvent>());

      // beforeSeq excludes newer events; limit pages from the end.
      final ({List<SessionEvent> events, bool hasMore}) page = await fake
          .history('sess-1', limit: 3);
      expect(page.hasMore, isTrue);
      expect(page.events, hasLength(3));
      expect(page.events.last, isA<TurnCompleteEvent>());
      final ({List<SessionEvent> events, bool hasMore}) older = await fake
          .history('sess-1', beforeSeq: 4);
      expect(older.hasMore, isFalse);
      expect(older.events.map((SessionEvent e) => e.seq).toList(), <int>[
        1,
        2,
        3,
      ]);
    },
  );

  test('history pages backwards with beforeSeq and reports hasMore', () async {
    final FakeDaemonClient fake = FakeDaemonClient();
    // Preload > one page via the seeding helper (seqs assigned 1..5).
    fake.seedHistory('sess-1', <SessionEvent>[
      for (var i = 1; i <= 5; i++) UserMessageEvent(text: 'm$i'),
    ]);

    final ({List<SessionEvent> events, bool hasMore}) all = await fake.history(
      'sess-1',
    );
    expect(all.hasMore, isFalse);
    expect(all.events.map((SessionEvent e) => e.seq).toList(), <int>[
      1,
      2,
      3,
      4,
      5,
    ]);
    expect(
      all.events.map((SessionEvent e) => (e as UserMessageEvent).text),
      <String>['m1', 'm2', 'm3', 'm4', 'm5'],
    );

    final ({List<SessionEvent> events, bool hasMore}) page1 = await fake
        .history('sess-1', limit: 2);
    expect(page1.hasMore, isTrue);
    expect(page1.events.map((SessionEvent e) => e.seq).toList(), <int>[4, 5]);

    final ({List<SessionEvent> events, bool hasMore}) page2 = await fake
        .history('sess-1', limit: 2, beforeSeq: 4);
    expect(page2.hasMore, isTrue);
    expect(page2.events.map((SessionEvent e) => e.seq).toList(), <int>[2, 3]);

    final ({List<SessionEvent> events, bool hasMore}) page3 = await fake
        .history('sess-1', limit: 2, beforeSeq: 2);
    expect(page3.hasMore, isFalse);
    expect(page3.events.map((SessionEvent e) => e.seq).toList(), <int>[1]);

    // Seeded events stay consistent with later live turns (seqs continue).
    fake.seedHistory('sess-1', <SessionEvent>[UserMessageEvent(text: 'm6')]);
    final ({List<SessionEvent> events, bool hasMore}) continued = await fake
        .history('sess-1', beforeSeq: 7);
    expect(continued.events.map((SessionEvent e) => e.seq).toList(), <int>[
      1,
      2,
      3,
      4,
      5,
      6,
    ]);
    expect(
      continued.events.last,
      isA<UserMessageEvent>().having(
        (UserMessageEvent e) => e.text,
        'text',
        'm6',
      ),
    );
  });

  test('forkSession copies history through either side of a message', () async {
    final FakeDaemonClient fake = FakeDaemonClient();
    fake.seedHistory('sess-1', const <SessionEvent>[
      UserMessageEvent(text: 'Question'),
      AgentMessageChunkEvent(text: 'An'),
      AgentMessageChunkEvent(text: 'swer'),
      TurnCompleteEvent(stopReason: 'end_turn'),
      UserMessageEvent(text: 'Later'),
    ]);

    final Session fork = await fake.forkSession('sess-1', 3);
    expect(fork.title, 'Fork of Build the feature');
    expect(fork.cwd, '/demo');
    expect(fork.baseBranch, 'main');
    final List<SessionEvent> history = (await fake.history(fork.id)).events;
    expect(history.map((SessionEvent event) => event.seq), <int>[1, 2, 3]);
    expect((history.first as UserMessageEvent).text, 'Question');
    expect(
      history.whereType<AgentMessageChunkEvent>().map((event) => event.text),
      <String>['An', 'swer'],
    );

    await expectLater(
      fake.forkSession('sess-1', 4),
      throwsA(
        isA<DaemonError>().having(
          (DaemonError error) => error.code,
          'code',
          -32602,
        ),
      ),
    );
  });

  test('projectsChanged emits on add and remove project', () async {
    final FakeDaemonClient fake = FakeDaemonClient();
    int emissions = 0;
    final StreamSubscription<void> sub = fake.projectsChanged.listen(
      (void _) => emissions++,
    );
    addTearDown(sub.cancel);

    await fake.addProject('/work/other', name: 'Other');
    await fake.removeProject('proj-demo');
    await Future<void>.delayed(Duration.zero);
    expect(emissions, 2);
  });

  test('sendMessage with attachments echoes metadata and readAttachment '
      'serves the payloads', () async {
    final FakeDaemonClient fake = FakeDaemonClient(
      eventDelay: const Duration(milliseconds: 1),
    );
    final List<SessionEvent> events = <SessionEvent>[];
    fake.sessionEvents('sess-1').listen(events.add);

    // A 1x1 transparent PNG, so the size is deterministic.
    final List<int> png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhf'
      'DwAChwGA60e6kgAAAABJRU5ErkJggg==',
    );
    await fake.sendMessage(
      'sess-1',
      '',
      attachments: <OutgoingAttachment>[
        OutgoingAttachment(
          name: 'shot.png',
          mimeType: 'image/png',
          data: base64Encode(png),
        ),
        OutgoingAttachment(
          name: 'notes.txt',
          mimeType: 'text/plain',
          data: base64Encode(<int>[104, 105]),
        ),
      ],
    );
    await _waitUntil(
      () => Future<bool>.value(
        events.any((SessionEvent e) => e is TurnCompleteEvent),
      ),
    );

    // The echoed user message carries metadata only, ids assigned in order.
    final UserMessageEvent user = events.first as UserMessageEvent;
    expect(user.text, isEmpty);
    expect(user.attachments, hasLength(2));
    expect(user.attachments[0].id, 'att-1');
    expect(user.attachments[0].name, 'shot.png');
    expect(user.attachments[0].mimeType, 'image/png');
    expect(user.attachments[0].size, png.length);
    expect(user.attachments[1].id, 'att-2');
    expect(user.attachments[1].name, 'notes.txt');
    expect(user.attachments[1].size, 2);

    // readAttachment serves the stored payload, metadata intact.
    final AttachmentData data = await fake.readAttachment('sess-1', 'att-1');
    expect(data.id, 'att-1');
    expect(data.name, 'shot.png');
    expect(data.mimeType, 'image/png');
    expect(data.size, png.length);
    expect(data.data, base64Encode(png));

    // Unknown attachment or session → not-found DaemonError.
    await expectLater(
      fake.readAttachment('sess-1', 'att-99'),
      throwsA(
        isA<DaemonError>().having(
          (DaemonError e) => e.code,
          'code',
          kErrNotFound,
        ),
      ),
    );
    await expectLater(
      fake.readAttachment('nope', 'att-1'),
      throwsA(
        isA<DaemonError>().having(
          (DaemonError e) => e.code,
          'code',
          kErrNotFound,
        ),
      ),
    );

    // Id counters are per-session: a fresh session starts at att-1 again.
    final List<SessionEvent> other = <SessionEvent>[];
    fake.sessionEvents('sess-2').listen(other.add);
    await fake.sendMessage(
      'sess-2',
      'x',
      attachments: <OutgoingAttachment>[
        const OutgoingAttachment(
          name: 'a.txt',
          mimeType: 'text/plain',
          data: 'YQ==',
        ),
      ],
    );
    await _waitUntil(
      () => Future<bool>.value(
        other.any((SessionEvent e) => e is TurnCompleteEvent),
      ),
    );
    expect((other.first as UserMessageEvent).attachments.single.id, 'att-1');
  });

  test('sendMessage while a turn is running throws a conflict error', () async {
    final FakeDaemonClient fake = FakeDaemonClient(
      eventDelay: const Duration(milliseconds: 1),
    );
    fake.sessionEvents('sess-1'); // create the live controller eagerly.
    await fake.sendMessage('sess-1', 'hello');
    await expectLater(
      fake.sendMessage('sess-1', 'second turn'),
      throwsA(
        isA<DaemonError>().having(
          (DaemonError e) => e.code,
          'code',
          kErrConflict,
        ),
      ),
    );
    await fake.cancelSession('sess-1');
  });

  test('cancelSession ends the turn with a cancelled stop reason', () async {
    final FakeDaemonClient fake = FakeDaemonClient(
      eventDelay: const Duration(milliseconds: 25),
    );
    final List<SessionEvent> events = <SessionEvent>[];
    fake.sessionEvents('sess-1').listen(events.add);

    await fake.sendMessage('sess-1', 'hello');
    // Cancel while the script is still streaming its first chunk.
    await Future<void>.delayed(const Duration(milliseconds: 1));
    await fake.cancelSession('sess-1');
    await _waitUntil(
      () => Future<bool>.value(
        events.any((SessionEvent e) => e is TurnCompleteEvent),
      ),
    );

    expect(events.whereType<TurnCompleteEvent>(), hasLength(1));
    expect(
      events.whereType<TurnCompleteEvent>().single.stopReason,
      'cancelled',
    );
    expect(
      (await fake.listSessions(projectId: 'proj-demo'))
          .singleWhere((Session s) => s.id == 'sess-1')
          .status,
      SessionStatus.idle,
    );
  });

  test(
    'create/rename/archive/setMode/setModel/delete mutate sessions',
    () async {
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
      // omp advertises its model list, so only listed ids are settable.
      final Session modelled = await fake.setModel(created.id, 'kimi-k3');
      expect(modelled.model, 'kimi-k3');

      final Session archived = await fake.archiveSession(created.id, true);
      expect(archived.archived, isTrue);
      expect(await fake.listSessions(), hasLength(2)); // archived hidden
      expect(await fake.listSessions(includeArchived: true), hasLength(3));

      await fake.deleteSession(created.id);
      expect(await fake.listSessions(includeArchived: true), hasLength(2));
    },
  );

  test('sendMessage auto-titles a default-titled session', () async {
    final FakeDaemonClient fake = FakeDaemonClient(
      eventDelay: const Duration(milliseconds: 1),
    );
    final String projectId = (await fake.listProjects()).single.id;

    final Session created = await fake.createSession(
      projectId: projectId,
      providerId: 'omp',
    );
    expect(created.title, kDefaultSessionTitle);

    await fake.sendMessage(created.id, 'Fix   the\nflaky test');
    await _waitUntil(
      () async =>
          (await fake.history(created.id)).events
              .any((SessionEvent e) => e is TurnCompleteEvent),
    );
    expect(
      (await fake.listSessions(includeArchived: true))
          .firstWhere((Session s) => s.id == created.id)
          .title,
      'Fix the',
    );

    // Explicit titles survive a send.
    final Session named = await fake.createSession(
      projectId: projectId,
      providerId: 'omp',
      title: 'Keep me',
    );
    await fake.sendMessage(named.id, 'something else');
    await _waitUntil(
      () async =>
          (await fake.history(named.id)).events
              .any((SessionEvent e) => e is TurnCompleteEvent),
    );
    expect(
      (await fake.listSessions(includeArchived: true))
          .firstWhere((Session s) => s.id == named.id)
          .title,
      'Keep me',
    );
  });

  test(
    'createSession seeds models for omp; setModel validates membership',
    () async {
      final FakeDaemonClient fake = FakeDaemonClient();
      final String projectId = (await fake.listProjects()).single.id;
      const List<String> ompModels = <String>[
        'omp-default',
        'kimi-k3',
        'gpt-5.2',
      ];

      // omp sessions advertise three models; a requested id inside the list
      // sticks…
      final Session adopted = await fake.createSession(
        projectId: projectId,
        providerId: 'omp',
        model: 'kimi-k3',
      );
      expect(adopted.models, ompModels);
      expect(adopted.model, 'kimi-k3');

      // …anything else falls back to the omp default (best-effort adoption).
      final Session fallback = await fake.createSession(
        projectId: projectId,
        providerId: 'omp',
        model: 'some/unknown-model',
      );
      expect(fallback.model, 'omp-default');
      expect(fallback.models, ompModels);

      // No model passed: the default applies, matching the sheet's create.
      final Session defaulted = await fake.createSession(
        projectId: projectId,
        providerId: 'omp',
      );
      expect(defaulted.model, 'omp-default');
      expect(defaulted.models, ompModels);

      // Other providers advertise no models and keep the caller's id as-is.
      final Session claude = await fake.createSession(
        projectId: projectId,
        providerId: 'claude',
        model: 'claude-sonnet',
      );
      expect(claude.models, isEmpty);
      expect(claude.model, 'claude-sonnet');
      // Thinking levels still distinguish the same way.
      expect(defaulted.thinkingLevels, const <String>[
        'off',
        'auto',
        'low',
        'high',
        'max',
      ]);
      expect(claude.thinkingLevels, isEmpty);

      // setModel rejects ids outside the advertised list with the raw -32602…
      await expectLater(
        fake.setModel(adopted.id, 'nope'),
        throwsA(
          isA<DaemonError>()
              .having((DaemonError e) => e.code, 'code', -32602)
              .having(
                (DaemonError e) => e.message,
                'message',
                'invalid model: nope; must be one of $ompModels',
              ),
        ),
      );
      // …and adopts ids inside it, propagating the advertised list.
      final Session switched = await fake.setModel(adopted.id, 'gpt-5.2');
      expect(switched.model, 'gpt-5.2');
      expect(switched.models, ompModels);

      // A session with no advertised models accepts any id (a locally
      // persisted preference, like the daemon's non-config providers).
      final Session local = await fake.setModel(claude.id, 'other/claude-x');
      expect(local.model, 'other/claude-x');
      expect(local.models, isEmpty);
    },
  );

  test('unknown resources fail with not-found DaemonErrors', () async {
    final FakeDaemonClient fake = FakeDaemonClient();
    final String projectId = (await fake.listProjects()).single.id;
    await expectLater(
      fake.listFiles(projectId, 'nope'),
      throwsA(
        isA<DaemonError>().having(
          (DaemonError e) => e.code,
          'code',
          kErrNotFound,
        ),
      ),
    );
    await expectLater(
      fake.readFile(projectId, 'missing.txt'),
      throwsA(
        isA<DaemonError>().having(
          (DaemonError e) => e.code,
          'code',
          kErrNotFound,
        ),
      ),
    );
    await expectLater(fake.addProject('/other'), completion(isA<Project>()));
    await expectLater(
      fake.removeProject('does-not-exist'),
      throwsA(
        isA<DaemonError>().having(
          (DaemonError e) => e.code,
          'code',
          kErrNotFound,
        ),
      ),
    );
  });
}
