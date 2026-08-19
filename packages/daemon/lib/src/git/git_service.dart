import 'dart:io';

import 'package:speeddial_protocol/speeddial_protocol.dart';

/// Shells out to `git` to inspect and mutate a repository.
///
/// All operations take an absolute repository path and pass arguments as a
/// [List] (never shell-interpolated) so untrusted user input cannot be
/// injected into the command line.
class GitService {
  GitService({this.gitPath = 'git'});

  final String gitPath;

  /// Parsed working-tree / index status via `--porcelain=v2`.
  Future<GitStatus> status(String repoPath) async {
    final result = await _run(
      repoPath,
      ['status', '--porcelain=v2', '--branch'],
    );
    return _parseStatus(result.stdout as String);
  }

  /// A compact per-session summary for the left-rail badges (see
  /// `git.sessionSummaries` in PROTOCOL.md).
  ///
  /// [repoPath] is the session's cwd (its worktree, or the project checkout
  /// for sessions without one). [baseBranch] and [createdAt] come from the
  /// session record; [createdAt] is required to tell a merged branch apart
  /// from one that never gained a commit of its own (both read "ahead 0").
  ///
  /// Every field fails soft: a missing/invalid directory or an unborn HEAD
  /// yields nulls, never an exception, so one broken worktree cannot sink
  /// the whole batch.
  Future<SessionGitSummary> sessionSummary({
    required String sessionId,
    required String repoPath,
    String? baseBranch,
    DateTime? createdAt,
  }) async {
    bool? dirty;
    try {
      dirty = await _hasUncommittedChanges(repoPath);
    } on DaemonError {
      dirty = null;
    } on ProcessException {
      // The directory itself is gone (deleted worktree).
      dirty = null;
    }

    int? aheadOfBase;
    int? behindBase;
    bool? mergedIntoBase;
    if (baseBranch != null) {
      try {
        _validateBranchName(baseBranch);
        // Worktrees share the project's refs, so the base branch and its
        // remote-tracking ref are visible from the session's cwd. A commit
        // that landed in either one counts as merged; no fetch is run here,
        // so the origin ref may be stale.
        final List<String> exclusions = <String>['refs/heads/$baseBranch'];
        final List<String> baseRefs = <String>['refs/heads/$baseBranch'];
        if (await _refExists(repoPath, 'refs/remotes/origin/$baseBranch')) {
          exclusions.add('refs/remotes/origin/$baseBranch');
          baseRefs.add('refs/remotes/origin/$baseBranch');
        }
        aheadOfBase = await _countAhead(repoPath, exclusions);
        behindBase = await _countBehind(repoPath, baseRefs);
        if (aheadOfBase == 0) {
          // HEAD is an ancestor of a base ref. That is trivially true for a
          // branch that never moved off its creation point (fresh worktree),
          // so only report "merged" once the branch gained a commit of its
          // own, approximated by the tip's committer time postdating the
          // session creation.
          mergedIntoBase =
              createdAt != null && await _tipCommittedAfter(repoPath, createdAt);
        } else {
          mergedIntoBase = false;
        }
      } on DaemonError {
        aheadOfBase = null;
        behindBase = null;
        mergedIntoBase = null;
      } on ProcessException {
        aheadOfBase = null;
        behindBase = null;
        mergedIntoBase = null;
      }
    }

    return SessionGitSummary(
      sessionId: sessionId,
      dirty: dirty,
      aheadOfBase: aheadOfBase,
      behindBase: behindBase,
      mergedIntoBase: mergedIntoBase,
    );
  }

  /// One summary per session (see [sessionSummary]), computed concurrently.
  /// Shared by the `git.sessionSummaries` handler and the summary watcher.
  Future<List<SessionGitSummary>> sessionSummaries(
      Iterable<Session> sessions) {
    return Future.wait(<Future<SessionGitSummary>>[
      for (final Session session in sessions)
        sessionSummary(
          sessionId: session.id,
          repoPath: session.cwd,
          baseBranch: session.baseBranch,
          createdAt: session.createdAt,
        ),
    ]);
  }


