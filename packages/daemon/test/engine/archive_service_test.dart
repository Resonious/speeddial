@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_daemon/src/engine/session_engine.dart';
import 'package:speeddial_daemon/src/git/git_service.dart';
import 'package:speeddial_daemon/src/providers/provider_registry.dart';
import 'package:speeddial_daemon/src/store/daemon_store.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:test/test.dart';

class _ControlledGit extends GitService {
  String? failPath;
  final Completer<void> entered = Completer<void>();
  Completer<void>? release;

  @override
  Future<void> removeLinkedWorktree(String path) async {
    if (!entered.isCompleted) entered.complete();
    await release?.future;
    if (path == failPath) {
      throw DaemonError(kErrGit, 'Test worktree removal failure');
    }
    await super.removeLinkedWorktree(path);
  }
}

void main() {
  late Directory temporary;
  late Directory projectDirectory;
  late DaemonStore store;
  late SessionEngine engine;
  late _ControlledGit git;

  Future<void> runGit(List<String> args) async {
    final ProcessResult result = await Process.run(
      'git',
      args,
      workingDirectory: projectDirectory.path,
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
  }

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('archive_service_test');
    projectDirectory = Directory(p.join(temporary.path, 'project'))
      ..createSync();
    await runGit(<String>['init', '-b', 'main']);
    File(p.join(projectDirectory.path, 'readme.txt'))
        .writeAsStringSync('original');
    await runGit(<String>['add', '.']);
    await runGit(<String>[
      '-c',
      'user.name=Test',
      '-c',
      'user.email=test@example.invalid',
      'commit',
      '-m',
      'initial',
    ]);
    store = DaemonStore(p.join(temporary.path, 'daemon.db'));
    final DateTime now = DateTime.now().toUtc();
    store.insertProject(
      Project(
        id: 'project',
        name: 'Project',
        path: projectDirectory.path,
        addedAt: now,
        lastActiveAt: now,
      ),
    );
    git = _ControlledGit();
    engine = SessionEngine(
      store: store,
      providers: ProviderRegistry(configOverrides: const <String, Object?>{}),
      git: git,
      autoArchiveAfter: Duration.zero,
    );
  });

  tearDown(() async {
    if (git.release != null && !git.release!.isCompleted) {
      git.release!.complete();
    }
    await engine.dispose();
    store.dispose();
    await temporary.delete(recursive: true);
  });

  void insert(
    String id,
    String cwd, {
    bool archived = true,
    bool pinned = false,
    bool preparing = false,
    SessionStatus status = SessionStatus.idle,
    String? baseBranch = 'main',
  }) {
    final DateTime now = DateTime.now().toUtc();
    store.insertSession(
      Session(
        id: id,
        projectId: 'project',
        providerId: 'fake',
        title: id,
        status: status,
        model: null,
        cwd: cwd,
        baseBranch: baseBranch,
        yolo: false,
        archived: archived,
        pinned: pinned,
        preparing: preparing,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  Future<String> worktree(String name) async {
    final String path = p.join(temporary.path, '.speeddial-worktrees', name);
    await git.addWorktree(
      projectDirectory.path,
      path: path,
      branch: name,
      baseRef: 'HEAD',
    );
    return path;
  }

  test('preview measures worktree files and UTF-8 transcripts; clear removes dirty worktree and payloads', () async {
    final String path = await worktree('one');
    insert(
      'one',
      path,
      pinned: true,
    ); // Explicit cleanup includes archived pins.
    final File dirty = File(p.join(path, 'untracked.bin'))
      ..writeAsBytesSync(List<int>.filled(1024, 1));
    final File outside = File(p.join(temporary.path, 'outside'))
      ..writeAsBytesSync(List<int>.filled(8192, 2));
    if (!Platform.isWindows) {
      await Link(p.join(path, 'external-link')).create(outside.path);
    }
    final SessionEvent event = store.appendEvent(
      'one',
      1,
      const UserMessageEvent(text: '日本語 transcript'),
    );
    store.insertAttachment(
      'one',
      const AttachmentData(
        id: 'attachment',
        name: 'note',
        mimeType: 'text/plain',
        size: 2,
        data: 'aGk=',
      ),
    );
    final List<String> removed = <String>[];
    final StreamSubscription<String> subscription = engine.sessionRemovals
        .listen(removed.add);
    addTearDown(subscription.cancel);

    final ArchivePreview preview = await engine.previewArchive();
    expect(preview.sessionIds, <String>['one']);
    expect(preview.worktreeCount, 1);
    expect(
      preview.worktreeBytes,
      await dirty.length() +
          await File(p.join(path, 'readme.txt')).length() +
          await File(p.join(path, '.git')).length(),
    );
    expect(
      preview.transcriptBytes,
      utf8.encode(jsonEncode(event.toJson())).length,
    );
    expect(preview.attachmentBytes, 2);

    final ClearArchiveResult result = await engine.clearArchive(
      preview.sessionIds,
    );
    await Future<void>.delayed(Duration.zero);
    expect(result.deletedSessionIds, <String>['one']);
    expect(result.removedWorktreeCount, 1);
    expect(result.failures, isEmpty);
    expect(removed, <String>['one']);
    expect(await Directory(path).exists(), isFalse);
    expect(await outside.exists(), isTrue);
    expect(store.getSession('one'), isNull);
    expect(store.listEvents('one').events, isEmpty);
    expect(store.getAttachment('one', 'attachment'), isNull);
    final ProcessResult registered = await Process.run('git', <String>[
      'worktree',
      'list',
      '--porcelain',
    ], workingDirectory: projectDirectory.path);
    expect(registered.stdout, isNot(contains(path)));
    await runGit(<String>['show-ref', '--verify', 'refs/heads/one']);
  });

  test('shared archived forks count and remove a worktree once', () async {
    final String path = await worktree('shared');
    insert('original', path);
    insert('fork', path);
    final ArchivePreview preview = await engine.previewArchive();
    expect(preview.sessionIds, hasLength(2));
    expect(preview.worktreeCount, 1);
    final ClearArchiveResult result = await engine.clearArchive(
      preview.sessionIds,
    );
    expect(result.deletedSessionIds, hasLength(2));
    expect(result.removedWorktreeCount, 1);
  });

  test('worktrees used by a surviving session and project directories are preserved', () async {
    final String path = await worktree('surviving');
    insert('archived', path);
    insert('survivor', path, archived: false);
    insert(
      'project-root',
      projectDirectory.path,
    ); // Even a malformed baseBranch cannot delete a project.
    final ArchivePreview preview = await engine.previewArchive();
    expect(preview.retainedWorktreeCount, 1);
    expect(preview.worktreeCount, 0);
    final ClearArchiveResult result = await engine.clearArchive(
      preview.sessionIds,
    );
    expect(
      result.deletedSessionIds,
      unorderedEquals(<String>['archived', 'project-root']),
    );
    expect(await Directory(path).exists(), isTrue);
    expect(await projectDirectory.exists(), isTrue);
    expect(store.getSession('survivor'), isNotNull);
  });

  test('a nested project protects its enclosing worktree', () async {
    final String path = await worktree('nested');
    insert('one', path);
    final Directory child = Directory(p.join(path, 'nested-project'))
      ..createSync();
    final DateTime now = DateTime.now().toUtc();
    store.insertProject(
      Project(
        id: 'nested',
        name: 'Nested',
        path: child.path,
        addedAt: now,
        lastActiveAt: now,
      ),
    );
    final ClearArchiveResult result = await engine.clearArchive(<String>[
      'one',
    ]);
    expect(result.deletedSessionIds, <String>['one']);
    expect(result.removedWorktreeCount, 0);
    expect(await child.exists(), isTrue);
  });

  test(
    'restored sessions and sessions archived after preview are not deleted',
    () async {
      insert('old', projectDirectory.path, baseBranch: null);
      insert('new', projectDirectory.path, archived: false, baseBranch: null);
      final ArchivePreview preview = await engine.previewArchive();
      await engine.archive('old', false);
      await engine.archive('new', true);
      final ClearArchiveResult result = await engine.clearArchive(
        preview.sessionIds,
      );
      expect(result.deletedSessionIds, isEmpty);
      expect(result.failures.single.sessionId, 'old');
      expect(store.getSession('old'), isNotNull);
      expect(store.getSession('new'), isNotNull);
    },
  );

  test('active and preparing archived sessions are blocked', () async {
    insert('running', projectDirectory.path, status: SessionStatus.running);
    insert(
      'permission',
      projectDirectory.path,
      status: SessionStatus.waitingPermission,
    );
    insert('preparing', projectDirectory.path, preparing: true);
    final ArchivePreview preview = await engine.previewArchive();
    expect(preview.sessionIds, isEmpty);
    expect(preview.blockedSessions, hasLength(3));
    final ClearArchiveResult result = await engine.clearArchive(<String>[
      'running',
      'permission',
      'preparing',
    ]);
    expect(result.deletedSessionIds, isEmpty);
    expect(result.failures, hasLength(3));
  });

  test(
    'missing worktrees delete metadata; invalid registrations remain retryable',
    () async {
      insert('missing', p.join(temporary.path, '.speeddial-worktrees', 'gone'));
      final Directory invalid = Directory(
        p.join(temporary.path, '.speeddial-worktrees', 'invalid'),
      )..createSync(recursive: true);
      File(p.join(invalid.path, 'keep.txt')).writeAsStringSync('keep');
      insert('invalid', invalid.path);
      final ArchivePreview preview = await engine.previewArchive();
      expect(preview.sessionIds, <String>['missing']);
      expect(preview.blockedSessions.single.sessionId, 'invalid');
      final ClearArchiveResult result = await engine.clearArchive(<String>[
        'missing',
        'invalid',
      ]);
      expect(result.deletedSessionIds, <String>['missing']);
      expect(result.failures.single.sessionId, 'invalid');
      expect(store.getSession('invalid'), isNotNull);
      expect(await File(p.join(invalid.path, 'keep.txt')).exists(), isTrue);
    },
  );

  test(
    'Git failures retain records and transcripts while other groups clear',
    () async {
      final String failed = await worktree('failed');
      final String good = await worktree('good');
      insert('failed', failed);
      insert('good', good);
      store.appendEvent(
        'failed',
        1,
        const UserMessageEvent(text: 'Retain history'),
      );
      git.failPath = failed;
      final ClearArchiveResult result = await engine.clearArchive(<String>[
        'failed',
        'good',
      ]);
      expect(result.deletedSessionIds, <String>['good']);
      expect(result.failures.single.sessionId, 'failed');
      expect(store.getSession('failed'), isNotNull);
      expect(store.listEvents('failed').events, hasLength(1));
      expect(await Directory(failed).exists(), isTrue);
    },
  );

  test(
    'cleanup rejects racing session changes and shutdown waits for cleanup',
    () async {
      final String path = await worktree('gated');
      insert('one', path);
      git.release = Completer<void>();
      final Future<ClearArchiveResult> cleanup = engine.clearArchive(<String>[
        'one',
      ]);
      await git.entered.future;
      expect(engine.hasActiveSessions, isTrue);
      expect(engine.prepareForRestart(), isFalse);
      await expectLater(
        engine.archive('one', false),
        throwsA(
          isA<DaemonError>().having(
            (DaemonError error) => error.code,
            'code',
            kErrConflict,
          ),
        ),
      );
      await expectLater(
        engine.sendMessage('one', 'new work'),
        throwsA(isA<DaemonError>()),
      );
      expect(
        () => engine.clearArchive(<String>['one']),
        throwsA(isA<DaemonError>()),
      );
      bool stopped = false;
      final Future<void> shutdown = engine.dispose().then(
        (_) => stopped = true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(stopped, isFalse);
      git.release!.complete();
      expect((await cleanup).deletedSessionIds, <String>['one']);
      await shutdown;
      expect(stopped, isTrue);
    },
  );
}
