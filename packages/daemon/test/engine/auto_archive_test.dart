@TestOn('vm')
library;

import 'dart:async';

import 'package:speeddial_daemon/src/engine/session_engine.dart';
import 'package:speeddial_daemon/src/providers/provider_registry.dart';
import 'package:speeddial_daemon/src/store/daemon_store.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:test/test.dart';

void main() {
  final DateTime now = DateTime.utc(2026, 10, 12, 12);
  late DaemonStore store;
  late SessionEngine engine;
  late StreamSubscription<Session> subscription;
  final List<Session> changes = <Session>[];

  SessionEngine createEngine({
    Duration timeout = const Duration(hours: 72),
    Duration interval = const Duration(minutes: 1),
    int keep = 0,
  }) => SessionEngine(
    store: store,
    providers: ProviderRegistry(configOverrides: const <String, Object?>{}),
    autoArchiveAfter: timeout,
    autoArchiveCheckInterval: interval,
    autoArchiveKeep: keep,
  );

  Session insert(
    String id, {
    DateTime? activity,
    SessionStatus status = SessionStatus.idle,
    bool pinned = false,
    bool archived = false,
    bool preparing = false,
    bool done = false,
  }) {
    final DateTime timestamp =
        activity ?? now.subtract(const Duration(days: 4));
    final Session session = Session(
      id: id,
      projectId: 'p1',
      providerId: 'fake',
      title: id,
      status: status,
      model: null,
      cwd: '/unused',
      baseBranch: null,
      yolo: false,
      pinned: pinned,
      archived: archived,
      preparing: preparing,
      done: done,
      completionRevision: done ? 3 : 0,
      createdAt: timestamp,
      lastActivityAt: timestamp,
      updatedAt: now,
    );
    store.insertSession(session);
    return session;
  }

  setUp(() {
    store = DaemonStore(':memory:');
    store.insertProject(
      Project(
        id: 'p1',
        name: 'Test',
        path: '/unused',
        addedAt: now,
        lastActiveAt: now,
      ),
    );
    engine = createEngine();
    changes.clear();
    subscription = engine.sessionChanges.listen(changes.add);
  });

  tearDown(() async {
    await subscription.cancel();
    await engine.dispose();
    store.dispose();
  });

  test('default keeps five unpinned sessions, excluding pins and archived sessions from the count', () async {
    await engine.dispose();
    engine = SessionEngine(
      store: store,
      providers: ProviderRegistry(configOverrides: const <String, Object?>{}),
    );
    final DateTime oldest = now.subtract(const Duration(days: 4));
    for (int index = 0; index < 3; index++) {
      insert('session-$index', activity: oldest.add(Duration(hours: index)));
      insert('pinned-$index', pinned: true);
      insert('archived-$index', archived: true);
    }
    engine.archiveInactiveSessions(now: now);
    expect(
      store.listSessions().where((Session session) => !session.pinned),
      hasLength(3),
    );
    for (int index = 3; index < 5; index++) {
      insert('session-$index', activity: oldest.add(Duration(hours: index)));
    }
    engine.archiveInactiveSessions(now: now);
    expect(
      store.listSessions().where((Session session) => !session.pinned),
      hasLength(5),
    );
    insert('session-5', activity: oldest.add(const Duration(hours: 5)));
    engine.archiveInactiveSessions(now: now);
    expect(store.getSession('session-0')!.archived, isTrue);
    expect(
      store
          .listSessions()
          .where((Session session) => !session.pinned)
          .map((Session session) => session.id),
      unorderedEquals(<String>[
        'session-1',
        'session-2',
        'session-3',
        'session-4',
        'session-5',
      ]),
    );
    engine.archiveInactiveSessions(now: now.add(const Duration(days: 365)));
    expect(
      store.listSessions().where((Session session) => !session.pinned),
      hasLength(5),
    );
  });

  test('custom keep count archives the oldest excess and leaves the most recent sessions', () async {
    await engine.dispose();
    engine = createEngine(keep: 2);
    final DateTime oldest = now.subtract(const Duration(days: 4));
    for (int index = 0; index < 9; index++) {
      insert('session-$index', activity: oldest.add(Duration(hours: index)));
    }
    engine.archiveInactiveSessions(now: now);
    expect(
      store.listSessions().map((Session session) => session.id),
      unorderedEquals(<String>['session-7', 'session-8']),
    );
  });

  test('recent sessions count toward the floor but are never forced into the archive', () async {
    await engine.dispose();
    engine = createEngine(keep: 5);
    for (int index = 0; index < 6; index++) {
      insert(
        'old-$index',
        activity: now
            .subtract(const Duration(days: 4))
            .add(Duration(hours: index)),
      );
    }
    insert('recent-1', activity: now);
    insert('recent-2', activity: now);
    engine.archiveInactiveSessions(now: now);
    expect(
      store.listSessions().map((Session session) => session.id),
      unorderedEquals(<String>[
        'old-3',
        'old-4',
        'old-5',
        'recent-1',
        'recent-2',
      ]),
    );
    await engine.dispose();
    engine = createEngine(keep: 2);
    for (int index = 3; index < 6; index++) {
      insert('recent-$index', activity: now);
    }
    engine.archiveInactiveSessions(now: now);
    expect(store.listSessions(), hasLength(5));
    expect(
      store.listSessions().every(
        (Session session) => session.id.startsWith('recent'),
      ),
      isTrue,
    );
  });

  test(
    'running, permission-waiting and preparing sessions count toward the floor',
    () async {
      await engine.dispose();
      engine = createEngine(keep: 5);
      insert('running', status: SessionStatus.running);
      insert('permission', status: SessionStatus.waitingPermission);
      insert('preparing', preparing: true);
      for (int index = 0; index < 4; index++) {
        insert(
          'idle-$index',
          activity: now
              .subtract(const Duration(days: 4))
              .add(Duration(hours: index)),
        );
      }
      engine.archiveInactiveSessions(now: now);
      expect(
        store.listSessions().map((Session session) => session.id),
        unorderedEquals(<String>[
          'running',
          'permission',
          'preparing',
          'idle-2',
          'idle-3',
        ]),
      );
    },
  );

  test('keep floor applies across projects on the daemon', () async {
    await engine.dispose();
    engine = createEngine(keep: 2);
    store.insertProject(
      Project(
        id: 'p2',
        name: 'Other',
        path: '/other',
        addedAt: now,
        lastActiveAt: now,
      ),
    );
    insert('oldest', activity: now.subtract(const Duration(days: 5)));
    insert('first-project', activity: now.subtract(const Duration(days: 4)));
    final Session other = insert(
      'other-project',
      activity: now.subtract(const Duration(days: 3)),
    );
    store.updateSession(
      Session.fromJson(<String, Object?>{...other.toJson(), 'projectId': 'p2'}),
    );
    engine.archiveInactiveSessions(now: now);
    expect(store.getSession('oldest')!.archived, isTrue);
    expect(store.getSession('first-project')!.archived, isFalse);
    expect(store.getSession('other-project')!.archived, isFalse);
  });

  test('negative keep count is rejected', () {
    expect(() => createEngine(keep: -1), throwsArgumentError);
  });

  test('archives at 72 hours and preserves newer or pinned sessions', () async {
    insert('boundary', activity: now.subtract(const Duration(hours: 72)));
    insert(
      'recent',
      activity: now.subtract(
        const Duration(hours: 72) - const Duration(milliseconds: 1),
      ),
    );
    insert('pinned', pinned: true);
    insert('old', done: true);
    insert('error', status: SessionStatus.error);
    insert('closed', status: SessionStatus.closed);
    insert('archived', archived: true);

    engine.archiveInactiveSessions(now: now);
    await Future<void>.delayed(Duration.zero);

    expect(
      changes.map((Session session) => session.id),
      unorderedEquals(<String>['boundary', 'old', 'error', 'closed']),
    );
    expect(changes.every((Session session) => session.archived), isTrue);
    expect(store.getSession('recent')!.archived, isFalse);
    expect(store.getSession('pinned')!.archived, isFalse);
    expect(store.getSession('old')!.done, isFalse);
    expect(store.getSession('old')!.completionRevision, 3);
    expect(
      store.getSession('old')!.lastActivityAt,
      now.subtract(const Duration(days: 4)),
    );
    expect(
      store.listSessions().map((Session session) => session.id),
      unorderedEquals(<String>['recent', 'pinned']),
    );

    engine.archiveInactiveSessions(now: now);
    await Future<void>.delayed(Duration.zero);
    expect(changes, hasLength(4));
  });

  test(
    'background events postpone archival and history and attachments survive',
    () {
      insert('background');
      final SessionEvent event = store.appendEvent(
        'background',
        1,
        AgentMessageChunkEvent(text: 'A background reply'),
      );
      const AttachmentData attachment = AttachmentData(
        id: 'attachment',
        name: 'note.txt',
        mimeType: 'text/plain',
        size: 2,
        data: 'aGk=',
      );
      store.insertAttachment('background', attachment);

      engine.archiveInactiveSessions(now: event.timestamp!);
      expect(store.getSession('background')!.archived, isFalse);

      engine.archiveInactiveSessions(
        now: event.timestamp!.add(const Duration(hours: 72)),
      );
      expect(store.getSession('background')!.archived, isTrue);
      expect(store.listEvents('background').events, hasLength(1));
      expect(
        store.getAttachment('background', attachment.id)!.data,
        attachment.data,
      );
    },
  );

  test('skips running, permission waits, and preparation', () async {
    insert('running', status: SessionStatus.running);
    insert('permission', status: SessionStatus.waitingPermission);
    insert('preparing', preparing: true);
    insert('failed-preparation', preparing: true, status: SessionStatus.error);

    engine.archiveInactiveSessions(now: now);
    await Future<void>.delayed(Duration.zero);

    expect(changes, isEmpty);
    expect(store.listSessions(), hasLength(4));
  });

  test('custom timeout and disabled archival', () async {
    await engine.dispose();
    engine = createEngine(timeout: const Duration(hours: 24));
    insert('day', activity: now.subtract(const Duration(hours: 24)));
    insert('recent', activity: now.subtract(const Duration(hours: 23)));
    engine.archiveInactiveSessions(now: now);
    expect(store.getSession('day')!.archived, isTrue);
    expect(store.getSession('recent')!.archived, isFalse);

    await engine.dispose();
    engine = createEngine(timeout: Duration.zero);
    insert('disabled');
    await engine.restore();
    engine.archiveInactiveSessions(now: now.add(const Duration(days: 365)));
    expect(store.getSession('disabled')!.archived, isFalse);
  });

  test('unpinning and restoring start fresh inactivity windows', () async {
    insert('pinned', pinned: true);
    insert('archived', archived: true);
    final Session unpinned = await engine.pin('pinned', false);
    final Session restored = await engine.archive('archived', false);
    engine.archiveInactiveSessions();
    expect(store.getSession('pinned')!.archived, isFalse);
    expect(store.getSession('archived')!.archived, isFalse);
    final Session repeated = await engine.archive('archived', false);
    expect(repeated.lastActivityAt, restored.lastActivityAt);

    engine.archiveInactiveSessions(
      now: restored.lastActivityAt.add(const Duration(hours: 72, seconds: 1)),
    );
    expect(store.getSession('archived')!.archived, isTrue);
    expect(store.getSession('pinned')!.archived, isTrue);
    expect(
      unpinned.lastActivityAt.isAfter(now.subtract(const Duration(days: 4))),
      isTrue,
    );
  });

  test(
    'startup archives old sessions and gives interrupted turns a window',
    () async {
      final DateTime old = DateTime.now().toUtc().subtract(
        const Duration(days: 4),
      );
      insert('old', activity: old);
      insert('pinned', activity: old, pinned: true);
      insert('interrupted', activity: old, status: SessionStatus.running);
      await engine.restore();
      expect(store.getSession('old')!.archived, isTrue);
      expect(store.getSession('pinned')!.archived, isFalse);
      final Session interrupted = store.getSession('interrupted')!;
      expect(interrupted.status, SessionStatus.error);
      expect(interrupted.archived, isFalse);
      expect(interrupted.lastActivityAt.isAfter(old), isTrue);
    },
  );

  test(
    'periodic archival works without clients and stops on disposal',
    () async {
      await engine.dispose();
      engine = createEngine(interval: const Duration(milliseconds: 10));
      final List<Timer> timers = <Timer>[];
      await runZoned(
        () async {
          await engine.restore();
          final Future<Session> archived = engine.sessionChanges.firstWhere(
            (Session session) => session.id == 'periodic' && session.archived,
          );
          insert(
            'periodic',
            activity: DateTime.now().toUtc().subtract(const Duration(days: 4)),
          );
          await archived.timeout(const Duration(seconds: 5));
          expect(store.getSession('periodic')!.archived, isTrue);
          expect(timers, hasLength(1));
          expect(timers.single.isActive, isTrue);
          await engine.dispose();
          expect(timers.single.isActive, isFalse);
        },
        zoneSpecification: ZoneSpecification(
          createPeriodicTimer:
              (
                Zone self,
                ZoneDelegate parent,
                Zone zone,
                Duration duration,
                void Function(Timer) callback,
              ) {
                final Timer timer = parent.createPeriodicTimer(
                  zone,
                  duration,
                  callback,
                );
                timers.add(timer);
                return timer;
              },
        ),
      );
    },
  );
}