  /// Unified diffs, one [GitDiff] per touched file.
  Future<List<GitDiff>> diff(String repoPath,
      {String? path, bool staged = false}) async {
    final args = <String>['diff'];
    if (staged) args.add('--cached');
    args.add('--no-color');
    if (path != null) {
      args..add('--')..add(path);
    }
    final result = await _run(repoPath, args);
    return _parseDiff(result.stdout as String);
  }

  /// Local branches with upstream info.
  Future<List<Branch>> branches(String repoPath) async {
    final result = await _run(repoPath, [
      'branch',
      '--format=%(refname:short)\t%(HEAD)\t%(upstream:short)',
    ]);
    final out = result.stdout as String;
    final branches = <Branch>[];
    if (out.trim().isEmpty) return branches;
    for (final line in out.split('\n')) {
      if (line.trim().isEmpty) continue;
      final parts = line.split('\t');
      final name = parts[0];
      if (name.isEmpty) continue;
      branches.add(Branch(
        name: name,
        isCurrent: parts.length > 1 && parts[1] == '*',
        upstream:
            parts.length > 2 && parts[2].isNotEmpty ? parts[2] : null,
      ));
    }
    return branches;
  }

  Future<void> checkout(String repoPath, String branch) async {
    _validateBranchName(branch);
    await _run(repoPath, ['checkout', branch]);
  }

  Future<void> createBranch(String repoPath, String name,
      {bool checkout = true}) async {
    _validateBranchName(name);
    if (checkout) {
      await _run(repoPath, ['checkout', '-b', name]);
    } else {
      await _run(repoPath, ['branch', name]);
    }
  }

  /// Rejects branch names that start with `-`: git would parse them as flags
  /// (e.g. `--delete` after `checkout`), letting a crafted name mutate the
  /// repository instead of naming a branch.
  void _validateBranchName(String name) {
    if (name.startsWith('-')) {
      throw DaemonError(
        kErrGit,
        'invalid branch name: $name',
        <String, Object?>{'branchName': name},
      );
    }
  }

  /// Commits staged changes (or all when [stageAll]) and returns the full
  /// commit hash.
  Future<String> commit(String repoPath, String message,
      {bool stageAll = false}) async {
    if (stageAll) {
      await _run(repoPath, ['add', '-A']);
    }
    await _run(repoPath, ['commit', '-m', message]);
    final result = await _run(repoPath, ['rev-parse', 'HEAD']);
    return (result.stdout as String).trim();
  }

  Future<void> push(String repoPath, {bool setUpstream = false}) async {
    if (setUpstream) {
      await _run(repoPath, ['push', '-u', 'origin', 'HEAD']);
    } else {
      await _run(repoPath, ['push']);
    }
  }

  /// Fetches [branch] from [remote], refreshing the remote-tracking ref
  /// (`origin/<branch>`) so worktrees branch off the latest remote tip.
  Future<void> fetch(String repoPath, String branch,
      {String remote = 'origin'}) async {
    _validateBranchName(branch);
    _validateBranchName(remote);
    await _run(repoPath, ['fetch', remote, branch]);
  }

  /// Resolves the base ref for a new session worktree on [branch]:
  /// `origin/<branch>` when the (freshly fetched) remote-tracking ref is
  /// strictly ahead of the local branch, otherwise the local branch —
  /// i.e. local wins when ahead, when equal, and on divergence. A branch
  /// that exists only locally or only on the remote resolves to the side
  /// that exists; one that exists on neither throws [DaemonError] `kErrGit`.
  Future<String> worktreeBaseRef(String repoPath, String branch) async {
    _validateBranchName(branch);
    var hasRemote = false;
    try {
      await fetch(repoPath, branch);
      hasRemote = true;
    } on DaemonError catch (e) {
      // A missing remote branch is fine: the local branch stands alone.
      // Anything else (network, auth) still fails the create.
      if (!e.message.toLowerCase().contains("couldn't find remote ref")) {
        rethrow;
      }
    }
    final bool hasLocal =
        await _refExists(repoPath, 'refs/heads/$branch');
    if (!hasLocal && !hasRemote) {
      throw DaemonError(kErrGit, 'No local or origin branch named: $branch');
    }
    if (!hasLocal) return 'origin/$branch';
    if (!hasRemote) return branch;

    final counts = await _aheadBehind(repoPath, branch, 'origin/$branch');
    // Remote wins only when the local branch can fast-forward to it.
    return counts.behind > 0 && counts.ahead == 0 ? 'origin/$branch' : branch;
  }

