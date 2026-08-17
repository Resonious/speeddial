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

  Future<ProcessResult> _run(String repoPath, List<String> args) async {
    final result = await Process.run(gitPath, args, workingDirectory: repoPath);
    if (result.exitCode != 0) {
      throw DaemonError(
        kErrGit,
        (result.stderr as String).trim(),
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
