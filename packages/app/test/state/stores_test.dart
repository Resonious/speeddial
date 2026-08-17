import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/scope.dart';

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

Future<void> _flushMicrotasks() =>
    Future<void>.delayed(Duration.zero);

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

  test('clientFor resolves registered clients and rejects unknown ids', () async {
    expect(app.clientFor('fake'), same(fake));
    expect(
      () => app.clientFor('nope'),
      throwsA(isA<StateError>()),
    );
  });

  group('projects', () {
    test('refresh/add/remove update the cache and lastError stays null', () async {
      expect(app.projects.projectsFor('fake'), isEmpty);

      await app.projects.refresh('fake');
      expect(app.projects.isLoading('fake'), isFalse);
      final List<Project> seeded = app.projects.projectsFor('fake');
      expect(seeded, hasLength(1));
      expect(seeded.single.name, 'Demo Project');
      expect(seeded.single.path, '/demo');

      final Project added =
          await app.projects.add('fake', '/work/other', name: 'Other');
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
    });

    test('isLoading is true while a refresh is in flight', () async {
      final Future<void> refreshing = app.projects.refresh('fake');
      expect(app.projects.isLoading('fake'), isTrue);
      await refreshing;
      expect(app.projects.isLoading('fake'), isFalse);
    });
  });

  group('sessions', () {
    test('create/refresh/rename/archive/delete keep the cache consistent', () async {
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
    });
  });

  group('chat', () {
    test('watch buffers events, merges chunks, derives status and usage', () async {
      final String sessionId = (await fake.listSessions()).first.id;
      app.chat.watchSession('fake', sessionId);

      await app.chat.send('fake', sessionId, 'hello');
      await _waitUntil(() => app.chat
          .eventsFor(sessionId)
          .any((SessionEvent e) => e is TurnCompleteEvent));

      final List<SessionEvent> events = app.chat.eventsFor(sessionId);
      // The three chunk deltas merged into a single concatenated event.
      final List<AgentMessageChunkEvent> chunks =
          events.whereType<AgentMessageChunkEvent>().toList();
      expect(chunks, hasLength(1));
      expect(chunks.single.text,
          'Working on it…```dart\nvoid main() {}\n```Done.');

      // Tool call appears once per status transition, plan and usage once.
      expect(events.whereType<ToolCallEvent>(), hasLength(2));
      expect(events.whereType<PlanEvent>().single.entries, hasLength(2));
      expect(app.chat.usageOf(sessionId)?.totalTokens, 1500);
      expect(events.last, isA<TurnCompleteEvent>());

      // Status: idle once the turn completed.
      expect(app.chat.statusOf(sessionId), SessionStatus.idle);
      expect(app.chat.modeOf(sessionId), SessionMode.build);
    });

    test('permission flow via the store parks then resolves', () async {
      final String sessionId = (await fake.listSessions()).first.id;
      app.chat.watchSession('fake', sessionId);

      await app.chat.send('fake', sessionId, 'please grant permission');
      await _waitUntil(() => app.chat
          .eventsFor(sessionId)
          .any((SessionEvent e) => e is PermissionRequestEvent));

      expect(app.chat.statusOf(sessionId), SessionStatus.waitingPermission);
      expect(
        app.chat.eventsFor(sessionId).any((SessionEvent e) => e is TurnCompleteEvent),
        isFalse,
      );

      final PermissionRequestEvent request = app.chat
          .eventsFor(sessionId)
          .singleWhere((SessionEvent e) => e is PermissionRequestEvent)
          as PermissionRequestEvent;
      await app.chat.respondPermission(
        'fake',
        sessionId,
        request.request.requestId,
        request.request.options.first.optionId,
      );

      await _waitUntil(() => app.chat
          .eventsFor(sessionId)
          .any((SessionEvent e) => e is TurnCompleteEvent));
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
      await _waitUntil(() async =>
          (await fake.history(sessionId)).any((SessionEvent e) => e is TurnCompleteEvent));

      int notifications = 0;
      app.chat.addListener(() => notifications++);

      app.chat.watchSession('fake', sessionId);
      await _flushMicrotasks();

      // 9 history events (userMessage + turn) arrive in one batch;
      // notifications are coalesced; 3 chunks merged → 1.
      expect(app.chat.eventsFor(sessionId).length, 7);
      expect(notifications, 1);

      // A second watch for the same session is a no-op.
      app.chat.watchSession('fake', sessionId);
      await _flushMicrotasks();
      expect(notifications, 1);
    });

    test('unwatch stops buffering and releases per-daemon subscriptions', () async {
      final String sessionId = (await fake.listSessions()).first.id;
      app.chat.watchSession('fake', sessionId);
      await app.chat.send('fake', sessionId, 'hello');
      await _waitUntil(() => app.chat
          .eventsFor(sessionId)
          .any((SessionEvent e) => e is TurnCompleteEvent));

      app.chat.unwatch(sessionId);
      expect(app.chat.eventsFor(sessionId), isEmpty);
      expect(app.chat.statusOf(sessionId), SessionStatus.idle);

      // Watching again reloads history (duplicates dropped by seq).
      app.chat.watchSession('fake', sessionId);
      await _flushMicrotasks();
      final List<SessionEvent> events = app.chat.eventsFor(sessionId);
      expect(events.whereType<AgentMessageChunkEvent>().single.text,
          'Working on it…```dart\nvoid main() {}\n```Done.');
      expect(events.whereType<TurnCompleteEvent>(), hasLength(1));
    });
  });

  group('files', () {
    test('entriesFor is null until loaded, then cached per directory', () async {
      final String projectId = (await fake.listProjects()).single.id;

      expect(app.files.entriesFor(projectId, '.'), isNull);

      await app.files.loadDir('fake', projectId, '.');
      final List<FileEntry>? root = app.files.entriesFor(projectId, '.');
      expect(root, isNotNull);
      expect(root!.map((FileEntry e) => e.name),
          <String>['lib', 'main.dart', 'pubspec.yaml']);
      expect(root.map((FileEntry e) => e.isDir).toList(),
          <bool>[true, false, false]);

      // Subdirectory loads independently.
      expect(app.files.entriesFor(projectId, 'lib'), isNull);
      await app.files.loadDir('fake', projectId, 'lib');
      expect(app.files.entriesFor(projectId, 'lib')!.single.name, 'main.dart');
    });

    test('readFile passes through content from the client', () async {
      final String projectId = (await fake.listProjects()).single.id;
      final FileReadResult result =
          await app.files.readFile('fake', projectId, 'lib/main.dart');
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
      expect(app.git.branchesFor(projectId)!.map((Branch b) => b.name),
          <String>['main', 'feature/x']);
    });

    test('commit records a git error and rethrows when the message is empty', () async {
      final String projectId = (await fake.listProjects()).single.id;
      await app.git.refresh('fake', projectId);

      final Future<String> bad = app.git.commit('fake', projectId, '');
      expect(app.git.isBusy(projectId), isTrue);
      await expectLater(
        bad,
        throwsA(isA<DaemonError>()
            .having((DaemonError e) => e.code, 'code', kErrGit)),
      );
      expect(app.git.isBusy(projectId), isFalse);
      expect(app.git.errorFor(projectId), isA<DaemonError>());

      // A subsequent success clears the error.
      final String hash = await app.git.commit('fake', projectId, 'fix stuff');
      expect(hash, 'deadbeef');
      expect(app.git.errorFor(projectId), isNull);
    });

    test('diff returns canned diffs and checkout switches the status branch', () async {
      final String projectId = (await fake.listProjects()).single.id;
      await app.git.refresh('fake', projectId);

      final List<GitDiff> diffs = await app.git.diff('fake', projectId);
      expect(diffs.single.path, 'lib/main.dart');
      expect(diffs.single.patch, startsWith('--- a/lib/main.dart'));

      await app.git.checkout('fake', projectId, 'feature/x');
      await app.git.refresh('fake', projectId);
      expect(app.git.statusFor(projectId)!.branch, 'feature/x');
      expect(
        app.git.branchesFor(projectId)!.singleWhere((Branch b) => b.isCurrent).name,
        'feature/x',
      );
    });
  });
}