  /// Whether [ref] (fully qualified, e.g. `refs/heads/main`) resolves.
  Future<bool> _refExists(String repoPath, String ref) async {
    final result = await Process.run(
      gitPath,
      ['rev-parse', '--verify', '--quiet', ref],
      workingDirectory: repoPath,
    );
    return result.exitCode == 0;
  }

  /// Creates a worktree at [path] on a new branch [branch] based on
  /// [baseRef] (e.g. `origin/main`). Fails with [DaemonError] `kErrGit` when
  /// the base ref is unknown or the path is occupied.
  Future<void> addWorktree(
    String repoPath, {
    required String path,
    required String branch,
    required String baseRef,
  }) async {
    _validateBranchName(branch);
    _validateBranchName(baseRef);
    if (path.startsWith('-')) {
      throw DaemonError(kErrGit, 'invalid worktree path: $path');
    }
    await _run(repoPath, ['worktree', 'add', path, '-b', branch, baseRef]);
  }

  /// Removes the worktree at [path], discarding any uncommitted changes in
  /// it (`--force`): only used to roll back a worktree whose session never
  /// started, never for user-facing deletion.
  Future<void> removeWorktree(String repoPath, String path) async {
    if (path.startsWith('-')) {
      throw DaemonError(kErrGit, 'invalid worktree path: $path');
    }
    await _run(repoPath, ['worktree', 'remove', '--force', path]);
  }

  /// Merges the session worktree branch at [worktreePath] back into the
  /// local [baseBranch] of the repository at [projectPath].
  ///
  /// The local base is first synchronized with `origin/<baseBranch>`: when
  /// the (freshly fetched) remote-tracking ref is strictly ahead, the local
  /// base fast-forwards to it — via `merge --ff-only` in the checkout that
  /// has the base branch, or by moving the ref when the base is checked out
  /// nowhere. Diverged local/remote bases throw [DaemonError] `kErrConflict`.
  ///
  /// The merge itself runs in the checkout holding the base branch (a real
  /// merge: fast-forward or merge commit); with no such checkout only a
  /// fast-forward ref move is possible, anything else is `kErrConflict`.
  /// The session worktree must be clean (`kErrConflict`) — merging never
  /// carries uncommitted changes. Merge conflicts propagate as `kErrGit`
  /// after `git merge --abort` restores the base checkout to its pre-merge
  /// state. Neither the worktree nor its branch is removed afterwards.
  Future<MergeResult> mergeIntoBase({
    required String projectPath,
    required String worktreePath,
    required String baseBranch,
  }) async {
    _validateBranchName(baseBranch);
    final sessionBranch = await _currentBranch(worktreePath);
    if (sessionBranch == null) {
      throw DaemonError(
          kErrGit, 'session worktree is on a detached HEAD: $worktreePath');
    }
    if (sessionBranch == baseBranch) {
      throw DaemonError(
          kErrGit, 'session is on the base branch itself: $baseBranch');
    }
    if (await _hasUncommittedChanges(worktreePath)) {
      throw DaemonError(
        kErrConflict,
        'session worktree has uncommitted changes; commit or discard '
            'them first',
      );
    }

    // Sync the local base with origin when the remote moved ahead.
    final baseFastForwarded =
        await _syncBaseWithOrigin(projectPath, baseBranch);

    final baseTip = await _revParse(projectPath, 'refs/heads/$baseBranch');
    if (await _isAncestor(projectPath, sessionBranch, baseBranch)) {
      return MergeResult(
        baseBranch: baseBranch,
        sessionBranch: sessionBranch,
        baseFastForwarded: baseFastForwarded,
        alreadyUpToDate: true,
        fastForward: false,
        commit: baseTip,
      );
    }
    final canFastForward =
        await _isAncestor(projectPath, baseBranch, sessionBranch);
    final checkout = await _worktreeForBranch(projectPath, baseBranch);
    if (checkout != null) {
      // A real merge in the base checkout: fast-forwards when possible,
      // otherwise creates a merge commit with git's default message.
      // --no-edit keeps the merge non-interactive either way. A conflicted
      // merge is aborted, restoring the checkout to its pre-merge state.
      try {
        await _run(checkout, ['merge', '--no-edit', sessionBranch]);
      } on DaemonError catch (error) {
        // Nothing to abort when git never entered MERGING state (e.g. an
        // untracked file would be overwritten): the checkout is untouched
        // and the original error stands.
        if (!await _isMerging(checkout)) rethrow;
        try {
          await _run(checkout, ['merge', '--abort']);
        } on DaemonError catch (abortError) {
          throw DaemonError(
            kErrGit,
            'merging $sessionBranch into $baseBranch conflicted; '
                '`git merge --abort` failed too (${abortError.message}), '
                'leaving $checkout in MERGING state. '
                'Original error: ${error.message}',
          );
        }
        throw DaemonError(
          kErrGit,
          'merging $sessionBranch into $baseBranch conflicted; the merge '
              'was aborted and $baseBranch is unchanged: ${error.message}',
          error.data,
        );
      }
    } else {
      if (!canFastForward) {
        throw DaemonError(
          kErrConflict,
          '$baseBranch is not checked out anywhere and the merge is not a '
              'fast-forward; check out $baseBranch and retry',
        );
      }
      // Safe away from any checkout: git branch -f refuses to move a branch
      // that is checked out, which is exactly the case handled above.
      await _run(projectPath, ['branch', '-f', baseBranch, sessionBranch]);
    }
    return MergeResult(
      baseBranch: baseBranch,
      sessionBranch: sessionBranch,
      baseFastForwarded: baseFastForwarded,
      alreadyUpToDate: false,
      fastForward: canFastForward,
      commit: await _revParse(projectPath, 'refs/heads/$baseBranch'),
    );
  }

