import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:speeddial_protocol/speeddial_protocol.dart';

/// How many of a repository's newest pull requests one refresh reads. A pull
/// request older than this many others shows no badge.
const int _kPullRequestLimit = 100;

/// Check run conclusions and commit status states that count as a failure.
const Set<String> _kFailedCheckResults = <String>{
  'FAILURE',
  'ERROR',
  'TIMED_OUT',
  'CANCELLED',
  'ACTION_REQUIRED',
  'STARTUP_FAILURE',
};

/// Shells out to the GitHub CLI (`gh`) for pull request operations.
class PrService {
  PrService({this.ghPath = 'gh'});

  final String ghPath;

  /// Project id → head branch → pull request, as of the last successful
  /// [refreshPullRequests].
  final Map<String, Map<String, SessionPullRequest>> _pullRequests =
      <String, Map<String, SessionPullRequest>>{};

  /// Resolve only SpeedDial-managed worktree identities. Forked sessions keep
  /// the original cwd, so their own session IDs must not be used here.
  Future<List<Session>> findSessions(String url, List<Session> sessions) async {
    final GithubPrLink? link = GithubPrLink.parse(url);
    if (link == null) return const <Session>[];
    try {
      final Process process = await Process.start(
        ghPath,
        <String>['pr', 'view', link.url, '--json', 'headRefName'],
        environment: <String, String>{'GH_PROMPT_DISABLED': '1'},
      );
      final Future<String> output = process.stdout
          .transform(utf8.decoder)
          .join();
      final Future<void> errors = process.stderr.drain<void>();
      final int code;
      try {
        code = await process.exitCode.timeout(const Duration(seconds: 15));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
        rethrow;
      } finally {
        await errors;
      }
      final String text = await output;
      if (code != 0) throw StateError('gh pr view exited $code');
      final Object? json = jsonDecode(text);
      final Object? branch = json is Map ? json['headRefName'] : null;
      if (branch is! String) {
        throw const FormatException('Missing PR headRefName');
      }
      final RegExpMatch? match = RegExp(r'^speeddial/.+-([0-9a-f]{8})$')
          .firstMatch(branch);
      if (match == null) return const <Session>[];
      final String id = match.group(1)!;
      return sessions
          .where(
            (Session session) =>
                p.basename(p.dirname(session.cwd)) == '.speeddial-worktrees' &&
                p.basename(session.cwd).endsWith('-$id'),
          )
          .toList();
    } on Object catch (error) {
      stderr.writeln(
        'Warning: could not resolve GitHub PR ${link.url}: $error',
      );
      return const <Session>[];
    }
  }

  /// Refreshes the cached pull requests of the repository at [repoPath],
  /// stored under [projectId] for [pullRequestLookup].
  ///
  /// Fails silently: `gh` being missing or logged out, a repository not on
  /// GitHub, or a network failure all leave the cache as it was. Pull request
  /// badges are an extra, so none of these may reach the user.
  Future<void> refreshPullRequests(String projectId, String repoPath) async {
    try {
      final Process process = await Process.start(
        ghPath,
        <String>[
          'pr',
          'list',
          '--state',
          'all',
          '--limit',
          '$_kPullRequestLimit',
          '--json',
          'number,url,state,isDraft,headRefName,isCrossRepository,'
              'reviewDecision,statusCheckRollup',
        ],
        workingDirectory: repoPath,
        environment: <String, String>{'GH_PROMPT_DISABLED': '1'},
      );
      final Future<String> output = process.stdout
          .transform(utf8.decoder)
          .join();
      final Future<void> errors = process.stderr.drain<void>();
      final int code;
      try {
        code = await process.exitCode.timeout(const Duration(seconds: 15));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
        return;
      } finally {
        await errors;
      }
      final String text = await output;
      if (code != 0) return;
      final Object? json = jsonDecode(text);
      if (json is! List) return;
      _pullRequests[projectId] = _pullRequestsByBranch(json);
    } on ProcessException {
      return; // gh is not installed, or the project directory is gone.
    } on FileSystemException {
      return;
    } on FormatException {
      return;
    }
  }

  /// A branch → pull request lookup for [projectId] from the cache filled by
  /// [refreshPullRequests], or null when it holds none.
  SessionPullRequest? Function(String branch)? pullRequestLookup(
    String projectId,
  ) {
    final Map<String, SessionPullRequest>? byBranch = _pullRequests[projectId];
    if (byBranch == null || byBranch.isEmpty) return null;
    return (String branch) => byBranch[branch];
  }

