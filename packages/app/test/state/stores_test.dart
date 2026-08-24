import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/scope.dart';
import 'package:speeddial_app/src/state/chat_store.dart';

/// Polls until [condition] holds, failing the test after [timeout].
Future<void> _waitUntil(
  FutureOr<bool> Function() condition, {
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

Future<void> _flushMicrotasks() => Future<void>.delayed(Duration.zero);

/// Fake whose listing/history calls are counted and whose history fetch can
/// be failed on demand.
class _InstrumentedFake extends FakeDaemonClient {
  _InstrumentedFake() : super(eventDelay: const Duration(milliseconds: 1));

  int listSessionsCalls = 0;
  int listProjectsCalls = 0;
  int historyCalls = 0;
  bool failHistory = false;

  @override
  Future<List<Session>> listSessions({
    String? projectId,
    bool includeArchived = false,
  }) {
    listSessionsCalls++;
    return super.listSessions(
      projectId: projectId,
      includeArchived: includeArchived,
    );
  }

  @override
  Future<List<Project>> listProjects() {
    listProjectsCalls++;
    return super.listProjects();
  }

  @override
  Future<({List<SessionEvent> events, bool hasMore})> history(
    String sessionId, {
    int limit = 200,
    int? beforeSeq,
  }) {
    historyCalls++;
    if (failHistory) {
      return Future<({List<SessionEvent> events, bool hasMore})>.error(
        StateError('daemon unreachable'),
      );
    }
    return super.history(sessionId, limit: limit, beforeSeq: beforeSeq);
  }
}

class _GatedSessionListFake extends FakeDaemonClient {
  _GatedSessionListFake()
    : super(eventDelay: const Duration(milliseconds: 100));

  Completer<void>? _captured;
  Completer<void>? _release;

  Future<void> get listCaptured => _captured?.future ?? Future<void>.value();

  void gateNextList() {
    _captured = Completer<void>();
    _release = Completer<void>();
  }

  void releaseList() {
    final Completer<void>? release = _release;
    if (release != null && !release.isCompleted) release.complete();
  }

  @override
  Future<List<Session>> listSessions({
    String? projectId,
    bool includeArchived = false,
  }) async {
    final List<Session> snapshot = await super.listSessions(
      projectId: projectId,
      includeArchived: includeArchived,
    );
    final Completer<void>? captured = _captured;
    final Completer<void>? release = _release;
    if (captured != null && release != null) {
      captured.complete();
      await release.future;
      _captured = null;
      _release = null;
    }
    return snapshot;
  }
}

/// Fake whose `history()` can be blocked on demand, so tests can hold a
/// resync's refetch open and observe the store's catch-up state.
class _GatedResyncFake extends FakeDaemonClient {
  _GatedResyncFake() : super(eventDelay: const Duration(milliseconds: 1));

  bool blockHistory = false;
  int historyCalls = 0;
  final List<Completer<void>> _gates = <Completer<void>>[];

  void releaseHistory() {
    for (final Completer<void> gate in _gates) {
      if (!gate.isCompleted) gate.complete();
    }
    _gates.clear();
  }

  @override
  Future<({List<SessionEvent> events, bool hasMore})> history(
    String sessionId, {
    int limit = 200,
    int? beforeSeq,
  }) {
    historyCalls++;
    if (!blockHistory) {
      return super.history(sessionId, limit: limit, beforeSeq: beforeSeq);
    }
    final Completer<void> gate = Completer<void>();
    _gates.add(gate);
    return gate.future.then(
      (_) => super.history(sessionId, limit: limit, beforeSeq: beforeSeq),
    );
  }
}

/// Fake whose `history()` serves the newest page normally and can hold
/// older pages behind a gate or fail them, so tests can observe the
/// store's incremental page application and mid-backfill retries.
class _GatedPageFake extends FakeDaemonClient {
  _GatedPageFake() : super(eventDelay: const Duration(milliseconds: 1));

  Completer<void>? _gate;
  bool _open = false;
  bool failOlderPages = false;

  /// Lets the held page (and all future pages) through.
  void releaseNextPage() {
    _open = true;
    final Completer<void>? gate = _gate;
    _gate = null;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  Future<({List<SessionEvent> events, bool hasMore})> history(
    String sessionId, {
    int limit = 200,
    int? beforeSeq,
  }) {
    if (beforeSeq != null) {
      if (failOlderPages) {
        return Future<({List<SessionEvent> events, bool hasMore})>.error(
          StateError('daemon unreachable mid-backfill'),
        );
      }
      if (!_open) {
        _gate ??= Completer<void>();
        final Completer<void> gate = _gate!;
        return gate.future.then(
          (_) => super.history(sessionId, limit: limit, beforeSeq: beforeSeq),
        );
      }
    }
    return super.history(sessionId, limit: limit, beforeSeq: beforeSeq);
  }
}

void main() {
  late FakeDaemonClient fake;
  late AppData app;

  setUp(() {
    fake = FakeDaemonClient(eventDelay: const Duration(milliseconds: 1));
    app = AppData()..registerClient('fake', fake);
  });

  tearDown(() {
    app.dispose();
  });

  test(
    'clientFor resolves registered clients and rejects unknown ids',
    () async {
      expect(app.clientFor('fake'), same(fake));
      expect(() => app.clientFor('nope'), throwsA(isA<StateError>()));
    },
  );

  group('projects', () {
    test(
      'refresh/add/remove update the cache and lastError stays null',
      () async {
        expect(app.projects.projectsFor('fake'), isEmpty);

        await app.projects.refresh('fake');
        expect(app.projects.isLoading('fake'), isFalse);
        final List<Project> seeded = app.projects.projectsFor('fake');
        expect(seeded, hasLength(1));
        expect(seeded.single.name, 'Demo Project');
        expect(seeded.single.path, '/demo');

        final Project added = await app.projects.add(
          'fake',
          '/work/other',
          name: 'Other',
        );
        expect(added.name, 'Other');
        expect(app.projects.projectsFor('fake'), hasLength(2));
        expect(
          app.projects.projectsFor('fake').map((Project p) => p.name),
          containsAll(<String>['Demo Project', 'Other']),
        );

        await app.projects.remove('fake', added.id);
        expect(app.projects.projectsFor('fake'), hasLength(1));
        expect(app.projects.projectsFor('fake').single.id, 'proj-demo');
        expect(app.projects.lastError, isNull);
      },
    );

    test('isLoading is true while a refresh is in flight', () async {
      final Future<void> refreshing = app.projects.refresh('fake');
      expect(app.projects.isLoading('fake'), isTrue);
      await refreshing;
      expect(app.projects.isLoading('fake'), isFalse);
    });

    test('refreshes when the daemon announces projects.changed', () async {
      await app.projects.refresh('fake');
      expect(app.projects.projectsFor('fake'), hasLength(1));

      // Daemon-side add: the subscription triggers a refetch on its own.
      await fake.addProject('/work/other', name: 'Other');
      await _waitUntil(() => app.projects.projectsFor('fake').length == 2);
      expect(
        app.projects.projectsFor('fake').map((Project p) => p.name),
        contains('Other'),
      );

      // Daemon-side remove: the refetch drops it (and its sessions).
      await fake.removeProject('proj-demo');
      await _waitUntil(() => app.projects.projectsFor('fake').length == 1);
      expect(app.projects.projectsFor('fake').single.name, 'Other');
      expect(app.projects.lastError, isNull);
    });
  });

  group('sessions', () {
    test(
      'create/refresh/rename/archive/delete keep the cache consistent',
      () async {
        final String projectId = (await fake.listProjects()).single.id;

        await app.sessions.refresh('fake', projectId: projectId);
        expect(app.sessions.sessionsFor(projectId), hasLength(2));
        expect(app.sessions.byId('sess-1')?.title, 'Build the feature');
        expect(app.sessions.byId('sess-2')?.mode, SessionMode.plan);

        final Session created = await app.sessions.create(
          'fake',
          projectId: projectId,
          providerId: 'omp',
          title: 'Fresh',
        );
        expect(created.mode, SessionMode.build);
        expect(app.sessions.byId(created.id), isNotNull);
        expect(app.sessions.sessionsFor(projectId), hasLength(3));

        await app.sessions.rename('fake', created.id, 'Renamed');
        expect(app.sessions.byId(created.id)!.title, 'Renamed');

        await app.sessions.setMode('fake', created.id, SessionMode.plan);
        expect(app.sessions.byId(created.id)!.mode, SessionMode.plan);

        await app.sessions.archive('fake', created.id, true);
        expect(app.sessions.byId(created.id)!.archived, isTrue);

        await app.sessions.delete('fake', created.id);
        expect(app.sessions.byId(created.id), isNull);
        expect(app.sessions.sessionsFor(projectId), hasLength(2));

        // A full refresh (all projects) keeps everything sane.
        await app.sessions.refresh('fake');
        expect(app.sessions.sessionsFor(projectId), hasLength(2));
      },
    );

    test('orders newly created sessions before older sessions', () async {
      final String projectId = (await fake.listProjects()).single.id;
      await app.sessions.refresh('fake', projectId: projectId);

      await Future<void>.delayed(const Duration(milliseconds: 2));
      final Session firstCreated = await app.sessions.create(
        'fake',
        projectId: projectId,
        providerId: 'omp',
        title: 'First created',
      );
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final Session newest = await fake.createSession(
        projectId: projectId,
        providerId: 'omp',
        title: 'Newest',
      );
      await _flushMicrotasks();

      expect(
        app.sessions.sessionsFor(projectId).take(2).map((Session s) => s.id),
        <String>[newest.id, firstCreated.id],
      );

      await app.sessions.refresh('fake', projectId: projectId);
      expect(
        app.sessions.sessionsFor(projectId).take(2).map((Session s) => s.id),
        <String>[newest.id, firstCreated.id],
      );
    });

    test('activity moves a session to the top through completion', () async {
      final String projectId = (await fake.listProjects()).single.id;
      await app.sessions.refresh('fake', projectId: projectId);
      app.selection
        ..selectedDaemonId = 'fake'
        ..selectedProjectId = projectId
        ..selectedSessionId = 'sess-1';
      expect(app.sessions.sessionsFor(projectId).first.id, 'sess-1');

      final DateTime before = app.sessions.byId('sess-2')!.lastActivityAt;
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await fake.sendMessage('sess-2', 'finish in the background');
      await _waitUntil(
        () => app.sessions.byId('sess-2')?.status == SessionStatus.running,
      );
      final Session running = app.sessions.byId('sess-2')!;
      expect(running.lastActivityAt.isAfter(before), isTrue);
      expect(app.sessions.sessionsFor(projectId).first.id, 'sess-2');

      await _waitUntil(() => app.sessions.isDone('fake', 'sess-2'));
      final Session completed = app.sessions.byId('sess-2')!;
      expect(completed.lastActivityAt.isAfter(running.lastActivityAt), isTrue);
      expect(app.sessions.sessionsFor(projectId).first.id, 'sess-2');

      final DateTime inactiveActivity = app.sessions
          .byId('sess-1')!
          .lastActivityAt;
      await fake.renameSession('sess-1', 'Metadata only');
      await _flushMicrotasks();
      expect(app.sessions.byId('sess-1')!.lastActivityAt, inactiveActivity);
      expect(app.sessions.sessionsFor(projectId).first.id, 'sess-2');
    });

    test('marks unseen completed turns done until selected', () async {
      final String projectId = (await fake.listProjects()).single.id;
      await app.sessions.refresh('fake', projectId: projectId);
      app.selection
        ..selectedDaemonId = 'fake'
        ..selectedProjectId = projectId
        ..selectedSessionId = 'sess-2';

      await fake.sendMessage('sess-1', 'finish in the background');
      await _waitUntil(() => app.sessions.isDone('fake', 'sess-1'));
      expect(app.sessions.byId('sess-1')?.status, SessionStatus.idle);
      expect(app.sessions.isDone('fake', 'sess-1'), isTrue);

      app.selection.selectedSessionId = 'sess-1';
      expect(app.sessions.isDone('fake', 'sess-1'), isFalse);
    });

    test('does not mark a selected completed turn done', () async {
      final String projectId = (await fake.listProjects()).single.id;
      await app.sessions.refresh('fake', projectId: projectId);
      app.selection
        ..selectedDaemonId = 'fake'
        ..selectedProjectId = projectId
        ..selectedSessionId = 'sess-1';

      await fake.sendMessage('sess-1', 'finish while visible');
      await _waitUntil(
        () => app.sessions.byId('sess-1')?.status == SessionStatus.running,
      );
      await _waitUntil(
        () => app.sessions.byId('sess-1')?.status == SessionStatus.idle,
      );
      expect(app.sessions.isDone('fake', 'sess-1'), isFalse);
    });

    test(
      'reacts to daemon sessionUpdates / sessionRemovals without a refresh',
      () async {
        final String projectId = (await fake.listProjects()).single.id;
        await app.sessions.refresh('fake', projectId: projectId);
        expect(app.sessions.byId('sess-1')!.title, 'Build the feature');

        // A daemon-side rename (no store call): the subscription upserts.
        await fake.renameSession('sess-1', 'Renamed externally');
        await _flushMicrotasks();
        expect(app.sessions.byId('sess-1')!.title, 'Renamed externally');
        expect(
          app.sessions
              .sessionsFor(projectId)
              .singleWhere((Session s) => s.id == 'sess-1')
              .title,
          'Renamed externally',
        );

        // A daemon-side create lands in the bucket too.
        final Session created = await fake.createSession(
          projectId: projectId,
          providerId: 'omp',
        );
        await _flushMicrotasks();
        expect(app.sessions.byId(created.id), isNotNull);
        expect(app.sessions.sessionsFor(projectId), hasLength(3));

        // A daemon-side delete removes it.
        await fake.deleteSession(created.id);
        await _flushMicrotasks();
        expect(app.sessions.byId(created.id), isNull);
        expect(app.sessions.sessionsFor(projectId), hasLength(2));
      },
    );

    test('refresh does not overwrite a newer live session update', () async {
      final _GatedSessionListFake gated = _GatedSessionListFake();
      app.registerClient('gated', gated);
      await app.sessions.refresh('gated');

      gated.gateNextList();
      final Future<void> refreshing = app.sessions.refresh('gated');
      await gated.listCaptured;

      await gated.sendMessage('sess-1', 'keep running');
      await _waitUntil(
        () => app.sessions.byId('sess-1')?.status == SessionStatus.running,
      );

      gated.releaseList();
      await refreshing;

      expect(app.sessions.byId('sess-1')?.status, SessionStatus.running);
    });

    test(
      'byId prefers the most recently used daemon for a shared id',
      () async {
        final FakeDaemonClient fake2 = FakeDaemonClient();
        app.registerClient('fake2', fake2);
        await app.sessions.refresh('fake');
        await app.sessions.refresh('fake2'); // last used for both daemons

        await app.sessions.rename('fake2', 'sess-1', 'From fake2');
        expect(app.sessions.byId('sess-1')!.title, 'From fake2');

        await app.sessions.rename('fake', 'sess-1', 'From fake');
        expect(app.sessions.byId('sess-1')!.title, 'From fake');

        // fake's entry is untouched internally; refreshing fake2 makes fake2's
        // copy authoritative again for the shared id.
        await app.sessions.refresh('fake2');
        expect(app.sessions.byId('sess-1')!.title, 'From fake2');
      },
    );
  });

  group('chat', () {
    test(
      'watch buffers events, merges chunks, derives status and usage',
      () async {
        final String sessionId = (await fake.listSessions()).first.id;
        app.chat.watchSession('fake', sessionId);

        await app.chat.send('fake', sessionId, 'hello');
        await _waitUntil(
          () => app.chat
              .eventsFor(sessionId)
              .any((SessionEvent e) => e is TurnCompleteEvent),
        );

        final List<SessionEvent> events = app.chat.eventsFor(sessionId);
        // The three chunk deltas merged into a single concatenated event.
        final List<AgentMessageChunkEvent> chunks = events
            .whereType<AgentMessageChunkEvent>()
            .toList();
        expect(chunks, hasLength(1));
        expect(
          chunks.single.text,
          'Working on it…\n\n```dart\nvoid main() {}\n```\n\nDone.',
        );

        // Tool call appears once per status transition, plan and usage once.
        expect(events.whereType<ToolCallEvent>(), hasLength(2));
        expect(events.whereType<PlanEvent>().single.entries, hasLength(2));
        expect(app.chat.usageOf(sessionId)?.totalTokens, 1500);
        expect(events.last, isA<TurnCompleteEvent>());

        // Status: idle once the turn completed.
        expect(app.chat.statusOf(sessionId), SessionStatus.idle);
        expect(app.chat.modeOf(sessionId), SessionMode.build);
      },
    );

    test(
      'session seed does not overwrite a newer live running update',
      () async {
        final _GatedSessionListFake gated = _GatedSessionListFake();
        app.registerClient('gated', gated);
        gated.gateNextList();

        app.chat.watchSession('gated', 'sess-1');
        await gated.listCaptured;

        await app.chat.send('gated', 'sess-1', 'keep running');
        await _waitUntil(
          () => app.chat.statusOf('sess-1') == SessionStatus.running,
        );

        gated.releaseList();
        await _flushMicrotasks();

        expect(app.chat.statusOf('sess-1'), SessionStatus.running);
      },
    );

    test('permission flow via the store parks then resolves', () async {
      final String sessionId = (await fake.listSessions()).first.id;
      app.chat.watchSession('fake', sessionId);

      await app.chat.send('fake', sessionId, 'please grant permission');
      await _waitUntil(
        () => app.chat
            .eventsFor(sessionId)
            .any((SessionEvent e) => e is PermissionRequestEvent),
      );

      expect(app.chat.statusOf(sessionId), SessionStatus.waitingPermission);
      expect(
        app.chat
            .eventsFor(sessionId)
            .any((SessionEvent e) => e is TurnCompleteEvent),
        isFalse,
      );

      final PermissionRequestEvent request =
          app.chat
                  .eventsFor(sessionId)
                  .singleWhere((SessionEvent e) => e is PermissionRequestEvent)
              as PermissionRequestEvent;
      await app.chat.respondPermission(
        'fake',
        sessionId,
        request.request.requestId,
        request.request.options.first.optionId,
      );

      await _waitUntil(
        () => app.chat
            .eventsFor(sessionId)
            .any((SessionEvent e) => e is TurnCompleteEvent),
      );
      expect(app.chat.statusOf(sessionId), SessionStatus.idle);
      expect(
        app.chat
            .eventsFor(sessionId)
            .whereType<PermissionResolvedEvent>()
            .single
            .requestId,
        request.request.requestId,
      );
    });

    test('history backfill notifies once for the whole batch', () async {
      // Run a full turn first so history() has events to replay.
      final String sessionId = (await fake.listSessions()).first.id;
      await fake.sendMessage(sessionId, 'hello');
      await _waitUntil(
        () async =>
            (await fake.history(sessionId)).events
                .any((SessionEvent e) => e is TurnCompleteEvent),
      );

      int notifications = 0;
      app.chat.addListener(() => notifications++);

      app.chat.watchSession('fake', sessionId);
      await _flushMicrotasks();

      // 12 history events (userMessage + turn) arrive in one batch;
      // notifications are coalesced; the two chunk runs merge → 9.
      expect(app.chat.eventsFor(sessionId).length, 9);
      expect(notifications, 1);

      // A second watch for the same session is a no-op.
      app.chat.watchSession('fake', sessionId);
      await _flushMicrotasks();
      expect(notifications, 1);
    });

    test(
      'unwatch stops buffering and releases per-daemon subscriptions',
      () async {
        final String sessionId = (await fake.listSessions()).first.id;
        app.chat.watchSession('fake', sessionId);
        await app.chat.send('fake', sessionId, 'hello');
        await _waitUntil(
          () => app.chat
              .eventsFor(sessionId)
              .any((SessionEvent e) => e is TurnCompleteEvent),
        );

        app.chat.unwatch(sessionId);
        expect(app.chat.eventsFor(sessionId), isEmpty);
        expect(app.chat.statusOf(sessionId), SessionStatus.idle);

        // Watching again reloads history (duplicates dropped by seq).
        app.chat.watchSession('fake', sessionId);
        await _flushMicrotasks();
        final List<SessionEvent> events = app.chat.eventsFor(sessionId);
        expect(
          events.whereType<AgentMessageChunkEvent>().single.text,
          'Working on it…\n\n```dart\nvoid main() {}\n```\n\nDone.',
        );
        expect(events.whereType<TurnCompleteEvent>(), hasLength(1));
      },
    );

    test('watch loads one page and older history is explicit', () async {
      fake.seedHistory('sess-1', <SessionEvent>[
        for (var i = 1; i <= 1001; i++) UserMessageEvent(text: 'm$i'),
      ]);

      app.chat.watchSession('fake', 'sess-1');
      await _waitUntil(
        () => app.chat.historyStatusFor('sess-1') == HistoryStatus.ready,
      );

      expect(app.chat.eventsFor('sess-1'), hasLength(500));
      expect(app.chat.hasOlderHistory('sess-1'), isTrue);
      expect(
        (app.chat.eventsFor('sess-1').first as UserMessageEvent).text,
        'm502',
      );

      await app.chat.loadOlderHistory('fake', 'sess-1');
      expect(app.chat.eventsFor('sess-1'), hasLength(1000));
      expect(app.chat.hasOlderHistory('sess-1'), isTrue);

      await app.chat.loadOlderHistory('fake', 'sess-1');
      final List<SessionEvent> events = app.chat.eventsFor('sess-1');
      expect(events, hasLength(1001));
      expect(app.chat.hasOlderHistory('sess-1'), isFalse);
      expect(
        events.map((SessionEvent e) => e.seq).toList(),
        List<int?>.generate(1001, (int i) => i + 1),
      );
    });

    test('history page size is configurable for compact clients', () async {
      final AppData compact = AppData(chatHistoryPageSize: 25)
        ..registerClient('fake', fake);
      addTearDown(compact.dispose);
      fake.seedHistory('sess-1', <SessionEvent>[
        for (var i = 1; i <= 61; i++) UserMessageEvent(text: 'm$i'),
      ]);

      compact.chat.watchSession('fake', 'sess-1');
      await _waitUntil(
        () => compact.chat.historyStatusFor('sess-1') == HistoryStatus.ready,
      );

      expect(compact.chat.eventsFor('sess-1'), hasLength(25));
      expect(compact.chat.hasOlderHistory('sess-1'), isTrue);
      expect(
        (compact.chat.eventsFor('sess-1').first as UserMessageEvent).text,
        'm37',
      );
    });

    test(
      'retained history renders immediately then reconciles on rewatch',
      () async {
        final _GatedResyncFake gated = _GatedResyncFake();
        final AppData compact = AppData(
          chatHistoryPageSize: 20,
          chatRetainedSessionLimit: 2,
        )..registerClient('gated', gated);
        addTearDown(compact.dispose);
        addTearDown(gated.dispose);
        gated.seedHistory('sess-1', <SessionEvent>[
          const UserMessageEvent(text: 'cached'),
        ]);

        compact.chat.watchSession('gated', 'sess-1');
        await _waitUntil(
          () => compact.chat.historyStatusFor('sess-1') == HistoryStatus.ready,
        );
        compact.chat.unwatch('sess-1');
        gated.seedHistory('sess-1', <SessionEvent>[
          const UserMessageEvent(text: 'missed while closed'),
        ]);
        gated.blockHistory = true;

        compact.chat.watchSession('gated', 'sess-1');
        await _waitUntil(() => compact.chat.isCatchingUp('sess-1'));
        expect(
          compact.chat
              .eventsFor('sess-1')
              .whereType<UserMessageEvent>()
              .single
              .text,
          'cached',
        );
        expect(gated.historyCalls, 2);

        gated.releaseHistory();
        await _waitUntil(() => !compact.chat.isCatchingUp('sess-1'));
        expect(
          compact.chat
              .eventsFor('sess-1')
              .whereType<UserMessageEvent>()
              .map((UserMessageEvent event) => event.text),
          <String>['cached', 'missed while closed'],
        );
      },
    );

    test('retained history evicts the least recently closed session', () async {
      final AppData compact = AppData(chatRetainedSessionLimit: 2)
        ..registerClient('fake', fake);
      addTearDown(compact.dispose);
      final Session second = await fake.createSession(
        projectId: 'proj-demo',
        providerId: 'fake',
        title: 'Second',
      );
      final Session third = await fake.createSession(
        projectId: 'proj-demo',
        providerId: 'fake',
        title: 'Third',
      );
      for (final (String id, String text) in <(String, String)>[
        ('sess-1', 'first'),
        (second.id, 'second'),
        (third.id, 'third'),
      ]) {
        fake.seedHistory(id, <SessionEvent>[UserMessageEvent(text: text)]);
        compact.chat.watchSession('fake', id);
        await _waitUntil(
          () => compact.chat.historyStatusFor(id) == HistoryStatus.ready,
        );
        compact.chat.unwatch(id);
      }

      expect(compact.chat.eventsFor('sess-1'), isEmpty);
      expect(compact.chat.eventsFor(second.id), isNotEmpty);
      expect(compact.chat.eventsFor(third.id), isNotEmpty);
    });

    test(
      'older history load exposes progress and suppresses duplicates',
      () async {
        final _GatedPageFake gated = _GatedPageFake();
        app.registerClient('gated', gated);
        gated.seedHistory('sess-1', <SessionEvent>[
          for (var i = 1; i <= 550; i++) UserMessageEvent(text: 'm$i'),
        ]);

        app.chat.watchSession('gated', 'sess-1');
        await _waitUntil(
          () => app.chat.historyStatusFor('sess-1') == HistoryStatus.ready,
        );
        expect(app.chat.eventsFor('sess-1'), hasLength(500));

        final Future<void> first = app.chat.loadOlderHistory('gated', 'sess-1');
        await _waitUntil(() => app.chat.isLoadingOlderHistory('sess-1'));
        final Future<void> duplicate = app.chat.loadOlderHistory(
          'gated',
          'sess-1',
        );
        await duplicate;
        expect(app.chat.eventsFor('sess-1'), hasLength(500));

        gated.releaseNextPage();
        await first;
        expect(app.chat.eventsFor('sess-1'), hasLength(550));
        expect(app.chat.hasOlderHistory('sess-1'), isFalse);
      },
    );

    test(
      'failed older history can be retried without clearing recent events',
      () async {
        final _GatedPageFake gated = _GatedPageFake()..failOlderPages = true;
        app.registerClient('gated', gated);
        gated.seedHistory('sess-1', <SessionEvent>[
          for (var i = 1; i <= 550; i++) UserMessageEvent(text: 'm$i'),
        ]);

        app.chat.watchSession('gated', 'sess-1');
        await _waitUntil(
          () => app.chat.historyStatusFor('sess-1') == HistoryStatus.ready,
        );
        await app.chat.loadOlderHistory('gated', 'sess-1');
        expect(app.chat.eventsFor('sess-1'), hasLength(500));
        expect(app.chat.olderHistoryErrorFor('sess-1'), isA<StateError>());

        gated.failOlderPages = false;
        gated.releaseNextPage();
        await app.chat.loadOlderHistory('gated', 'sess-1');
        expect(app.chat.eventsFor('sess-1'), hasLength(550));
        expect(app.chat.olderHistoryErrorFor('sess-1'), isNull);
      },
    );

    test('revisionFor increments on every buffer mutation', () async {
      final String sessionId = (await fake.listSessions()).first.id;
      expect(app.chat.revisionFor(sessionId), 0); // never watched

      app.chat.watchSession('fake', sessionId);
      await _flushMicrotasks();
      expect(app.chat.revisionFor(sessionId), 0); // empty history: no-op watch

      await app.chat.send('fake', sessionId, 'hello');
      await _waitUntil(
        () => app.chat
            .eventsFor(sessionId)
            .any((SessionEvent e) => e is TurnCompleteEvent),
      );
      // 12 events (userMessage, 2 thought deltas, 3 chunk deltas, 2 tool
      // calls, plan, activity, usage, turnComplete); the merged chunk deltas
      // still count as mutations.
      expect(app.chat.revisionFor(sessionId), 12);

      // Reading the buffer never bumps the revision.
      final int settled = app.chat.revisionFor(sessionId);
      app.chat.eventsFor(sessionId);
      expect(app.chat.revisionFor(sessionId), settled);

      // Unwatching forgets the counters for that session.
      app.chat.unwatch(sessionId);
      expect(app.chat.revisionFor(sessionId), 0);
    });

    test(
      'attachmentData fetches payloads and memoizes per attachment',
      () async {
        final String sessionId = (await fake.listSessions()).first.id;
        await fake.sendMessage(
          sessionId,
          '',
          attachments: <OutgoingAttachment>[
            const OutgoingAttachment(
              name: 'shot.png',
              mimeType: 'image/png',
              data: 'aGVsbG8=',
            ),
          ],
        );

        final Future<AttachmentData> first = app.chat.attachmentData(
          'fake',
          sessionId,
          'att-1',
        );
        final AttachmentData data = await first;
        expect(data.id, 'att-1');
        expect(data.name, 'shot.png');
        expect(data.mimeType, 'image/png');
        expect(data.data, 'aGVsbG8=');

        // Attachments are immutable, so repeat reads share one future.
        expect(
          app.chat.attachmentData('fake', sessionId, 'att-1'),
          same(first),
        );

        // Unknown attachments surface the daemon's not-found code.
        await expectLater(
          app.chat.attachmentData('fake', sessionId, 'att-99'),
          throwsA(
            isA<DaemonError>().having(
              (DaemonError e) => e.code,
              'code',
              kErrNotFound,
            ),
          ),
        );
      },
    );

    test(
      'same session id on two daemons stays separate, last watch wins',
      () async {
        final FakeDaemonClient fake2 = FakeDaemonClient(
          eventDelay: const Duration(milliseconds: 1),
        );
        app.registerClient('fake2', fake2);
        final String sessionId = (await fake.listSessions()).first.id;

        app.chat.watchSession('fake', sessionId);
        await app.chat.send('fake', sessionId, 'hello');
        await _waitUntil(
          () => app.chat
              .eventsFor(sessionId)
              .any((SessionEvent e) => e is TurnCompleteEvent),
        );
        expect(app.chat.eventsFor(sessionId), isNotEmpty);
        final int fakeRevisions = app.chat.revisionFor(sessionId);

        // Now watch the same id on fake2: the public getters shift to fake2's
        // fresh buffer — its own history is empty, unlike fake's full turn.
        app.chat.watchSession('fake2', sessionId);
        await _flushMicrotasks();
        expect(app.chat.eventsFor(sessionId), isEmpty);
        expect(app.chat.revisionFor(sessionId), 0);

        // A turn on fake2 fills only fake2's buffer; seqs start at 1 again.
        await app.chat.send('fake2', sessionId, 'hi there');
        await _waitUntil(
          () => app.chat
              .eventsFor(sessionId)
              .any((SessionEvent e) => e is TurnCompleteEvent),
        );
        final List<SessionEvent> fake2Events = app.chat.eventsFor(sessionId);
        expect(fake2Events.first, isA<UserMessageEvent>());
        expect(fake2Events.first.seq, 1);
        // 12 raw events; the 2 thought deltas and 3 chunk deltas each merge
        // into one buffered event whose seq is the last delta's, so the buffer
        // holds 9 events with seqs [1, 3, 6, 7, 8, 9, 10, 11, 12].
        expect(fake2Events.map((SessionEvent e) => e.seq).toList(), <int>[
          1,
          3,
          6,
          7,
          8,
          9,
          10,
          11,
          12,
        ]);
        expect(app.chat.revisionFor(sessionId), 12);

        // Unwatching releases the preferred (fake2) buffer; resolution shifts
        // back to fake's still-watched buffer with its turn intact.
        app.chat.unwatch(sessionId);
        await _flushMicrotasks();
        expect(app.chat.eventsFor(sessionId).first, isA<UserMessageEvent>());
        expect(app.chat.revisionFor(sessionId), fakeRevisions);
      },
    );
  });

  group('connection recovery', () {
    test('failed history load reports failed; retryHistory recovers', () async {
      final _InstrumentedFake instrumented = _InstrumentedFake();
      app.registerClient('inst', instrumented);
      instrumented.seedHistory('sess-1', <SessionEvent>[
        UserMessageEvent(text: 'earlier'),
      ]);

      // Daemon unreachable at watch time: the session must not read as
      // empty; it reports a failed load instead.
      instrumented.failHistory = true;
      app.chat.watchSession('inst', 'sess-1');
      await _waitUntil(
        () => app.chat.historyStatusFor('sess-1') == HistoryStatus.failed,
      );
      expect(app.chat.eventsFor('sess-1'), isEmpty);
      expect(app.chat.historyErrorFor('sess-1'), isNotNull);

      // Back up: the manual retry loads the persisted events.
      instrumented.failHistory = false;
      app.chat.retryHistory('inst', 'sess-1');
      await _waitUntil(
        () => app.chat.historyStatusFor('sess-1') == HistoryStatus.ready,
      );
      expect(app.chat.eventsFor('sess-1'), hasLength(1));
      expect(app.chat.historyErrorFor('sess-1'), isNull);
    });

    test(
      'a live sequence gap backfills missed events before applying the tail',
      () async {
        final FakeDaemonClient waking = FakeDaemonClient(
          eventDelay: const Duration(milliseconds: 1),
        );
        app.registerClient('waking', waking);
        waking.seedHistory('sess-1', <SessionEvent>[
          UserMessageEvent(text: 'before sleep 1'),
          AgentMessageChunkEvent(text: 'before sleep 2'),
        ]);
        app.chat.watchSession('waking', 'sess-1');
        await _waitUntil(
          () => app.chat.historyStatusFor('sess-1') == HistoryStatus.ready,
        );
        expect(
          app.chat.eventsFor('sess-1').map((SessionEvent e) => e.seq),
          <int>[1, 2],
        );

        waking.seedHistory('sess-1', <SessionEvent>[
          UserMessageEvent(text: 'missed 3'),
          AgentMessageChunkEvent(text: 'missed 4'),
        ]);
        await waking.sendMessage('sess-1', 'live after wake');

        await _waitUntil(
          () => app.chat
              .eventsFor('sess-1')
              .any(
                (SessionEvent event) =>
                    event is UserMessageEvent && event.text == 'missed 3',
              ),
        );
        final List<int> seqs = <int>[
          for (final SessionEvent event in app.chat.eventsFor('sess-1'))
            event.seq!,
        ];
        expect(seqs, orderedEquals(seqs.toSet().toList()..sort()));
        expect(seqs, containsAllInOrder(<int>[1, 2, 3, 4, 5]));
      },
    );

    test('a resync refetches sessions, projects and watched history', () async {
      final _InstrumentedFake instrumented = _InstrumentedFake();
      app.registerClient('inst', instrumented);

      await app.projects.refresh('inst');
      await app.sessions.refresh('inst');
      app.chat.watchSession('inst', 'sess-1');
      await _waitUntil(
        () => app.chat.historyStatusFor('sess-1') == HistoryStatus.ready,
      );

      final int sessionsBefore = instrumented.listSessionsCalls;
      final int projectsBefore = instrumented.listProjectsCalls;
      final int historyBefore = instrumented.historyCalls;

      // Simulates the client reconnecting after the daemon restarted: each
      // store must refetch what it could have missed while offline.
      instrumented.triggerResync();

      await _waitUntil(
        () =>
            instrumented.listSessionsCalls > sessionsBefore &&
            instrumented.listProjectsCalls > projectsBefore &&
            instrumented.historyCalls > historyBefore,
      );
    });

    test(
      'isCatchingUp is true while the resync history refetch is in flight',
      () async {
        final _GatedResyncFake gated = _GatedResyncFake();
        app.registerClient('gated', gated);
        gated.seedHistory('sess-1', <SessionEvent>[
          UserMessageEvent(text: 'before the drop'),
        ]);
        app.chat.watchSession('gated', 'sess-1');
        await _waitUntil(
          () => app.chat.historyStatusFor('sess-1') == HistoryStatus.ready,
        );
        expect(app.chat.isCatchingUp('sess-1'), isFalse);

        // Hold the resync refetch open: while it runs the session must
        // report that it is catching up on missed events.
        gated.blockHistory = true;
        gated.triggerResync();
        await _flushMicrotasks();
        expect(app.chat.isCatchingUp('sess-1'), isTrue);
        // The existing content stays visible meanwhile; the load state is
        // still ready (this is a backfill, not a first load).
        expect(app.chat.eventsFor('sess-1'), isNotEmpty);
        expect(app.chat.historyStatusFor('sess-1'), HistoryStatus.ready);

        gated.blockHistory = false;
        gated.releaseHistory();
        await _waitUntil(() => !app.chat.isCatchingUp('sess-1'));
        expect(app.chat.historyStatusFor('sess-1'), HistoryStatus.ready);
      },
    );
  });

  group('files', () {
    test(
      'entriesFor is null until loaded, then cached per directory',
      () async {
        final String projectId = (await fake.listProjects()).single.id;

        expect(app.files.entriesFor(projectId, '.'), isNull);

        await app.files.loadDir('fake', projectId, '.');
        final List<FileEntry>? root = app.files.entriesFor(projectId, '.');
        expect(root, isNotNull);
        expect(root!.map((FileEntry e) => e.name), <String>[
          'lib',
          'main.dart',
          'pubspec.yaml',
        ]);
        expect(root.map((FileEntry e) => e.isDir).toList(), <bool>[
          true,
          false,
          false,
        ]);

        // Subdirectory loads independently.
        expect(app.files.entriesFor(projectId, 'lib'), isNull);
        await app.files.loadDir('fake', projectId, 'lib');
        expect(
          app.files.entriesFor(projectId, 'lib')!.single.name,
          'main.dart',
        );
      },
    );

    test('readFile passes through content from the client', () async {
      final String projectId = (await fake.listProjects()).single.id;
      final FileReadResult result = await app.files.readFile(
        'fake',
        projectId,
        'lib/main.dart',
      );
      expect(result.content, contains('runApp'));
      expect(result.isBinary, isFalse);
    });
  });

  group('git', () {
    test('refresh populates status/branches with a busy flag', () async {
      final String projectId = (await fake.listProjects()).single.id;
      expect(app.git.statusFor(projectId), isNull);
      expect(app.git.branchesFor(projectId), isNull);
      expect(app.git.isBusy(projectId), isFalse);

      final Future<void> refreshing = app.git.refresh('fake', projectId);
      expect(app.git.isBusy(projectId), isTrue);
      await refreshing;

      expect(app.git.isBusy(projectId), isFalse);
      expect(app.git.errorFor(projectId), isNull);
      final GitStatus? status = app.git.statusFor(projectId);
      expect(status, isNotNull);
      expect(status!.branch, 'main');
      expect(status.files.single.path, 'lib/main.dart');
      expect(status.files.single.worktreeStatus, 'M');
      expect(
        app.git.branchesFor(projectId)!.map((Branch b) => b.name),
        <String>['main', 'feature/x'],
      );
    });

    test(
      'commit records a git error and rethrows when the message is empty',
      () async {
        final String projectId = (await fake.listProjects()).single.id;
        await app.git.refresh('fake', projectId);

        final Future<String> bad = app.git.commit('fake', projectId, '');
        expect(app.git.isBusy(projectId), isTrue);
        await expectLater(
          bad,
          throwsA(
            isA<DaemonError>().having(
              (DaemonError e) => e.code,
              'code',
              kErrGit,
            ),
          ),
        );
        expect(app.git.isBusy(projectId), isFalse);
        expect(app.git.errorFor(projectId), isA<DaemonError>());

        // A subsequent success clears the error.
        final String hash = await app.git.commit(
          'fake',
          projectId,
          'fix stuff',
        );
        expect(hash, 'deadbeef');
        expect(app.git.errorFor(projectId), isNull);
      },
    );

    test(
      'diff returns canned diffs and checkout switches the status branch',
      () async {
        final String projectId = (await fake.listProjects()).single.id;
        await app.git.refresh('fake', projectId);

        final List<GitDiff> diffs = await app.git.diff('fake', projectId);
        expect(diffs.single.path, 'lib/main.dart');
        expect(diffs.single.patch, startsWith('--- a/lib/main.dart'));

        await app.git.checkout('fake', projectId, 'feature/x');
        await app.git.refresh('fake', projectId);
        expect(app.git.statusFor(projectId)!.branch, 'feature/x');
        expect(
          app.git
              .branchesFor(projectId)!
              .singleWhere((Branch b) => b.isCurrent)
              .name,
          'feature/x',
        );
      },
    );

    test(
      'session scope keys status/branches/errors per worktree session',
      () async {
        final String projectId = (await fake.listProjects()).single.id;
        final Session session = await app.sessions.create(
          'fake',
          projectId: projectId,
          providerId: 'omp',
          title: 'Worktree session',
          baseBranch: 'main',
        );
        expect(session.cwd, contains('.speeddial-worktrees'));

        // The session scope is a cache entry of its own: refreshing it shows
        // the worktree branch and leaves the project entry untouched.
        expect(app.git.statusFor(projectId, sessionId: session.id), isNull);
        await app.git.refresh('fake', projectId, sessionId: session.id);
        final GitStatus sessionStatus = app.git.statusFor(
          projectId,
          sessionId: session.id,
        )!;
        expect(sessionStatus.branch, 'speeddial/${session.id}');
        expect(sessionStatus.files, isEmpty);
        expect(
          app.git.branchesFor(projectId, sessionId: session.id)!.single.name,
          'speeddial/${session.id}',
        );
        expect(
          app.git.statusFor(projectId),
          isNull,
          reason: 'project scope stays empty until refreshed itself',
        );

        await app.git.refresh('fake', projectId);
        expect(app.git.statusFor(projectId)!.branch, 'main');
        expect(
          app.git.statusFor(projectId)!.files,
          isNotEmpty,
          reason: 'the project checkout still has its own change',
        );

        // Errors are scoped too: a failing commit under the session does not
        // mark the project entry.
        await expectLater(
          app.git.commit('fake', projectId, '', sessionId: session.id),
          throwsA(isA<DaemonError>()),
        );
        expect(
          app.git.errorFor(projectId, sessionId: session.id),
          isA<DaemonError>(),
        );
        expect(app.git.errorFor(projectId), isNull);

        // A session of another project is rejected (refresh records it).
        final Project other = await fake.addProject('/other');
        final Session otherSession = await app.sessions.create(
          'fake',
          projectId: other.id,
          providerId: 'omp',
        );
        await app.git.refresh('fake', projectId, sessionId: otherSession.id);
        expect(
          app.git.errorFor(projectId, sessionId: otherSession.id),
          isA<DaemonError>(),
        );
        expect(
          app.git.statusFor(projectId, sessionId: otherSession.id),
          isNull,
        );
      },
    );

    test(
      'refreshSessionSummaries populates badges and replaces stale entries',
      () async {
        final String projectId = (await fake.listProjects()).single.id;
        expect(app.git.sessionSummaryFor('sess-1'), isNull);

        await app.git.refreshSessionSummaries('fake', projectId);
        final SessionGitSummary first = app.git.sessionSummaryFor('sess-1')!;
        expect(first.dirty, isTrue);
        expect(first.aheadOfBase, 2);
        expect(first.mergedIntoBase, isFalse);
        expect(app.git.sessionSummaryFor('sess-2')!.dirty, isTrue);
        expect(app.git.sessionSummaryFor('sess-2')!.aheadOfBase, isNull);
        expect(app.git.sessionSummaryErrorFor('fake', projectId), isNull);

        // The daemon drops archived sessions from the batch; the store must
        // drop their cached summaries rather than keep stale badges.
        await fake.archiveSession('sess-2', true);
        // The archive notification itself triggers a refresh (idle session);
        // wait for the replacement to settle, then assert.
        await _waitUntil(() => app.git.sessionSummaryFor('sess-2') == null);
        expect(app.git.sessionSummaryFor('sess-1'), isNotNull);

        // Scripted change lands on the next refresh.
        fake.sessionGitSummaries['sess-1'] = const SessionGitSummary(
          sessionId: 'sess-1',
          dirty: false,
          aheadOfBase: 0,
          behindBase: 0,
          mergedIntoBase: true,
        );
        await app.git.refreshSessionSummaries('fake', projectId);
        final SessionGitSummary merged = app.git.sessionSummaryFor('sess-1')!;
        expect(merged.dirty, isFalse);
        expect(merged.mergedIntoBase, isTrue);
      },
    );

    test('refreshSessionSummaries records failures without throwing', () async {
      await app.git.refreshSessionSummaries('fake', 'nope');
      expect(
        app.git.sessionSummaryErrorFor('fake', 'nope'),
        isA<DaemonError>(),
      );
    });

    test(
      'an idle session update refetches summaries for a known project',
      () async {
        final String projectId = (await fake.listProjects()).single.id;
        await app.git.refreshSessionSummaries('fake', projectId);
        expect(app.git.sessionSummaryFor('sess-1')!.mergedIntoBase, isFalse);

        // The turn ended daemon-side (agents commit mid-turn): the next idle
        // session update must pull the fresh summaries on its own.
        fake.sessionGitSummaries['sess-1'] = const SessionGitSummary(
          sessionId: 'sess-1',
          dirty: false,
          aheadOfBase: 0,
          behindBase: 0,
          mergedIntoBase: true,
        );
        await fake.renameSession('sess-1', 'Renamed (idle update)');
        await _waitUntil(
          () => app.git.sessionSummaryFor('sess-1')?.mergedIntoBase == true,
        );
      },
    );

    test(
      'a git.changed notification refetches summaries for a known project',
      () async {
        final String projectId = (await fake.listProjects()).single.id;
        await app.git.refreshSessionSummaries('fake', projectId);
        expect(app.git.sessionSummaryFor('sess-1')!.behindBase, 0);

        // The daemon's watcher noticed the base move on the remote: the
        // notification alone must pull the fresh summaries, with no turn
        // having ended and no manual refresh.
        fake.sessionGitSummaries['sess-1'] = const SessionGitSummary(
          sessionId: 'sess-1',
          dirty: false,
          aheadOfBase: 1,
          behindBase: 3,
          mergedIntoBase: false,
        );
        fake.gitChangedController.add(projectId);
        await _waitUntil(
          () => app.git.sessionSummaryFor('sess-1')?.behindBase == 3,
        );
      },
    );
  });
}