  /// Rebases the session worktree branch at [worktreePath] onto the local
  /// [baseBranch] of the repository at [projectPath].
  ///
  /// The local base is first synchronized with `origin/<baseBranch>` exactly
  /// like [mergeIntoBase]. When the session branch already contains the base
  /// tip the rebase is a no-op (`alreadyUpToDate`). Otherwise
  /// `git rebase <baseBranch>` runs in the session worktree: the session's
  /// commits are replayed onto the base tip (a pure fast-forward when the
  /// session branched off the base tip and never moved). Unlike a merge this
  /// needs no checkout of the base branch, so diverged histories rebase fine
  /// regardless of where the base is checked out.
  ///
  /// The session worktree must be clean ([DaemonError] `kErrConflict`).
  /// Rebase conflicts propagate as `kErrGit` after `git rebase --abort`
  /// restores the session branch to its pre-rebase tip. The base branch and
  /// the project checkout are never touched by the rebase itself.
  Future<RebaseResult> rebaseOntoBase({
    required String projectPath,
    required String worktreePath,
    required String baseBranch,
  }) async {
    _validateBranchName(baseBranch);
    final sessionBranch = await _currentBranch(worktreePath);
    if (sessionBranch == null) {
      throw DaemonError(
          kErrGit, 'session worktree is on a detached HEAD: $worktreePath');
    }
    if (sessionBranch == baseBranch) {
      throw DaemonError(
          kErrGit, 'session is on the base branch itself: $baseBranch');
    }
    if (await _hasUncommittedChanges(worktreePath)) {
      throw DaemonError(
        kErrConflict,
        'session worktree has uncommitted changes; commit or discard '
            'them first',
      );
    }

    // Sync the local base with origin when the remote moved ahead.
    final baseFastForwarded =
        await _syncBaseWithOrigin(projectPath, baseBranch);

    if (await _isAncestor(projectPath, baseBranch, sessionBranch)) {
      return RebaseResult(
        baseBranch: baseBranch,
        sessionBranch: sessionBranch,
        baseFastForwarded: baseFastForwarded,
        alreadyUpToDate: true,
        commit: await _revParse(worktreePath, 'HEAD'),
      );
    }
    // A conflicted rebase is aborted, restoring the session branch to its
    // pre-rebase tip and the worktree to a clean state.
    try {
      await _run(worktreePath, ['rebase', baseBranch]);
    } on DaemonError catch (error) {
      // Nothing to abort when git never started the rebase (e.g. an
      // untracked file would be overwritten): the worktree is untouched and
      // the original error stands.
      if (!await _isRebasing(worktreePath)) rethrow;
      try {
        await _run(worktreePath, ['rebase', '--abort']);
      } on DaemonError catch (abortError) {
        throw DaemonError(
          kErrGit,
          'rebasing $sessionBranch onto $baseBranch conflicted; '
              '`git rebase --abort` failed too (${abortError.message}), '
              'leaving $worktreePath mid-rebase. '
              'Original error: ${error.message}',
        );
      }
      throw DaemonError(
        kErrGit,
        'rebasing $sessionBranch onto $baseBranch conflicted; the rebase '
            'was aborted and $sessionBranch is unchanged: ${error.message}',
        error.data,
      );
    }
    return RebaseResult(
      baseBranch: baseBranch,
      sessionBranch: sessionBranch,
      baseFastForwarded: baseFastForwarded,
      alreadyUpToDate: false,
      commit: await _revParse(worktreePath, 'HEAD'),
    );
  }

