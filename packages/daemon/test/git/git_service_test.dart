import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_daemon/src/git/git_service.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:test/test.dart';

Future<ProcessResult> _git(Directory repo, List<String> args) {
  return Process.run('git', args, workingDirectory: repo.path);
}

Future<Directory> _initRepo() async {
  final dir = await Directory.systemTemp.createTemp('sd_git_test_');
  await _git(dir, ['init', '-b', 'main']);
  await _git(dir, ['config', 'user.email', 'test@example.com']);
  await _git(dir, ['config', 'user.name', 'Test User']);
  return dir;
}

/// A repo cloned from a local bare "origin" (filesystem-only remote: no
/// network), so fetch/worktree flows have a real `origin/<branch>` to track.
Future<({Directory origin, Directory repo})> _initRepoWithOrigin() async {
  final parent = await Directory.systemTemp.createTemp('sd_git_wt_');
  final origin = Directory(p.join(parent.path, 'origin.git'));
  await Process.run('git', ['init', '--bare', '-b', 'main', origin.path]);
  final repo = Directory(p.join(parent.path, 'repo'));
  await Process.run('git', ['clone', origin.path, repo.path]);
  await _git(repo, ['config', 'user.email', 'test@example.com']);
  await _git(repo, ['config', 'user.name', 'Test User']);
  return (origin: origin, repo: repo);
}

Future<void> _write(Directory repo, String name, String content) async {
  await File(p.join(repo.path, name)).writeAsString(content);
}

Future<void> _commitAll(Directory repo, String message) async {
  await _git(repo, ['add', '-A']);
  await _git(repo, ['commit', '-m', message]);
}

