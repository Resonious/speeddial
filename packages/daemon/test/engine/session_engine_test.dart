@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_daemon/src/engine/session_engine.dart';
import 'package:speeddial_daemon/src/git/git_service.dart';
import 'package:speeddial_daemon/src/providers/provider_registry.dart';
import 'package:speeddial_daemon/src/store/daemon_store.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:test/test.dart';

/// Resolves the fake ACP agent fixture whether the runner's cwd is the
/// package dir (`dart test` in packages/daemon) or the repo root
/// (`dart test packages/daemon`).
String resolveFixture() => <String>[
      p.join(Directory.current.path, 'test', 'fixtures', 'fake_acp_agent.dart'),
      p.join(
          Directory.current.path, 'packages', 'daemon', 'test', 'fixtures',
          'fake_acp_agent.dart'),
    ].firstWhere((path) => File(path).existsSync());

/// A registry whose only provider is the fake ACP fixture, spawned through
/// the current Dart VM.
ProviderRegistry fakeProviders() => ProviderRegistry(configOverrides: <String, Object?>{
      'providers': <String, Object?>{
        'fake': <String, Object?>{
          'name': 'Fake Agent',
          'command': <String>[Platform.resolvedExecutable, resolveFixture()],
        },
      },
    });

void main() {
  late Directory tempDir;
  late DaemonStore store;
  late SessionEngine engine;
  late Project project;
  late StreamSubscription<({String sessionId, int seq, SessionEvent event})>
      eventsSub;
  late StreamSubscription<Session> changesSub;
  late StreamSubscription<String> removalsSub;
  final events = <({String sessionId, int seq, SessionEvent event})>[];
  final changes = <Session>[];
  final removals = <String>[];

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('session_engine_test');
    // The fixture's fs/read_text_file target defaults to `<cwd>/example.txt`.
    File(p.join(tempDir.path, 'example.txt'))
        .writeAsStringSync('hello from file\n');
    store = DaemonStore(p.join(tempDir.path, 'speeddial.db'));
    project = Project(
      id: 'p1',
      name: 'Demo Project',
      path: tempDir.path,
      addedAt: DateTime.now().toUtc(),
      lastActiveAt: DateTime.now().toUtc(),
    );
    store.insertProject(project);
    engine = SessionEngine(store: store, providers: fakeProviders());
    await engine.restore();
    events.clear();
    changes.clear();
    removals.clear();
    eventsSub = engine.events.listen(events.add);
    changesSub = engine.sessionChanges.listen(changes.add);
    removalsSub = engine.sessionRemovals.listen(removals.add);
  });

  tearDown(() async {
    await eventsSub.cancel();
    await changesSub.cancel();
    await removalsSub.cancel();
    await engine.dispose();
    store.dispose();
    try {
      await tempDir.delete(recursive: true);
    } on Object {
      // Cleanup failure is not a test failure.
    }
  });

  /// Completes when [target] emits a PermissionRequestEvent.
  Future<PermissionRequestEvent> waitForPermissionRequestOn(
      SessionEngine target) async {
    final seen = Completer<PermissionRequestEvent>();
    final sub = target.events.listen((tuple) {
      final event = tuple.event;
      if (event is PermissionRequestEvent && !seen.isCompleted) {
        seen.complete(event);
      }
    });
    final request = await seen.future;
    await sub.cancel();
    return request;
  }

  /// Completes when the engine emits a PermissionRequestEvent.
  Future<PermissionRequestEvent> waitForPermissionRequest() =>
      waitForPermissionRequestOn(engine);

  /// Polls until [condition] holds, failing the test after [timeout].
  Future<void> waitFor(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final DateTime deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('condition did not become true within $timeout');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('createSession spawns an idle session and persists it', () async {
    final session =
        await engine.createSession(projectId: 'p1', providerId: 'fake');

    expect(session.title, 'New session');
    expect(session.status, SessionStatus.idle);
    expect(session.mode, SessionMode.build);
    // The model is agent-reported: no explicit model was passed, so the
    // fake's current model is adopted.
    expect(session.model, 'fake-fast');
    expect(session.cwd, tempDir.path);
    expect(session.projectId, 'p1');
    expect(session.archived, isFalse);

    // Persisted and published.
    final stored = store.getSession(session.id)!;
    expect(stored.id, session.id);
    expect(stored.status, SessionStatus.idle);
    expect(changes.last.id, session.id);
    expect(changes.last.status, SessionStatus.idle);
  });

  test('sendMessage streams ordered events with merged tool calls and '
      'permission handshake', () async {
    final session =
        await engine.createSession(projectId: 'p1', providerId: 'fake');

    final permissionFuture = waitForPermissionRequest();
    final send = engine.sendMessage(session.id, 'please edit the file');
    final request = await permissionFuture;

    // The agent asked for permission; the turn must not finish until we
    // respond.
    expect(request.request.toolCallId, 'tc1');
    expect(request.request.title, 'Read example.txt');
    expect(
      request.request.options.map((o) => o.optionId),
      <String>['allow', 'reject'],
    );
    expect(request.request.options.first.kind, PermissionKind.allowAlways);
    expect(request.request.options.last.kind, PermissionKind.rejectOnce);

    var sendDone = false;
    unawaited(send.then((_) {
      sendDone = true;
    }));
    await Future<void>.delayed(Duration.zero);
    expect(sendDone, isFalse,
        reason: 'the turn is parked until respondPermission');

    await engine.respondPermission(session.id, request.request.requestId, 'allow');
    await send;
    expect(sendDone, isTrue);

    // Session status walked through the full turn lifecycle.
    expect(
      changes.map((s) => s.status).toList(),
      <SessionStatus>[
        SessionStatus.idle, // created
        SessionStatus.idle, // auto-titled while still idle
        SessionStatus.running,
        SessionStatus.waitingPermission,
        SessionStatus.running,
        SessionStatus.idle,
      ],
    );

    // Events arrive in the order the agent produced them.
    expect(
      events.map((t) => t.event.runtimeType).toList(),
      <Type>[
        UserMessageEvent,
        AgentMessageChunkEvent,
        AgentMessageChunkEvent,
        ToolCallEvent, // created
        ToolCallEvent, // completed (merged)
        PlanEvent,
        PermissionRequestEvent,
        PermissionResolvedEvent,
        UsageEvent,
        TurnCompleteEvent,
      ],
    );

    // seq runs 1..N and matches the persisted event metadata.
    for (var i = 0; i < events.length; i++) {
      expect(events[i].seq, i + 1);
      expect(events[i].event.seq, i + 1);
      expect(events[i].sessionId, session.id);
    }

    final user = events[0].event as UserMessageEvent;
    expect(user.text, 'please edit the file');
    expect((events[1].event as AgentMessageChunkEvent).text,
        'I will inspect the target file.');
    expect((events[2].event as AgentMessageChunkEvent).text,
        'Reading its contents first.');

    final created = events[3].event as ToolCallEvent;
    expect(created.toolCall.id, 'tc1');
    expect(created.toolCall.status, ToolCallStatus.running);
    expect(created.toolCall.kind, 'read');
    expect(created.toolCall.title, 'Read example.txt');
    expect(created.toolCall.locations, <String>['example.txt']);

    // The update merged onto the created call: state carried over.
    final updated = events[4].event as ToolCallEvent;
    expect(updated.toolCall.id, 'tc1');
    expect(updated.toolCall.status, ToolCallStatus.completed);
    expect(updated.toolCall.title, 'Read example.txt');
    expect(updated.toolCall.kind, 'read');
    expect(updated.toolCall.locations, <String>['example.txt']);
    expect(
      (updated.toolCall.rawOutput! as Map)['content'],
      'hello from file\n',
    );

    final plan = events[5].event as PlanEvent;
    expect(plan.entries, hasLength(2));
    expect(plan.entries.first.content, 'Read the target file');
    expect(plan.entries.first.priority, PlanPriority.high);
    expect(plan.entries.first.status, PlanEntryStatus.inProgress);
    expect(plan.entries.last.priority, PlanPriority.medium);
    expect(plan.entries.last.status, PlanEntryStatus.pending);

    final permission = events[6].event as PermissionRequestEvent;
    final resolved = events[7].event as PermissionResolvedEvent;
    expect(resolved.requestId, permission.request.requestId);
    expect(resolved.optionId, 'allow');

    final usage = events[8].event as UsageEvent;
    expect(usage.usage.totalTokens, 250);
    expect(usage.usage.outputTokens, 250);
    expect(usage.usage.cost, '0.012');

    expect((events[9].event as TurnCompleteEvent).stopReason, 'end_turn');
  });

  test('yolo sessions auto-approve permission requests', () async {
    final session = await engine.createSession(
      projectId: 'p1',
      providerId: 'fake',
      yolo: true,
    );
    expect(session.yolo, isTrue);
    expect(store.getSession(session.id)!.yolo, isTrue,
        reason: 'the flag must persist for restarts/resume');

    // The turn completes without respondPermission: the engine resolves the
    // agent's request itself with the allow_always option.
    await engine.sendMessage(session.id, 'please edit the file');

    expect(store.getSession(session.id)!.status, SessionStatus.idle);
    expect(
      changes.map((s) => s.status),
      isNot(contains(SessionStatus.waitingPermission)),
      reason: 'yolo resolution never parks the session',
    );

    final request = events
        .firstWhere((e) => e.event is PermissionRequestEvent)
        .event as PermissionRequestEvent;
    final resolved = events
        .firstWhere((e) => e.event is PermissionResolvedEvent)
        .event as PermissionResolvedEvent;
    expect(resolved.requestId, request.request.requestId);
    expect(resolved.optionId, 'allow',
        reason: 'the allow_always option wins');

    // The auto-resolved request was never parked: a late respondPermission
    // is not-found, not a conflict or a no-op success.
    await expectLater(
      engine.respondPermission(session.id, request.request.requestId, 'reject'),
      throwsA(
          isA<DaemonError>().having((e) => e.code, 'code', kErrNotFound)),
    );
  });

  test('events are persisted and replayable from the store', () async {
    final session =
        await engine.createSession(projectId: 'p1', providerId: 'fake');
    final permissionFuture = waitForPermissionRequest();
    final send = engine.sendMessage(session.id, 'please edit the file');
    final request = await permissionFuture;
    await engine.respondPermission(session.id, request.request.requestId, 'allow');
    await send;

    final history = store.listEvents(session.id);
    expect(history.hasMore, isFalse);
    expect(history.events, hasLength(events.length));
    for (var i = 0; i < events.length; i++) {
      expect(history.events[i].seq, events[i].seq);
      expect(history.events[i].runtimeType, events[i].event.runtimeType);
    }
    // Events survive a fresh engine over the same database.
    final fresh = SessionEngine(store: store, providers: fakeProviders());
    await fresh.restore();
    final replayed = store.listEvents(session.id).events;
    expect(replayed, hasLength(events.length));
    expect((replayed.first as UserMessageEvent).text, isNotEmpty);
    await fresh.dispose();
  });

  test('restore keeps idle sessions idle and sendMessage resumes them',
      () async {
    final session =
        await engine.createSession(projectId: 'p1', providerId: 'fake');
    expect(store.getSession(session.id)!.status, SessionStatus.idle);

    // Daemon restart: the agent process is gone, the row persists.
    await engine.dispose();
    final restarted = SessionEngine(store: store, providers: fakeProviders());
    await restarted.restore();
    final restored = store.getSession(session.id)!;
    expect(restored.status, SessionStatus.idle);

    // The next send respawns the agent and resumes the ACP session.
    final permissionFuture = waitForPermissionRequestOn(restarted);
    final send = restarted.sendMessage(session.id, 'please edit the file');
    final request = await permissionFuture;
    await restarted.respondPermission(session.id, request.request.requestId, 'allow');
    await send;
    expect(store.getSession(session.id)!.status, SessionStatus.idle);
    final replayed = store.listEvents(session.id).events;
    expect(replayed.first, isA<UserMessageEvent>());
    expect(replayed.last, isA<TurnCompleteEvent>());
    await restarted.dispose();
  });

  test('restore flags a turn interrupted by the restart; send resumes the '
      'session anyway', () async {
    final session =
        await engine.createSession(projectId: 'p1', providerId: 'fake');
    final hung = engine.sendMessage(session.id, 'hang');
    await waitFor(() => store.getSession(session.id)!.status ==
        SessionStatus.running);

    // The daemon dies mid-turn.
    await engine.dispose();
    await hung; // the killed agent's turn unwinds quietly
    final restarted = SessionEngine(store: store, providers: fakeProviders());
    await restarted.restore();

    // Interrupted: error status plus a persisted explanation in history.
    expect(store.getSession(session.id)!.status, SessionStatus.error);
    final note = store.listEvents(session.id).events.last;
    expect(note, isA<SessionErrorEvent>());
    expect((note as SessionErrorEvent).message,
        contains('restarted'));

    // …but usable: the next send resumes the agent and runs a normal turn.
    final permissionFuture = waitForPermissionRequestOn(restarted);
    final send = restarted.sendMessage(session.id, 'please edit the file');
    final request = await permissionFuture;
    await restarted.respondPermission(session.id, request.request.requestId, 'allow');
    await send;
    expect(store.getSession(session.id)!.status, SessionStatus.idle);
    await restarted.dispose();
  });

  test('sendMessage after a restart reports unresumable sessions', () async {
    final now = DateTime.now().toUtc();

    // A session row persisted before resume support has no ACP session id.
    store.insertSession(Session(
      id: 'legacy',
      projectId: 'p1',
      providerId: 'fake',
      title: 'Legacy',
      status: SessionStatus.idle,
      mode: SessionMode.build,
      model: null,
      cwd: tempDir.path,
      baseBranch: null,
      yolo: false,
      archived: false,
      createdAt: now,
      updatedAt: now,
    ));
    // A closed session is never resumed.
    final closed =
        await engine.createSession(projectId: 'p1', providerId: 'fake');
    store.updateSession(Session(
      id: closed.id,
      projectId: closed.projectId,
      providerId: closed.providerId,
      title: closed.title,
      status: SessionStatus.closed,
      mode: closed.mode,
      model: closed.model,
      cwd: closed.cwd,
      baseBranch: closed.baseBranch,
      yolo: closed.yolo,
      archived: closed.archived,
      createdAt: closed.createdAt,
      updatedAt: DateTime.now().toUtc(),
    ));
    await engine.dispose();

    final restarted = SessionEngine(store: store, providers: fakeProviders());
    await restarted.restore();
    await expectLater(
      restarted.sendMessage('legacy', 'hi'),
      throwsA(isA<DaemonError>()
          .having((e) => e.code, 'code', kErrConflict)),
    );
    await expectLater(
      restarted.sendMessage(closed.id, 'hi'),
      throwsA(isA<DaemonError>()
          .having((e) => e.code, 'code', kErrConflict)),
    );
    await expectLater(
      restarted.sendMessage('no-such-session', 'hi'),
      throwsA(isA<DaemonError>()
          .having((e) => e.code, 'code', kErrNotFound)),
    );
    await restarted.dispose();
  });

  test('resume fails cleanly when the provider lacks session/load support',
      () async {
    final session =
        await engine.createSession(projectId: 'p1', providerId: 'fake');
    await engine.dispose();
    // The next agent the engine spawns advertises no loadSession capability.
    File(p.join(tempDir.path, 'agent.no_load_session')).createSync();

    final restarted = SessionEngine(store: store, providers: fakeProviders());
    await restarted.restore();
    await expectLater(
      restarted.sendMessage(session.id, 'hi'),
      throwsA(isA<DaemonError>()
          .having((e) => e.code, 'code', kErrConflict)),
    );
    // The refusal says nothing about the agent's state: status untouched.
    expect(store.getSession(session.id)!.status, SessionStatus.idle);
    await restarted.dispose();
  });

  test('resume marks the session error when the agent lost its own state',
      () async {
    final session =
        await engine.createSession(projectId: 'p1', providerId: 'fake');
    await engine.dispose();
    // The next agent answers session/load with an error.
    File(p.join(tempDir.path, 'agent.load_fails')).createSync();

    final restarted = SessionEngine(store: store, providers: fakeProviders());
    await restarted.restore();
    await expectLater(
      restarted.sendMessage(session.id, 'hi'),
      throwsA(isA<DaemonError>()
          .having((e) => e.code, 'code', kErrAgentProcess)),
    );
    expect(store.getSession(session.id)!.status, SessionStatus.error);
    await restarted.dispose();
  });

  test('concurrent sends after a restart share one resume; the second '
      'conflicts', () async {
    final session =
        await engine.createSession(projectId: 'p1', providerId: 'fake');
    await engine.dispose();
    final restarted = SessionEngine(store: store, providers: fakeProviders());
    await restarted.restore();

    final first = restarted.sendMessage(session.id, 'weird');
    await expectLater(
      restarted.sendMessage(session.id, 'weird'),
      throwsA(isA<DaemonError>()
          .having((e) => e.code, 'code', kErrConflict)),
    );
    await first; // the resumed session completes its turn
    expect(store.getSession(session.id)!.status, SessionStatus.idle);
    await restarted.dispose();
  });


  test('sendMessage conflicts while a turn is running, and cancel finishes it',
      () async {
    final session =
        await engine.createSession(projectId: 'p1', providerId: 'fake');
    final first = engine.sendMessage(session.id, 'hang');

    await expectLater(
      engine.sendMessage(session.id, 'second message'),
      throwsA(isA<DaemonError>()
          .having((e) => e.code, 'code', kErrConflict)),
    );

    await engine.cancel(session.id);
    await first; // resolves with the cancelled stop reason

    expect(
      events.map((t) => t.event.runtimeType).toList(),
      <Type>[UserMessageEvent, TurnCompleteEvent],
    );
    expect((events.last.event as TurnCompleteEvent).stopReason, 'cancelled');
    expect(changes.last.status, SessionStatus.idle);

    // The session is usable again afterwards.
    final sendAgain = engine.sendMessage(session.id, 'cancel');
    await engine.cancel(session.id);
    await sendAgain;
  });

  test('cancel resolves a pending turn with the cancelled stop reason',
      () async {
    final session =
        await engine.createSession(projectId: 'p1', providerId: 'fake');
    final send = engine.sendMessage(session.id, 'cancel');
    await engine.cancel(session.id);
    await send;
    expect(
      events.map((t) => t.event.runtimeType).toList(),
      <Type>[UserMessageEvent, TurnCompleteEvent],
    );
    expect((events.last.event as TurnCompleteEvent).stopReason, 'cancelled');
    expect(changes.last.status, SessionStatus.idle);
  });

  test('respondPermission rejects unknown or expired requests', () async {
    final session =
        await engine.createSession(projectId: 'p1', providerId: 'fake');
    await expectLater(
      engine.respondPermission(session.id, 'missing-request', 'allow'),
      throwsA(isA<DaemonError>()
          .having((e) => e.code, 'code', kErrNotFound)),
    );
    await expectLater(
      engine.respondPermission(session.id, 'also-missing', 'reject'),
      throwsA(isA<DaemonError>()
          .having((e) => e.code, 'code', kErrNotFound)),
    );
  });

  test('rename, archive, setMode and setModel persist and notify', () async {
    final session =
        await engine.createSession(projectId: 'p1', providerId: 'fake');

    final renamed = await engine.rename(session.id, 'My Session');
    expect(renamed.title, 'My Session');

    final archived = await engine.archive(session.id, true);
    expect(archived.archived, isTrue);

    final planned = await engine.setMode(session.id, SessionMode.plan);
    expect(planned.mode, SessionMode.plan);

    // The fake advertises the model option; setModel validates against it.
    final withModel = await engine.setModel(session.id, 'fake-smart');
    expect(withModel.model, 'fake-smart');

    final reloaded = store.getSession(session.id)!;
    expect(reloaded.title, 'My Session');
    expect(reloaded.archived, isTrue);
    expect(reloaded.mode, SessionMode.plan);
    expect(reloaded.model, 'fake-smart');
    // The advertised models survive every copy helper (rename/archive/
    // setMode/setModel) — the constructor default would silently wipe them.
    expect(reloaded.models, <String>['fake-fast', 'fake-smart']);

    // Metadata changes surfaced on sessionChanges.
    expect(changes.where((s) => s.id == session.id).last.title, 'My Session');
    expect(
      changes.where((s) => s.id == session.id).map((s) => s.mode),
      contains(SessionMode.plan),
    );

    // The session list honours the archived flag.
    expect(store.listSessions().map((s) => s.id), isNot(contains(session.id)));
    expect(
      store.listSessions(includeArchived: true).map((s) => s.id),
      contains(session.id),
    );
  });

  test('the first user message auto-titles a default-titled session', () async {
    // Yolo auto-approves the scripted permission so the turn completes
    // without a client handshake.
    final session = await engine.createSession(
        projectId: 'p1', providerId: 'fake', yolo: true);
    expect(session.title, kDefaultSessionTitle);

    await engine.sendMessage(session.id, 'Fix   the\nflaky test now');

    // First line only, whitespace-collapsed; broadcast on sessionChanges.
    expect(store.getSession(session.id)!.title, 'Fix the');
    expect(changes.where((s) => s.id == session.id).last.title, 'Fix the');

    // Long first lines truncate to 60 characters.
    final truncating = await engine.createSession(
        projectId: 'p1', providerId: 'fake', yolo: true);
    await engine.sendMessage(truncating.id, 'a' * 61);
    expect(store.getSession(truncating.id)!.title, '${'a' * 60}…');

    // Explicit titles are never clobbered.
    final explicit = await engine.createSession(
        projectId: 'p1', providerId: 'fake', yolo: true, title: 'Keep me');
    await engine.sendMessage(explicit.id, 'a brand new task');
    expect(store.getSession(explicit.id)!.title, 'Keep me');
  });

  test("createSession adopts the agent's advertised thinking level and "
      'options', () async {
    final session =
        await engine.createSession(projectId: 'p1', providerId: 'fake');

    expect(session.thinkingLevel, 'auto');
    expect(
      session.thinkingLevels,
      <String>['off', 'auto', 'low', 'high', 'max'],
    );

    // Persisted, and survived the copy helpers used by status changes and
    // metadata updates.
    final stored = store.getSession(session.id)!;
    expect(stored.thinkingLevel, 'auto');
    expect(
      stored.thinkingLevels,
      <String>['off', 'auto', 'low', 'high', 'max'],
    );
  });

  test('setThinkingLevel forwards the choice to the agent and persists the '
      'agent-reported state', () async {
    final session =
        await engine.createSession(projectId: 'p1', providerId: 'fake');

    final updated = await engine.setThinkingLevel(session.id, 'high');
    expect(updated.thinkingLevel, 'high');
    expect(
      updated.thinkingLevels,
      <String>['off', 'auto', 'low', 'high', 'max'],
    );

    final stored = store.getSession(session.id)!;
    expect(stored.thinkingLevel, 'high');
    expect(
      stored.thinkingLevels,
      <String>['off', 'auto', 'low', 'high', 'max'],
    );
    // The fake agent recorded the applied value.
    expect(
      File(p.join(tempDir.path, 'agent.thinking')).readAsStringSync(),
      'high',
    );
    // The change surfaced on sessionChanges.
    expect(
      changes.where((s) => s.id == session.id).last.thinkingLevel,
      'high',
    );
  });

  test('setThinkingLevel rejects invalid levels, unsupported providers, and '
      'unknown sessions', () async {
    final session =
        await engine.createSession(projectId: 'p1', providerId: 'fake');

    await expectLater(
      engine.setThinkingLevel(session.id, 'nope'),
      throwsA(isA<DaemonError>()
          .having((e) => e.code, 'code', -32602)
          .having((e) => e.message, 'message', contains('valid levels'))),
    );

    // A provider without a thinking option accepts no level at all.
    File(p.join(tempDir.path, 'agent.no_thinking')).createSync();
    final plain = await engine.createSession(
        projectId: 'p1', providerId: 'fake');
    expect(plain.thinkingLevel, isNull);
    expect(plain.thinkingLevels, isEmpty);
    await expectLater(
      engine.setThinkingLevel(plain.id, 'auto'),
      throwsA(isA<DaemonError>()
          .having((e) => e.code, 'code', -32602)
          .having((e) => e.message, 'message',
              contains('does not expose a thinking level option'))),
    );

    // Unknown session → kErrNotFound.
    await expectLater(
      engine.setThinkingLevel('nope', 'auto'),
      throwsA(isA<DaemonError>().having((e) => e.code, 'code', kErrNotFound)),
    );
  });

  test('offline setThinkingLevel persists locally; the resume reapplies it',
      () async {
    final session =
        await engine.createSession(projectId: 'p1', providerId: 'fake');

    // Daemon restart: the agent process is gone, the row persists.
    await engine.dispose();
    final restarted = SessionEngine(store: store, providers: fakeProviders());
    await restarted.restore();
    // No live agent: the choice is persisted locally.
    final offline = await restarted.setThinkingLevel(session.id, 'low');
    expect(offline.thinkingLevel, 'low');
    expect(store.getSession(session.id)!.thinkingLevel, 'low');

    // The next send respawns the agent and reapplies the persisted level.
    final permissionFuture = waitForPermissionRequestOn(restarted);
    final send = restarted.sendMessage(session.id, 'please edit the file');
    final request = await permissionFuture;
    await restarted.respondPermission(
        session.id, request.request.requestId, 'allow');
    await send;
    expect(
      File(p.join(tempDir.path, 'agent.thinking')).readAsStringSync(),
      'low',
      reason: 'the resumed agent must have received the persisted level',
    );
    expect(store.getSession(session.id)!.thinkingLevel, 'low');
    await restarted.dispose();
  });

  test('resume adopts the agent-reported level when the persisted choice is '
      'no longer offered', () async {
    final session =
        await engine.createSession(projectId: 'p1', providerId: 'fake');

    // A persisted choice the agent no longer advertises must not be
    // reapplied; the load-reported state wins instead.
    await engine.dispose();
    final stored = store.getSession(session.id)!;
    store.updateSession(Session(
      id: stored.id,
      projectId: stored.projectId,
      providerId: stored.providerId,
      title: stored.title,
      status: stored.status,
      mode: stored.mode,
      model: stored.model,
      cwd: stored.cwd,
      baseBranch: stored.baseBranch,
      thinkingLevel: 'turbo',
      thinkingLevels: stored.thinkingLevels,
      yolo: stored.yolo,
      archived: stored.archived,
      createdAt: stored.createdAt,
      updatedAt: stored.updatedAt,
    ));
    final restarted = SessionEngine(store: store, providers: fakeProviders());
    await restarted.restore();

    final permissionFuture = waitForPermissionRequestOn(restarted);
    final send = restarted.sendMessage(session.id, 'please edit the file');
    final request = await permissionFuture;
    await restarted.respondPermission(
        session.id, request.request.requestId, 'allow');
    await send;

    expect(
      store.getSession(session.id)!.thinkingLevel,
      'auto',
      reason: 'the stale persisted level is replaced by the load state',
    );
    expect(
      File(p.join(tempDir.path, 'agent.thinking')).existsSync(),
      isFalse,
      reason: 'a level the agent does not offer is never sent',
    );
    await restarted.dispose();
  });

  test("createSession adopts the agent's advertised model and models list",
      () async {
    final session =
        await engine.createSession(projectId: 'p1', providerId: 'fake');

    expect(session.model, 'fake-fast');
    expect(session.models, <String>['fake-fast', 'fake-smart']);

    // Persisted, and survived the copy helpers used by status changes and
    // metadata updates.
    final stored = store.getSession(session.id)!;
    expect(stored.model, 'fake-fast');
    expect(
      stored.models,
      <String>['fake-fast', 'fake-smart'],
    );
  });

  test('createSession applies an explicitly requested listed model', () async {
    final session = await engine.createSession(
        projectId: 'p1', providerId: 'fake', model: 'fake-smart');
    expect(session.model, 'fake-smart');
    expect(session.models, <String>['fake-fast', 'fake-smart']);
    expect(store.getSession(session.id)!.model, 'fake-smart');
  });

  test('setModel forwards the choice to the agent and persists the '
      'agent-reported state', () async {
    final session =
        await engine.createSession(projectId: 'p1', providerId: 'fake');

    final updated = await engine.setModel(session.id, 'fake-smart');
    expect(updated.model, 'fake-smart');
    expect(updated.models, <String>['fake-fast', 'fake-smart']);

    final stored = store.getSession(session.id)!;
    expect(stored.model, 'fake-smart');
    expect(stored.models, <String>['fake-fast', 'fake-smart']);
    // The fake agent recorded the applied value.
    expect(
      File(p.join(tempDir.path, 'agent.model')).readAsStringSync(),
      'fake-smart',
    );
    // The change surfaced on sessionChanges.
    expect(
      changes.where((s) => s.id == session.id).last.model,
      'fake-smart',
    );
  });

  test('setModel rejects unlisted models; behind agent.no_model any string '
      'is a local preference', () async {
    final session =
        await engine.createSession(projectId: 'p1', providerId: 'fake');

    await expectLater(
      engine.setModel(session.id, 'nope'),
      throwsA(isA<DaemonError>()
          .having((e) => e.code, 'code', -32602)
          .having((e) => e.message, 'message', contains('2 models advertised'))),
    );

    // A provider without a model option accepts any string as a plain
    // local preference, with no validation and no forwarding.
    File(p.join(tempDir.path, 'agent.no_model')).createSync();
    final plain = await engine.createSession(
        projectId: 'p1', providerId: 'fake');
    expect(plain.model, isNull);
    expect(plain.models, isEmpty);
    final legacy = await engine.setModel(plain.id, 'claude-sonnet');
    expect(legacy.model, 'claude-sonnet');
    expect(legacy.models, isEmpty);
    expect(store.getSession(plain.id)!.model, 'claude-sonnet');
    // Never forwarded: the agent recorded no model.
    expect(
      File(p.join(tempDir.path, 'agent.model')).existsSync(),
      isFalse,
    );

    // Unknown session → kErrNotFound.
    await expectLater(
      engine.setModel('nope', 'fake-fast'),
      throwsA(isA<DaemonError>().having((e) => e.code, 'code', kErrNotFound)),
    );
  });

  test('offline setModel persists locally; the resume reapplies it',
      () async {
    final session =
        await engine.createSession(projectId: 'p1', providerId: 'fake');

    // Daemon restart: the agent process is gone, the row persists.
    await engine.dispose();
    final restarted = SessionEngine(store: store, providers: fakeProviders());
    await restarted.restore();
    // No live agent: the choice is persisted locally. A fresh agent process
    // reports 'fake-fast' as current, so the persisted 'fake-smart' differs
    // and must be reapplied on resume.
    final offline = await restarted.setModel(session.id, 'fake-smart');
    expect(offline.model, 'fake-smart');
    expect(store.getSession(session.id)!.model, 'fake-smart');

    // The next send respawns the agent and reapplies the persisted model.
    final permissionFuture = waitForPermissionRequestOn(restarted);
    final send = restarted.sendMessage(session.id, 'please edit the file');
    final request = await permissionFuture;
    await restarted.respondPermission(
        session.id, request.request.requestId, 'allow');
    await send;
    expect(
      File(p.join(tempDir.path, 'agent.model')).readAsStringSync(),
      'fake-smart',
      reason: 'the resumed agent must have received the persisted model',
    );
    expect(store.getSession(session.id)!.model, 'fake-smart');
    expect(
      store.getSession(session.id)!.models,
      <String>['fake-fast', 'fake-smart'],
    );
    await restarted.dispose();
  });

  test('setModel adoption is total: thinking fields keep the agent-reported '
      'state', () async {
    final session =
        await engine.createSession(projectId: 'p1', providerId: 'fake');
    await engine.setThinkingLevel(session.id, 'high');

    // The set_config_option response is authoritative for ALL config-backed
    // fields: a model switch re-adopts the thinking fields from the same
    // response — neither wiped nor left stale.
    final updated = await engine.setModel(session.id, 'fake-smart');
    expect(updated.model, 'fake-smart');
    expect(updated.thinkingLevel, 'high');
    expect(
      updated.thinkingLevels,
      <String>['off', 'auto', 'low', 'high', 'max'],
    );

    final stored = store.getSession(session.id)!;
    expect(stored.model, 'fake-smart');
    expect(stored.thinkingLevel, 'high');
    expect(
      stored.thinkingLevels,
      <String>['off', 'auto', 'low', 'high', 'max'],
    );
  });

  test('delete removes the session, cascades events, and emits removal',
      () async {
    final session =
        await engine.createSession(projectId: 'p1', providerId: 'fake');
    final send = engine.sendMessage(session.id, 'cancel');
    await engine.cancel(session.id);
    await send;
    final eventCount = store.listEvents(session.id).events.length;
    expect(eventCount, greaterThan(0));

    await engine.delete(session.id);

    expect(removals, <String>[session.id]);
    expect(store.getSession(session.id), isNull);
    expect(store.listEvents(session.id).events, isEmpty,
        reason: 'session events cascade away with the session');

    // Idempotency guard: deleting again errors not-found.
    await expectLater(
      engine.delete(session.id),
      throwsA(isA<DaemonError>()
          .having((e) => e.code, 'code', kErrNotFound)),
    );
  });

  test('createSession validates project and provider availability', () async {
    await expectLater(
      engine.createSession(projectId: 'nope', providerId: 'fake'),
      throwsA(isA<DaemonError>().having((e) => e.code, 'code', kErrNotFound)),
    );
    await expectLater(
      engine.createSession(projectId: 'p1', providerId: 'nope'),
      throwsA(isA<DaemonError>()
          .having((e) => e.code, 'code', kErrProviderUnavailable)),
    );

    // Known provider whose command does not resolve.
    final offline = SessionEngine(
      store: store,
      providers: ProviderRegistry(configOverrides: <String, Object?>{
        'providers': <String, Object?>{
          'fake': <String, Object?>{
            'name': 'Fake Offline',
            'command': <String>['definitely-not-a-real-binary-xyz-111'],
          },
        },
      }),
    );
    await expectLater(
      offline.createSession(projectId: 'p1', providerId: 'fake'),
      throwsA(isA<DaemonError>()
          .having((e) => e.code, 'code', kErrProviderUnavailable)),
    );
    await offline.dispose();
    expect(store.listSessions(), isEmpty);
  });

  test('createSession honours title, mode, model, and cwd overrides', () async {
    final session = await engine.createSession(
      projectId: 'p1',
      providerId: 'fake',
      title: 'Plan the refactor',
      mode: SessionMode.plan,
      model: 'sonnet',
      cwd: project.path,
    );
    expect(session.title, 'Plan the refactor');
    expect(session.mode, SessionMode.plan);
    expect(session.model, 'sonnet');
    expect(session.cwd, project.path);
  });

  test('agent death mid-permission expires the parked request', () async {
    final session =
        await engine.createSession(projectId: 'p1', providerId: 'fake');

    // The 'die' turn parks a permission request (the agent requests it and
    // then waits for `<cwd>/agent.turn.die` before exiting).
    final permissionFuture = waitForPermissionRequest();
    final send = engine.sendMessage(session.id, 'die');
    final request = await permissionFuture;
    expect(request.request.requestId, isNotEmpty);
    expect(store.getSession(session.id)!.status, SessionStatus.waitingPermission);

    var sendDone = false;
    unawaited(send.then((_) {
      sendDone = true;
    }));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(sendDone, isFalse,
        reason: 'the turn is parked until the agent dies');

    // Kill the agent mid-request: the turn errors and the session ends in
    // error status.
    File(p.join(tempDir.path, 'agent.turn.die')).writeAsStringSync('die');
    await send;
    expect(store.getSession(session.id)!.status, SessionStatus.error,
        reason: 'agent death must leave the session in error');

    // The parked request is gone: a stale respondPermission is not-found and
    // cannot flip the dead session back to running.
    await expectLater(
      engine.respondPermission(session.id, request.request.requestId, 'allow'),
      throwsA(isA<DaemonError>()
          .having((e) => e.code, 'code', kErrNotFound)),
    );
    expect(store.getSession(session.id)!.status, SessionStatus.error,
        reason: 'a stale respondPermission must not revive the session');
  });

  test('createSession rejects cwd outside the project sandbox', () async {
    Session ok;
    // The project root itself is allowed (equality).
    ok = await engine.createSession(
        projectId: 'p1', providerId: 'fake', cwd: tempDir.path);
    expect(ok.cwd, tempDir.path);

    // A real subdirectory of the project is allowed.
    Directory(p.join(tempDir.path, 'sub')).createSync();
    ok = await engine.createSession(projectId: 'p1', providerId: 'fake',
        cwd: p.join(tempDir.path, 'sub'));
    expect(ok.cwd, p.join(tempDir.path, 'sub'));

    // Absolute paths outside the project are invalid params.
    await expectLater(
      engine.createSession(projectId: 'p1', providerId: 'fake', cwd: '/'),
      throwsA(isA<DaemonError>()
          .having((e) => e.code, 'code', -32602)),
      reason: 'a filesystem-root cwd voids the ACP fs sandbox',
    );
    if (Platform.isLinux || Platform.isMacOS) {
      final outside = await Directory.systemTemp.createTemp('sd_cwd_out_');
      addTearDown(() async {
        try {
          await outside.delete(recursive: true);
        } on Object {
          // Cleanup failure is not a test failure.
        }
      });
      await expectLater(
        engine.createSession(
            projectId: 'p1', providerId: 'fake', cwd: outside.path),
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', -32602)),
      );
      // A symlink inside the project that points outside is an escape too.
      Link(p.join(tempDir.path, 'escape'))
          .createSync(outside.path);
      await expectLater(
        engine.createSession(projectId: 'p1', providerId: 'fake',
            cwd: p.join(tempDir.path, 'escape')),
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', -32602)),
      );
    }
  });

  group('worktree sessions', () {
    Future<String> runGit(String cwd, List<String> args) async {
      final result = await Process.run('git', args, workingDirectory: cwd);
      if (result.exitCode != 0) {
        throw StateError('git ${args.join(' ')} failed: ${result.stderr}');
      }
      return (result.stdout as String).trim();
    }

    /// Registers a git-backed project at `<tempDir>/repo`: a clone of a
    /// local bare "origin" (filesystem-only remote, no network) with one
    /// pushed commit. Returns the repo path and its origin/main tip hash.
    Future<({String repoPath, String originTip})> setupGitProject() async {
      final originDir = p.join(tempDir.path, 'origin.git');
      await runGit(tempDir.path, ['init', '--bare', '-b', 'main', originDir]);
      final repoPath = p.join(tempDir.path, 'repo');
      await runGit(tempDir.path, ['clone', originDir, repoPath]);
      await runGit(repoPath, ['config', 'user.email', 'test@example.com']);
      await runGit(repoPath, ['config', 'user.name', 'Test User']);
      File(p.join(repoPath, 'a.txt')).writeAsStringSync('v1\n');
      await runGit(repoPath, ['add', '-A']);
      await runGit(repoPath, ['commit', '-m', 'init']);
      await runGit(repoPath, ['push', '-u', 'origin', 'main']);
      final tip = await runGit(repoPath, ['rev-parse', 'origin/main']);
      store.insertProject(Project(
        id: 'gitp',
        name: 'Git Project',
        path: repoPath,
        addedAt: DateTime.now().toUtc(),
        lastActiveAt: DateTime.now().toUtc(),
      ));
      return (repoPath: repoPath, originTip: tip);
    }

    test('createSession with baseBranch runs the agent in a worktree off '
        'origin/<base>', () async {
      final git = await setupGitProject();
      final gitEngine = SessionEngine(
          store: store, providers: fakeProviders(), git: GitService());
      try {
        final session = await gitEngine.createSession(
          projectId: 'gitp',
          providerId: 'fake',
          title: 'Fix the login bug!',
          baseBranch: 'main',
        );

        final shortId = session.id.substring(0, 8);
        final worktreeDir =
            p.join(tempDir.path, '.speeddial-worktrees', 'repo-$shortId');
        expect(session.cwd, worktreeDir);
        expect(session.baseBranch, 'main');
        expect(Directory(worktreeDir).existsSync(), isTrue);
        // Branched off the remote tip, not the local checkout.
        expect(
            await runGit(worktreeDir, ['rev-parse', 'HEAD']), git.originTip);
        expect(await runGit(worktreeDir, ['branch', '--show-current']),
            'speeddial/fix-the-login-bug-$shortId');
        // The persisted session carries the worktree cwd too.
        expect(store.getSession(session.id)!.cwd, worktreeDir);
        expect(store.getSession(session.id)!.baseBranch, 'main');
      } finally {
        await gitEngine.dispose();
      }
    });

    test('createSession bases the worktree on the local base branch when it '
        'is ahead of origin', () async {
      final git = await setupGitProject();
      // One unpushed local commit: local main is ahead of origin/main.
      File(p.join(git.repoPath, 'local.txt')).writeAsStringSync('local\n');
      await runGit(git.repoPath, ['add', '-A']);
      await runGit(git.repoPath, ['commit', '-m', 'local work']);
      final localTip = await runGit(git.repoPath, ['rev-parse', 'HEAD']);
      expect(localTip, isNot(git.originTip));

      final gitEngine = SessionEngine(
          store: store, providers: fakeProviders(), git: GitService());
      try {
        final session = await gitEngine.createSession(
            projectId: 'gitp', providerId: 'fake', baseBranch: 'main');
        expect(await runGit(session.cwd, ['rev-parse', 'HEAD']), localTip);
        expect(File(p.join(session.cwd, 'local.txt')).existsSync(), isTrue,
            reason: 'the worktree must contain the unpushed local work');
      } finally {
        await gitEngine.dispose();
      }
    });

    test('createSession rejects cwd combined with baseBranch', () async {
      final git = await setupGitProject();
      final gitEngine = SessionEngine(
          store: store, providers: fakeProviders(), git: GitService());
      try {
        await expectLater(
          gitEngine.createSession(
            projectId: 'gitp',
            providerId: 'fake',
            cwd: git.repoPath,
            baseBranch: 'main',
          ),
          throwsA(isA<DaemonError>().having((e) => e.code, 'code', -32602)),
        );
        expect(
            Directory(p.join(tempDir.path, '.speeddial-worktrees'))
                .existsSync(),
            isFalse,
            reason: 'rejection must happen before any git work');
      } finally {
        await gitEngine.dispose();
      }
    });

    test('createSession removes the worktree when the agent fails to start',
        () async {
      await setupGitProject();
      final failing = ProviderRegistry(configOverrides: <String, Object?>{
        'providers': <String, Object?>{
          'bad': <String, Object?>{
            'name': 'Bad Agent',
            // Starts and exits immediately without answering initialize.
            'command': <String>[Platform.resolvedExecutable, '--version'],
          },
        },
      });
      final gitEngine =
          SessionEngine(store: store, providers: failing, git: GitService());
      try {
        await expectLater(
          gitEngine.createSession(
              projectId: 'gitp', providerId: 'bad', baseBranch: 'main'),
          throwsA(isA<DaemonError>()
              .having((e) => e.code, 'code', kErrAgentProcess)),
        );
        final listed = await runGit(p.join(tempDir.path, 'repo'),
            ['worktree', 'list', '--porcelain']);
        expect(listed, isNot(contains('.speeddial-worktrees')),
            reason:
                'the worktree of a session that never started is rolled back');
      } finally {
        await gitEngine.dispose();
      }
    });

    test('createSession with baseBranch requires a git-enabled engine',
        () async {
      await setupGitProject();
      await expectLater(
        engine.createSession(
            projectId: 'gitp', providerId: 'fake', baseBranch: 'main'),
        throwsA(isA<DaemonError>().having((e) => e.code, 'code', kErrGit)),
      );
    });
  });
}