  /// Synchronizes the local [baseBranch] with `origin/<baseBranch>`: fetches
  /// and, when the remote-tracking ref is strictly ahead, fast-forwards the
  /// local base to it, returning whether that happened. A base branch that
  /// exists only locally stands alone; diverged local/remote bases throw
  /// [DaemonError] `kErrConflict`.
  Future<bool> _syncBaseWithOrigin(
      String projectPath, String baseBranch) async {
    var hasRemote = false;
    try {
      await fetch(projectPath, baseBranch);
      hasRemote = true;
    } on DaemonError catch (e) {
      // A missing remote branch is fine: the local base stands alone.
      // Anything else (network, auth) still fails the operation.
      if (!e.message.toLowerCase().contains("couldn't find remote ref")) {
        rethrow;
      }
    }
    if (!hasRemote) return false;
    final counts =
        await _aheadBehind(projectPath, baseBranch, 'origin/$baseBranch');
    if (counts.behind > 0 && counts.ahead > 0) {
      throw DaemonError(
        kErrConflict,
        'local $baseBranch and origin/$baseBranch have diverged; '
            'reconcile them first',
      );
    }
    if (counts.behind > 0) {
      await _fastForwardRef(projectPath, baseBranch, 'origin/$baseBranch');
      return true;
    }
    return false;
  }

  /// The short name of the branch checked out at [repoPath], or null on a
  /// detached HEAD.
  Future<String?> _currentBranch(String repoPath) async {
    final result = await Process.run(
      gitPath,
      ['symbolic-ref', '--short', '--quiet', 'HEAD'],
      workingDirectory: repoPath,
    );
    if (result.exitCode != 0) return null;
    return (result.stdout as String).trim();
  }

  /// Whether [repoPath] has staged or unstaged changes (incl. untracked).
  Future<bool> _hasUncommittedChanges(String repoPath) async {
    final result = await _run(repoPath, ['status', '--porcelain']);
    return (result.stdout as String).trim().isNotEmpty;
  }

  /// Commits [left] leads/trails [right] by (`left...right`).
  Future<({int ahead, int behind})> _aheadBehind(
      String repoPath, String left, String right) async {
    final result = await _run(
        repoPath, ['rev-list', '--left-right', '--count', '$left...$right']);
    final List<String> parts =
        (result.stdout as String).trim().split(RegExp(r'\s+'));
    return (ahead: int.parse(parts[0]), behind: int.parse(parts[1]));
  }

  /// Commits reachable from HEAD but not from any of [excludeRefs]
  /// (`git rev-list --count HEAD ^a ^b …`).
  Future<int> _countAhead(String repoPath, List<String> excludeRefs) async {
    final result = await _run(repoPath, <String>[
      'rev-list',
      '--count',
      'HEAD',
      for (final String ref in excludeRefs) '^$ref',
    ]);
    return int.parse((result.stdout as String).trim());
  }