void main() {
  late GitService service;

  setUp(() {
    service = GitService();
  });

  group('status', () {
    test('reports a clean repo', () async {
      final repo = await _initRepo();
      await _write(repo, 'a.txt', 'hello\n');
      await _commitAll(repo, 'init');

      final status = await service.status(repo.path);
      expect(status.branch, 'main');
      expect(status.ahead, 0);
      expect(status.behind, 0);
      expect(status.files, isEmpty);
    });

    test('detects modified, untracked and staged files with correct flags',
        () async {
      final repo = await _initRepo();
      await _write(repo, 'a.txt', 'v1\n');
      await _write(repo, 'tracked.txt', 'x\n');
      await _commitAll(repo, 'init');

      // modified (unstaged)
      await _write(repo, 'tracked.txt', 'y\n');
      // new untracked
      await _write(repo, 'untracked.txt', 'new\n');
      // staged new file
      await _write(repo, 'staged.txt', 's\n');
      await _git(repo, ['add', 'staged.txt']);
      // staged modification
      await _write(repo, 'a.txt', 'v2\n');
      await _git(repo, ['add', 'a.txt']);

      final status = await service.status(repo.path);
      final byPath = {for (final f in status.files) f.path: f};

      final modified = byPath['tracked.txt']!;
      expect(modified.indexStatus, '.');
      expect(modified.worktreeStatus, 'M');
      expect(modified.staged, isFalse);

      final untracked = byPath['untracked.txt']!;
      expect(untracked.indexStatus, '?');
      expect(untracked.worktreeStatus, '?');
      expect(untracked.staged, isFalse);

      final stagedNew = byPath['staged.txt']!;
      expect(stagedNew.indexStatus, 'A');
      expect(stagedNew.staged, isTrue);

      final stagedMod = byPath['a.txt']!;
      expect(stagedMod.indexStatus, 'M');
      expect(stagedMod.staged, isTrue);
    });
  });

  group('diff', () {
    test('returns empty list when nothing changed', () async {
      final repo = await _initRepo();
      await _write(repo, 'a.txt', 'hello\n');
      await _commitAll(repo, 'init');

      expect(await service.diff(repo.path), isEmpty);
    });

    test('modified file produces a patch', () async {
      final repo = await _initRepo();
      await _write(repo, 'a.txt', 'v1\n');
      await _commitAll(repo, 'init');
      await _write(repo, 'a.txt', 'v2\n');

      final diffs = await service.diff(repo.path);
      expect(diffs, hasLength(1));
      final d = diffs.single;
      expect(d.path, 'a.txt');
      expect(d.isNew, isFalse);
      expect(d.isDeleted, isFalse);
      expect(d.isBinary, isFalse);
      expect(d.patch, contains('diff --git'));
      expect(d.patch, contains('-v1'));
      expect(d.patch, contains('+v2'));
    });

    test('staged new and deleted files carry isNew/isDeleted flags', () async {
      final repo = await _initRepo();
      await _write(repo, 'keep.txt', 'k\n');
      await _write(repo, 'del.txt', 'bye\n');
      await _commitAll(repo, 'init');

      await _write(repo, 'new.txt', 'brand new\n');
      await _git(repo, ['add', 'new.txt']);
      await _git(repo, ['rm', 'del.txt']);

      final diffs = await service.diff(repo.path, staged: true);
      final byPath = {for (final d in diffs) d.path: d};

      final newFile = byPath['new.txt']!;
      expect(newFile.isNew, isTrue);
      expect(newFile.isDeleted, isFalse);
      expect(newFile.patch, contains('new file mode'));

      final deleted = byPath['del.txt']!;
      expect(deleted.isDeleted, isTrue);
      expect(deleted.isNew, isFalse);
      expect(deleted.patch, contains('deleted file mode'));
    });

    test('binary diff is flagged and yields no patch text', () async {
      final repo = await _initRepo();
      await File(p.join(repo.path, 'bin.dat'))
          .writeAsBytes([0, 1, 2, 3, 255]);
      await _commitAll(repo, 'init');
      await File(p.join(repo.path, 'bin.dat'))
          .writeAsBytes([0, 1, 2, 3, 254]);
      await _git(repo, ['add', 'bin.dat']);

      final diffs = await service.diff(repo.path, staged: true);
      expect(diffs, hasLength(1));
      expect(diffs.single.path, 'bin.dat');
      expect(diffs.single.isBinary, isTrue);
      expect(diffs.single.patch, isEmpty);
    });
  });

  group('branches', () {
    test('lists branches with current + upstream flags', () async {
      final repo = await _initRepo();
      await _write(repo, 'a.txt', 'x\n');
      await _commitAll(repo, 'init');
      await _git(repo, ['branch', 'feature']);

      final branches = await service.branches(repo.path);
      final byName = {for (final b in branches) b.name: b};

      expect(byName.keys, containsAll(['main', 'feature']));
      expect(byName['main']!.isCurrent, isTrue);
      expect(byName['feature']!.isCurrent, isFalse);
      // no remote, so no upstream
      expect(byName['main']!.upstream, isNull);
    });
  });

  group('checkout / createBranch / commit', () {
    test('createBranch switches to new branch and checkout moves back',
        () async {
      final repo = await _initRepo();
      await _write(repo, 'a.txt', 'x\n');
      await _commitAll(repo, 'init');

      await service.createBranch(repo.path, 'feature');
      var branches = await service.branches(repo.path);
      var feature =
          branches.firstWhere((b) => b.name == 'feature');
      expect(feature.isCurrent, isTrue);

      await service.checkout(repo.path, 'main');
      branches = await service.branches(repo.path);
      expect(branches.firstWhere((b) => b.name == 'main').isCurrent, isTrue);
      expect(branches.firstWhere((b) => b.name == 'feature').isCurrent,
          isFalse);
    });

    test('createBranch without checkout just creates', () async {
      final repo = await _initRepo();
      await _write(repo, 'a.txt', 'x\n');
      await _commitAll(repo, 'init');

      await service.createBranch(repo.path, 'feature', checkout: false);
      final branches = await service.branches(repo.path);
      final feature = branches.firstWhere((b) => b.name == 'feature');
      expect(feature.isCurrent, isFalse);
    });

    test('commit returns full hash and stageAll stages everything', () async {
      final repo = await _initRepo();
      await _write(repo, 'a.txt', 'x\n');
      await _commitAll(repo, 'init');

      // Unstaged new + modified files; stageAll must pick both up.
      await _write(repo, 'a.txt', 'y\n');
      await _write(repo, 'b.txt', 'z\n');

      final hash = await service.commit(repo.path, 'second', stageAll: true);
      expect(hash, matches(RegExp(r'^[0-9a-f]{40}$')));

      final rev = await _git(repo, ['rev-parse', 'HEAD']);
      expect(hash, (rev.stdout as String).trim());
      final status = await service.status(repo.path);
      expect(status.files, isEmpty);
    });

    test('checkout rejects dash-prefixed branch names', () async {
      final repo = await _initRepo();
      await _write(repo, 'a.txt', 'x\n');
      await _commitAll(repo, 'init');

      await expectLater(
        service.checkout(repo.path, '--delete'),
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', kErrGit)
            .having((e) => e.message, 'message', contains('invalid branch name'))),
      );
      expect((await service.branches(repo.path)).map((b) => b.name),
          isNot(contains('--delete')),
          reason: 'the crafted name must never reach git');
    });

    test('createBranch rejects dash-prefixed names with and without checkout',
        () async {
      final repo = await _initRepo();
      await _write(repo, 'a.txt', 'x\n');
      await _commitAll(repo, 'init');

      for (final call in <Future<void> Function()>[
        () => service.createBranch(repo.path, '-D'),
        () => service.createBranch(repo.path, '-D', checkout: false),
      ]) {
        await expectLater(
          call(),
          throwsA(isA<DaemonError>()
              .having((e) => e.code, 'code', kErrGit)
              .having((e) => e.message, 'message', contains('invalid branch name'))),
        );
      }
      expect((await service.branches(repo.path)).map((b) => b.name),
          isNot(contains('-D')),
          reason: 'the crafted name must never reach git');
    });
  });

  group('push', () {
    test('errors with DaemonError kErrGit when no remote configured',
        () async {
      final repo = await _initRepo();
      await _write(repo, 'a.txt', 'x\n');
      await _commitAll(repo, 'init');

      await expectLater(
        service.push(repo.path),
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', kErrGit)
            .having((e) => e.data, 'data', isNotNull)),
      );
    });
  });

  group('worktrees', () {
    test('fetch + addWorktree branches off the latest origin tip', () async {
      final repos = await _initRepoWithOrigin();
      final repo = repos.repo;
      await _write(repo, 'a.txt', 'v1\n');
      await _commitAll(repo, 'init');
      await _git(repo, ['push', '-u', 'origin', 'main']);

      // Advance origin/main through a second clone so fetch has new work.
      final other = Directory(
          p.join(repos.origin.parent.path, 'other'));
      await Process.run('git', ['clone', repos.origin.path, other.path]);
      await _git(other, ['config', 'user.email', 'test@example.com']);
      await _git(other, ['config', 'user.name', 'Test User']);
      await _write(other, 'b.txt', 'from other\n');
      await _commitAll(other, 'advance');
      await _git(other, ['push', 'origin', 'main']);
      final originTip = ((await _git(other, ['rev-parse', 'HEAD']))
              .stdout as String)
          .trim();

      await service.fetch(repo.path, 'main');
      final localTip =
          ((await _git(repo, ['rev-parse', 'origin/main'])).stdout as String)
              .trim();
      expect(localTip, originTip,
          reason: 'fetch must refresh the remote-tracking ref');

      final wtPath = p.join(repos.origin.parent.path, 'wt');
      await service.addWorktree(
        repo.path,
        path: wtPath,
        branch: 'speeddial/fix-login-1a2b3c4d',
        baseRef: 'origin/main',
      );
      final wtHead = ((await Process.run(
                  'git', ['rev-parse', 'HEAD'],
                  workingDirectory: wtPath))
              .stdout as String)
          .trim();
      expect(wtHead, originTip);
      final wtBranch = ((await Process.run(
                  'git', ['branch', '--show-current'],
                  workingDirectory: wtPath))
              .stdout as String)
          .trim();
      expect(wtBranch, 'speeddial/fix-login-1a2b3c4d');
      expect(File(p.join(wtPath, 'b.txt')).existsSync(), isTrue,
          reason: 'worktree must contain the latest origin content');
    });

    test('addWorktree fails with kErrGit for an unknown base ref', () async {
      final repos = await _initRepoWithOrigin();
      await _write(repos.repo, 'a.txt', 'v1\n');
      await _commitAll(repos.repo, 'init');
      await _git(repos.repo, ['push', '-u', 'origin', 'main']);

      await expectLater(
        service.addWorktree(
          repos.repo.path,
          path: p.join(repos.origin.parent.path, 'wt'),
          branch: 'speeddial/x-1a2b3c4d',
          baseRef: 'origin/nope',
        ),
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', kErrGit)),
      );
    });

    test('removeWorktree deletes the worktree and its registration',
        () async {
      final repos = await _initRepoWithOrigin();
      await _write(repos.repo, 'a.txt', 'v1\n');
      await _commitAll(repos.repo, 'init');
      await _git(repos.repo, ['push', '-u', 'origin', 'main']);

      final wtPath = p.join(repos.origin.parent.path, 'wt');
      await service.addWorktree(
        repos.repo.path,
        path: wtPath,
        branch: 'speeddial/x-1a2b3c4d',
        baseRef: 'origin/main',
      );
      expect(Directory(wtPath).existsSync(), isTrue);

      await service.removeWorktree(repos.repo.path, wtPath);
      expect(Directory(wtPath).existsSync(), isFalse);
      final list = (await _git(repos.repo, ['worktree', 'list', '--porcelain']))
          .stdout as String;
      expect(list, isNot(contains(wtPath)));
    });

    test('fetch/addWorktree reject dash-prefixed names before hitting git',
        () async {
      final repos = await _initRepoWithOrigin();
      await _write(repos.repo, 'a.txt', 'v1\n');
      await _commitAll(repos.repo, 'init');

      for (final call in <Future<void> Function()>[
        () => service.fetch(repos.repo.path, '-D'),
        () => service.addWorktree(repos.repo.path,
            path: 'wt', branch: '-D', baseRef: 'origin/main'),
        () => service.addWorktree(repos.repo.path,
            path: 'wt', branch: 'ok', baseRef: '--detach'),
        () => service.addWorktree(repos.repo.path,
            path: '--prune', branch: 'ok', baseRef: 'origin/main'),
      ]) {
        await expectLater(
          call(),
          throwsA(isA<DaemonError>()
              .having((e) => e.code, 'code', kErrGit)
              .having((e) => e.message, 'message', contains('invalid'))),
        );
      }
    });
  });

  group('worktreeBaseRef', () {
    Future<Directory> secondClone(Directory origin) async {
      final other = Directory(p.join(origin.parent.path, 'other'));
      await Process.run('git', ['clone', origin.path, other.path]);
      await _git(other, ['config', 'user.email', 'test@example.com']);
      await _git(other, ['config', 'user.name', 'Test User']);
      return other;
    }

    test('local wins when equal or ahead; remote wins when strictly ahead',
        () async {
      final repos = await _initRepoWithOrigin();
      final repo = repos.repo;
      await _write(repo, 'a.txt', 'v1\n');
      await _commitAll(repo, 'init');
      await _git(repo, ['push', '-u', 'origin', 'main']);

      // Equal tips: local (same commit either way).
      expect(await service.worktreeBaseRef(repo.path, 'main'), 'main');

      // Unpushed local commit: local ahead.
      await _write(repo, 'a.txt', 'v2\n');
      await _commitAll(repo, 'local work');
      expect(await service.worktreeBaseRef(repo.path, 'main'), 'main');

      // Push, then advance origin through a second clone: local is strictly
      // behind and can fast-forward — the remote tip wins.
      await _git(repo, ['push', 'origin', 'main']);
      final other = await secondClone(repos.origin);
      await _write(other, 'b.txt', 'remote work\n');
      await _commitAll(other, 'remote work');
      await _git(other, ['push', 'origin', 'main']);
      expect(await service.worktreeBaseRef(repo.path, 'main'), 'origin/main');
    });

    test('diverged branches resolve to local', () async {
      final repos = await _initRepoWithOrigin();
      final repo = repos.repo;
      await _write(repo, 'a.txt', 'v1\n');
      await _commitAll(repo, 'init');
      await _git(repo, ['push', '-u', 'origin', 'main']);

      // Local commit, unpushed…
      await _write(repo, 'a.txt', 'v2\n');
      await _commitAll(repo, 'local');

      // …plus an independent remote commit: ahead 1, behind 1.
      final other = await secondClone(repos.origin);
      await _write(other, 'b.txt', 'x\n');
      await _commitAll(other, 'remote');
      await _git(other, ['push', 'origin', 'main']);

      expect(await service.worktreeBaseRef(repo.path, 'main'), 'main');
    });

    test('local-only branch resolves to local; unknown branch throws',
        () async {
      final repos = await _initRepoWithOrigin();
      final repo = repos.repo;
      await _write(repo, 'a.txt', 'v1\n');
      await _commitAll(repo, 'init');
      await _git(repo, ['push', '-u', 'origin', 'main']);
      await service.createBranch(repo.path, 'feature', checkout: false);

      // `git fetch origin feature` fails (no such remote branch); the local
      // branch stands alone.
      expect(await service.worktreeBaseRef(repo.path, 'feature'), 'feature');

      await expectLater(
        service.worktreeBaseRef(repo.path, 'ghost'),
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', kErrGit)
            .having((e) => e.message, 'message', contains('ghost'))),
      );
    });
  });

  group('mergeIntoBase', () {
    const sessionBranch = 'speeddial/s-1a2b3c4d';

    /// Repo cloned from a local origin with one pushed commit, plus a
    /// session worktree on [sessionBranch] branched off origin/main.
    Future<({Directory repo, Directory origin, Directory worktree})>
        setup() async {
      final repos = await _initRepoWithOrigin();
      final repo = repos.repo;
      await _write(repo, 'a.txt', 'v1\n');
      await _commitAll(repo, 'init');
      await _git(repo, ['push', '-u', 'origin', 'main']);
      final wtPath = p.join(repos.origin.parent.path, 'wt');
      await service.addWorktree(
        repo.path,
        path: wtPath,
        branch: sessionBranch,
        baseRef: 'origin/main',
      );
      return (repo: repo, origin: repos.origin, worktree: Directory(wtPath));
    }

    Future<String> tip(Directory dir, String ref) async =>
        ((await _git(dir, ['rev-parse', ref])).stdout as String).trim();

    Future<void> commitIn(Directory dir, String file, String message) async {
      await _write(dir, file, '$message\n');
      await _git(dir, ['add', '-A']);
      await _git(dir, ['commit', '-m', message]);
    }

    /// Advances origin/main through a second clone; the local main in
    /// [repo] stays behind until something fetches/merges it.
    Future<Directory> advanceOrigin(Directory origin) async {
      final other = Directory(p.join(origin.parent.path, 'other'));
      await Process.run('git', ['clone', origin.path, other.path]);
      await _git(other, ['config', 'user.email', 'test@example.com']);
      await _git(other, ['config', 'user.name', 'Test User']);
      await commitIn(other, 'remote.txt', 'remote work');
      await _git(other, ['push', 'origin', 'main']);
      return other;
    }

    test('fast-forwards the checked-out base when the session is ahead',
        () async {
      final s = await setup();
      await commitIn(s.worktree, 'feat.txt', 'session work');
      final sessionTip = await tip(s.worktree, 'HEAD');

      final result = await service.mergeIntoBase(
        projectPath: s.repo.path,
        worktreePath: s.worktree.path,
        baseBranch: 'main',
      );

      expect(result.baseBranch, 'main');
      expect(result.sessionBranch, sessionBranch);
      expect(result.baseFastForwarded, isFalse);
      expect(result.alreadyUpToDate, isFalse);
      expect(result.fastForward, isTrue);
      expect(result.commit, sessionTip);
      expect(await tip(s.repo, 'main'), sessionTip,
          reason: 'main must move to the session tip');
      expect(await tip(s.repo, 'HEAD'), sessionTip,
          reason: 'the project checkout has main checked out');
      expect(File(p.join(s.repo.path, 'feat.txt')).existsSync(), isTrue);
    });

    test('fast-forwards the local base to origin first when origin is ahead',
        () async {
      // Origin advances before the session worktree is created, so the
      // whole merge can fast-forward once local main catches up.
      final repos = await _initRepoWithOrigin();
      final repo = repos.repo;
      await _write(repo, 'a.txt', 'v1\n');
      await _commitAll(repo, 'init');
      await _git(repo, ['push', '-u', 'origin', 'main']);
      final other = await advanceOrigin(repos.origin);
      final originTip = await tip(other, 'HEAD');
      expect(await tip(repo, 'main'), isNot(originTip),
          reason: 'local main must be behind origin');

      // The daemon always fetches before branching a worktree; here that
      // makes the stale remote-tracking ref visible for the branch point.
      await service.fetch(repo.path, 'main');
      final wtPath = p.join(repos.origin.parent.path, 'wt');
      await service.addWorktree(
        repo.path,
        path: wtPath,
        branch: sessionBranch,
        baseRef: 'origin/main',
      );
      final worktree = Directory(wtPath);
      await commitIn(worktree, 'feat.txt', 'session work');
      final sessionTip = await tip(worktree, 'HEAD');

      final result = await service.mergeIntoBase(
        projectPath: repo.path,
        worktreePath: worktree.path,
        baseBranch: 'main',
      );

      expect(result.baseFastForwarded, isTrue,
          reason: 'local main must first catch up to origin/main');
      expect(result.fastForward, isTrue);
      expect(result.alreadyUpToDate, isFalse);
      expect(result.commit, sessionTip);
      expect(await tip(repo, 'main'), sessionTip);
      expect(File(p.join(repo.path, 'remote.txt')).existsSync(), isTrue,
          reason: 'the remote work must land in the project checkout');
      expect(File(p.join(repo.path, 'feat.txt')).existsSync(), isTrue);
    });

    test('merges (no ff) when both base and session moved since the worktree '
        'was branched', () async {
      final s = await setup();
      // The session worktree branched off the old tip; then origin moved.
      await advanceOrigin(s.origin);
      await commitIn(s.worktree, 'feat.txt', 'session work');

      final result = await service.mergeIntoBase(
        projectPath: s.repo.path,
        worktreePath: s.worktree.path,
        baseBranch: 'main',
      );

      expect(result.baseFastForwarded, isTrue);
      expect(result.fastForward, isFalse,
          reason: 'session and base both have unique commits');
      expect(result.alreadyUpToDate, isFalse);
      expect(await tip(s.repo, 'main'), result.commit);
      // A real merge commit has two parents.
      final secondParent =
          await _git(s.repo, ['rev-parse', '--verify', '--quiet', 'main^2']);
      expect(secondParent.exitCode, 0);
      expect(File(p.join(s.repo.path, 'remote.txt')).existsSync(), isTrue);
      expect(File(p.join(s.repo.path, 'feat.txt')).existsSync(), isTrue);
    });

    test('creates a merge commit when the local base has unpushed commits',
        () async {
      final s = await setup();
      await commitIn(s.repo, 'local.txt', 'local work');
      await commitIn(s.worktree, 'feat.txt', 'session work');

      final result = await service.mergeIntoBase(
        projectPath: s.repo.path,
        worktreePath: s.worktree.path,
        baseBranch: 'main',
      );

      expect(result.baseFastForwarded, isFalse);
      expect(result.fastForward, isFalse);
      expect(await tip(s.repo, 'main'), result.commit);
      final secondParent =
          await _git(s.repo, ['rev-parse', '--verify', '--quiet', 'main^2']);
      expect(secondParent.exitCode, 0);
      expect(File(p.join(s.repo.path, 'local.txt')).existsSync(), isTrue);
      expect(File(p.join(s.repo.path, 'feat.txt')).existsSync(), isTrue);
    });

    test('reports alreadyUpToDate when the base contains the session branch',
        () async {
      final s = await setup();
      final baseTip = await tip(s.repo, 'main');

      final result = await service.mergeIntoBase(
        projectPath: s.repo.path,
        worktreePath: s.worktree.path,
        baseBranch: 'main',
      );

      expect(result.alreadyUpToDate, isTrue);
      expect(result.fastForward, isFalse);
      expect(result.baseFastForwarded, isFalse);
      expect(result.commit, baseTip);
      expect(await tip(s.repo, 'main'), baseTip);
    });

    test('rejects a dirty session worktree', () async {
      final s = await setup();
      await _write(s.worktree, 'dirty.txt', 'uncommitted\n');

      await expectLater(
        service.mergeIntoBase(
          projectPath: s.repo.path,
          worktreePath: s.worktree.path,
          baseBranch: 'main',
        ),
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', kErrConflict)
            .having((e) => e.message, 'message', contains('uncommitted'))),
      );
      expect(await tip(s.repo, 'main'), await tip(s.origin, 'HEAD'),
          reason: 'the base must not move when the merge is rejected');
    });

    test('rejects a local base diverged from origin', () async {
      final s = await setup();
      await commitIn(s.repo, 'local.txt', 'local work');
      await advanceOrigin(s.origin);

      await expectLater(
        service.mergeIntoBase(
          projectPath: s.repo.path,
          worktreePath: s.worktree.path,
          baseBranch: 'main',
        ),
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', kErrConflict)
            .having((e) => e.message, 'message', contains('diverged'))),
      );
    });

    test('moves the base ref directly when it is checked out nowhere',
        () async {
      final s = await setup();
      await commitIn(s.worktree, 'feat.txt', 'session work');
      final sessionTip = await tip(s.worktree, 'HEAD');
      await _git(s.repo, ['checkout', '-b', 'topic']);

      final result = await service.mergeIntoBase(
        projectPath: s.repo.path,
        worktreePath: s.worktree.path,
        baseBranch: 'main',
      );

      expect(result.fastForward, isTrue);
      expect(result.commit, sessionTip);
      expect(await tip(s.repo, 'main'), sessionTip);
      expect(
          ((await _git(s.repo, ['branch', '--show-current'])).stdout as String)
              .trim(),
          'topic',
          reason: 'the project checkout must stay on its branch');
    });

    test('rejects a non-fast-forward merge when the base is checked out '
        'nowhere', () async {
      final s = await setup();
      await commitIn(s.repo, 'local.txt', 'local work');
      await _git(s.repo, ['checkout', '-b', 'topic']);
      await commitIn(s.worktree, 'feat.txt', 'session work');

      await expectLater(
        service.mergeIntoBase(
          projectPath: s.repo.path,
          worktreePath: s.worktree.path,
          baseBranch: 'main',
        ),
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', kErrConflict)
            .having(
                (e) => e.message, 'message', contains('not checked out'))),
      );
      // The session's commits must not have landed on main.
      final merged = await Process.run('git',
          ['merge-base', '--is-ancestor', sessionBranch, 'main'],
          workingDirectory: s.repo.path);
      expect(merged.exitCode, 1);
    });

    test('rejects a detached session worktree', () async {
      final s = await setup();
      await _git(s.worktree, ['checkout', '--detach', 'HEAD']);

      await expectLater(
        service.mergeIntoBase(
          projectPath: s.repo.path,
          worktreePath: s.worktree.path,
          baseBranch: 'main',
        ),
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', kErrGit)
            .having((e) => e.message, 'message', contains('detached'))),
      );
    });
  });

  group('error handling', () {
    test('throws DaemonError kErrGit with exit code and args on failure',
        () async {
      final repo = await _initRepo();
      await _write(repo, 'a.txt', 'x\n');
      await _commitAll(repo, 'init');

      // checkout of a nonexistent branch fails
      await expectLater(
        service.checkout(repo.path, 'does-not-exist'),
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', kErrGit)
            .having((e) => e.message, 'message', isNotEmpty)
            .having((e) => (e.data as Map)['exitCode'], 'exitCode',
                isNonZero)),
      );
    });
  });
}