  /// Keeps each branch's most relevant pull request from `gh pr list` output
  /// (newest first): its open one if any, otherwise its newest. Pull requests
  /// from forks are skipped, since their branch names mean nothing here.
  static Map<String, SessionPullRequest> _pullRequestsByBranch(
    List<Object?> json,
  ) {
    final Map<String, SessionPullRequest> byBranch =
        <String, SessionPullRequest>{};
    for (final Object? entry in json) {
      if (entry is! Map || entry['isCrossRepository'] == true) continue;
      final Object? branch = entry['headRefName'];
      final Object? number = entry['number'];
      final Object? url = entry['url'];
      final PullRequestState? state = _pullRequestState(entry);
      if (branch is! String || number is! int || url is! String) continue;
      if (state == null) continue;
      final SessionPullRequest? existing = byBranch[branch];
      final bool existingLive =
          existing != null &&
          (existing.state == PullRequestState.open ||
              existing.state == PullRequestState.draft);
      final bool live =
          state == PullRequestState.open || state == PullRequestState.draft;
      if (existing != null && (existingLive || !live)) continue;
      byBranch[branch] = SessionPullRequest(
        number: number,
        url: url,
        state: state,
        checks: _pullRequestChecks(entry['statusCheckRollup']),
        review: switch (entry['reviewDecision']) {
          'APPROVED' => PullRequestReview.approved,
          'CHANGES_REQUESTED' => PullRequestReview.changesRequested,
          'REVIEW_REQUIRED' => PullRequestReview.reviewRequired,
          _ => null,
        },
      );
    }
    return byBranch;
  }

  static PullRequestState? _pullRequestState(Map<Object?, Object?> entry) =>
      switch (entry['state']) {
        'OPEN' when entry['isDraft'] == true => PullRequestState.draft,
        'OPEN' => PullRequestState.open,
        'MERGED' => PullRequestState.merged,
        'CLOSED' => PullRequestState.closed,
        _ => null,
      };

  /// Rolls `statusCheckRollup` up to one verdict: any failure wins, then
  /// anything unfinished. The rollup mixes check runs (`status`/`conclusion`)
  /// with commit statuses (`state`). Null when the head has no checks.
  static PullRequestChecks? _pullRequestChecks(Object? rollup) {
    if (rollup is! List || rollup.isEmpty) return null;
    bool pending = false;
    for (final Object? check in rollup) {
      if (check is! Map) continue;
      final Object? result = check['conclusion'] ?? check['state'];
      if (_kFailedCheckResults.contains(result)) {
        return PullRequestChecks.failing;
      }
      final bool unfinishedRun =
          check.containsKey('status') && check['status'] != 'COMPLETED';
      if (unfinishedRun || result == 'PENDING' || result == 'EXPECTED') {
        pending = true;
      }
    }
    return pending ? PullRequestChecks.pending : PullRequestChecks.passing;
  }

  /// Whether `gh` is present and authenticated (`gh auth status` exit 0).
  Future<bool> isAvailable() async {
    try {
      final result = await Process.run(ghPath, [
        'auth',
        'status',
      ], runInShell: false);
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    } on FileSystemException {
      return false;
    }
  }

  /// Creates a pull request for the current branch and returns its URL.
  ///
  /// Title/body derive from the latest commit via `--fill` when both are
  /// absent — passing `--base` or `--draft` must never drop the fill, since
  /// `gh` would otherwise prompt interactively and hang a non-tty daemon.
  Future<String> createPullRequest(
    String repoPath, {
    String? title,
    String? body,
    String? base,
    bool draft = false,
  }) async {
    final args = <String>['pr', 'create'];
    if (title == null && body == null) {
      args.add('--fill');
    } else {
      if (title != null) {
        args
          ..add('--title')
          ..add(title);
      }
      if (body != null) {
        args
          ..add('--body')
          ..add(body);
      }
    }
    if (base != null) {
      args
        ..add('--base')
        ..add(base);
    }
    if (draft) {
      args.add('--draft');
    }

    ProcessResult result;
    try {
      result = await Process.run(ghPath, args, workingDirectory: repoPath);
    } on ProcessException catch (e) {
      throw DaemonError(kErrGit, e.message, {
        'exitCode': e.errorCode,
        'args': args,
      });
    }
    if (result.exitCode != 0) {
      throw DaemonError(kErrGit, (result.stderr as String).trim(), {
        'exitCode': result.exitCode,
        'args': args,
      });
    }

    final out = result.stdout as String;
    final lines = out
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    return lines.isEmpty ? '' : lines.last;
  }
}