  /// Commits reachable from any of [baseRefs] but not from HEAD
  /// (`git rev-list --count a b … ^HEAD`).
  Future<int> _countBehind(String repoPath, List<String> baseRefs) async {
    final result = await _run(repoPath, <String>[
      'rev-list',
      '--count',
      ...baseRefs,
      '^HEAD',
    ]);
    return int.parse((result.stdout as String).trim());
  }

  /// Whether HEAD's tip commit has a committer time later than [since].
  /// Used to tell a branch that gained (and then merged) its own commits
  /// apart from one still pointing at its creation-time commit.
  Future<bool> _tipCommittedAfter(String repoPath, DateTime since) async {
    final result = await _run(repoPath, ['log', '-1', '--format=%ct', 'HEAD']);
    final int? seconds = int.tryParse((result.stdout as String).trim());
    if (seconds == null) return false;
    return seconds * 1000 > since.millisecondsSinceEpoch;
  }

  /// Whether [ancestor] is an ancestor of (or equal to) [descendant].
  Future<bool> _isAncestor(
      String repoPath, String ancestor, String descendant) async {
    final result = await Process.run(
      gitPath,
      ['merge-base', '--is-ancestor', ancestor, descendant],
      workingDirectory: repoPath,
    );
    if (result.exitCode == 0) return true;
    if (result.exitCode == 1) return false;
    throw DaemonError(
      kErrGit,
      (result.stderr as String).trim(),
      {'exitCode': result.exitCode},
    );
  }

  /// Whether [repoPath] is mid-merge (MERGE_HEAD exists).
  Future<bool> _isMerging(String repoPath) async {
    final result = await Process.run(
      gitPath,
      ['rev-parse', '--verify', '--quiet', 'MERGE_HEAD'],
      workingDirectory: repoPath,
    );
    return result.exitCode == 0;
  }

  /// Whether [repoPath] is mid-rebase (REBASE_HEAD exists).
  Future<bool> _isRebasing(String repoPath) async {
    final result = await Process.run(
      gitPath,
      ['rev-parse', '--verify', '--quiet', 'REBASE_HEAD'],
      workingDirectory: repoPath,
    );
    return result.exitCode == 0;
  }

  Future<String> _revParse(String repoPath, String ref) async {
    final result = await _run(repoPath, ['rev-parse', ref]);
    return (result.stdout as String).trim();
  }

  /// Path of the worktree that has [branch] checked out, or null.
  Future<String?> _worktreeForBranch(String repoPath, String branch) async {
    final result = await _run(repoPath, ['worktree', 'list', '--porcelain']);
    String? worktreePath;
    for (final line in (result.stdout as String).split('\n')) {
      if (line.startsWith('worktree ')) {
        worktreePath = line.substring('worktree '.length);
      } else if (line.isEmpty) {
        worktreePath = null;
      } else if (line == 'branch refs/heads/$branch' && worktreePath != null) {
        return worktreePath;
      }
    }
    return null;
  }

  /// Advances [branch] to [target], which must be a descendant: via
  /// `merge --ff-only` where [branch] is checked out (protecting that
  /// worktree's uncommitted changes), or a direct ref move otherwise.
  Future<void> _fastForwardRef(
      String repoPath, String branch, String target) async {
    final checkout = await _worktreeForBranch(repoPath, branch);
    if (checkout != null) {
      await _run(checkout, ['merge', '--ff-only', target]);
    } else {
      await _run(repoPath, ['branch', '-f', branch, target]);
    }
  }

  Future<ProcessResult> _run(String repoPath, List<String> args) async {
    final result = await Process.run(gitPath, args, workingDirectory: repoPath);
    if (result.exitCode != 0) {
      // git reports some failures (e.g. merge conflicts) on stdout only.
      final stderr = (result.stderr as String).trim();
      throw DaemonError(
        kErrGit,
        stderr.isNotEmpty ? stderr : (result.stdout as String).trim(),
        {'exitCode': result.exitCode, 'args': args},
      );
    }
    return result;
  }

