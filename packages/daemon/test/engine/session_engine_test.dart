@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_daemon/src/engine/session_engine.dart';
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

  /// Completes when the engine emits a PermissionRequestEvent.
  Future<PermissionRequestEvent> waitForPermissionRequest() async {
    final seen = Completer<PermissionRequestEvent>();
    final sub = engine.events.listen((tuple) {
      final event = tuple.event;
      if (event is PermissionRequestEvent && !seen.isCompleted) {
        seen.complete(event);
      }
    });
    final request = await seen.future;
    await sub.cancel();
    return request;
  }

  test('createSession spawns an idle session and persists it', () async {
    final session =
        await engine.createSession(projectId: 'p1', providerId: 'fake');

    expect(session.title, 'New session');
    expect(session.status, SessionStatus.idle);
    expect(session.mode, SessionMode.build);
    expect(session.model, isNull);
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

  test('restore marks non-closed sessions as error', () async {
    final session =
        await engine.createSession(projectId: 'p1', providerId: 'fake');
    expect(store.getSession(session.id)!.status, SessionStatus.idle);

    final restarted = SessionEngine(store: store, providers: fakeProviders());
    await restarted.restore();
    expect(store.getSession(session.id)!.status, SessionStatus.error);
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

    final withModel = await engine.setModel(session.id, 'claude-sonnet-4-5');
    expect(withModel.model, 'claude-sonnet-4-5');

    final reloaded = store.getSession(session.id)!;
    expect(reloaded.title, 'My Session');
    expect(reloaded.archived, isTrue);
    expect(reloaded.mode, SessionMode.plan);
    expect(reloaded.model, 'claude-sonnet-4-5');

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
}