  /// Parses `git status --porcelain=v2 --branch` output.
  GitStatus _parseStatus(String out) {
    var branch = '';
    var ahead = 0;
    var behind = 0;
    final files = <GitStatusFile>[];

    final abPattern =
        RegExp(r'^#\s*branch\.ab\s+\+(-\d+|\?)\s+-(-\d+|\?)\s*$');
    for (final line in out.split('\n')) {
      if (line.isEmpty) continue;
      if (line.startsWith('# branch.head ')) {
        branch = line.substring('# branch.head '.length).trim();
      } else if (line.startsWith('# branch.ab ')) {
        final m = abPattern.firstMatch(line);
        if (m != null) {
          ahead = int.tryParse(m.group(1)!) ?? 0;
          behind = int.tryParse(m.group(2)!) ?? 0;
        }
      } else if (line.startsWith('#')) {
        // Other header lines (`# branch.oid`, `# branch.upstream`, …) carry
        // no file information and must not yield a phantom file entry.
        continue;
      } else if (line.startsWith('?')) {
        // Untracked: `? <path>` (path is the remainder, may contain spaces).
        final path = line.length > 2 ? line.substring(2) : '';
        files.add(GitStatusFile(
          path: path,
          indexStatus: '?',
          worktreeStatus: '?',
          staged: false,
        ));
      } else {
        final parts = line.split(' ');
        if (parts.length < 2) continue;
        final kind = parts[0];
        final xy = parts[1];
        final indexStatus = xy.isNotEmpty ? xy[0] : '.';
        final worktreeStatus = xy.length > 1 ? xy[1] : '.';

        String path;
        if (kind == '2') {
          // Rename/copy: `<score> <path><sep><origPath>` — path is everything
          // after the score column, cut at the separator.
          path = parts.length > 9
              ? _renamePath(parts.sublist(9).join(' '))
              : '';
        } else {
          // kind == '1' (or unknown): path is everything after 8 columns.
          path = parts.length > 8 ? parts.sublist(8).join(' ') : '';
        }

        files.add(GitStatusFile(
          path: path,
          indexStatus: indexStatus,
          worktreeStatus: worktreeStatus,
          staged: indexStatus != '.' && indexStatus != ' ',
        ));
      }
    }

    return GitStatus(
        branch: branch, ahead: ahead, behind: behind, files: files);
  }

  String _renamePath(String joined) {
    // The separator between the new and original path is a tab when the path
    // contains spaces, otherwise a single space. Cut at the tab, or strip the
    // trailing original path when space-separated.
    final tab = joined.indexOf('\t');
    if (tab >= 0) return joined.substring(0, tab);
    final space = joined.lastIndexOf(' ');
    if (space >= 0) return joined.substring(0, space);
    return joined;
  }

  /// Splits a multi-file unified diff into per-file [GitDiff]s.
  List<GitDiff> _parseDiff(String out) {
    if (out.trim().isEmpty) return [];

    final sections = <List<String>>[];
    List<String>? current;
    for (final line in out.split('\n')) {
      if (line.startsWith('diff --git ')) {
        current = [];
        sections.add(current);
        current.add(line);
      } else if (current != null) {
        current.add(line);
      }
    }

    final diffs = <GitDiff>[];
    for (final section in sections) {
      final header = section[0];
      diffs.add(_parseDiffSection(header, section));
    }
    return diffs;
  }

  GitDiff _parseDiffSection(String header, List<String> section) {
    // `diff --git a/<old> b/<new>` — use the `b/` side for the path.
    final rest = header.substring('diff --git '.length);
    final bIdx = rest.indexOf(' b/');
    final path = bIdx >= 0 ? rest.substring(bIdx + 3) : rest;

    final joined = section.join('\n');
    final isNew = section.any((l) => l.startsWith('new file mode '));
    final isDeleted = section.any((l) => l.startsWith('deleted file mode '));
    final isBinary = joined.contains('Binary files ') ||
        joined.contains('GIT binary patch');

    return GitDiff(
      path: path,
      patch: isBinary ? '' : joined,
      isNew: isNew,
      isDeleted: isDeleted,
      isBinary: isBinary,
    );
  }
}
