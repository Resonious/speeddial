import 'dart:async';
import 'dart:convert';

import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../store/daemon_store.dart';
import 'git_service.dart';
import 'pr_service.dart';

/// Watches every project's session git summaries and reports the projects
/// whose summaries changed between passes, so clients refresh their
/// left-rail badges without polling.
///
/// Two cadences:
/// - every [pollInterval]: recompute summaries from local git state. This
///   catches commits an agent makes mid-turn (the `session.updated` path
///   only refreshes badges when a turn ends) and commits made from outside
///   this app entirely.
/// - every [fetchInterval], per project: `git fetch` the distinct base
///   branches first (best effort — an offline remote just leaves the
///   `origin` refs stale), so `behindBase` tracks the remote.
/// - every [pullRequestInterval], per project: one `gh pr list` (best effort
///   too — without a working `gh` sessions just show no pull request).
///
/// Passes are skipped while [hasClients] reports false: nothing consumes
/// the change events, so no git processes are spawned. Baselines persist
/// across such gaps, so the first pass after clients (re)connect reports
/// everything that moved meanwhile.
class SummaryWatcher {
  SummaryWatcher({
    required DaemonStore store,
    required GitService git,
    required PrService pr,
    required bool Function() hasClients,
    this.pollInterval = const Duration(seconds: 15),
    this.fetchInterval = const Duration(minutes: 2),
    this.pullRequestInterval = const Duration(minutes: 1),
    void Function(String projectId)? onChanged,
  }) : _store = store, // ignore: prefer_initializing_formals — public API name
       _git = git, // ignore: prefer_initializing_formals — public API name
       _pr = pr, // ignore: prefer_initializing_formals — public API name
       // ignore: prefer_initializing_formals — public API name
       _hasClients = hasClients,
       // ignore: prefer_initializing_formals — public API name
       _onChanged = onChanged;

  final DaemonStore _store;
  final GitService _git;
  final PrService _pr;
  final bool Function() _hasClients;

  /// How often summaries are recomputed from local state.
  final Duration pollInterval;

  /// Minimum time between `git fetch`es of a project's base branches.
  final Duration fetchInterval;

  /// Minimum time between `gh pr list`s of a project.
  final Duration pullRequestInterval;

  final void Function(String projectId)? _onChanged;

  Timer? _timer;
  bool _passRunning = false;
  bool _closed = false;

  /// Last summaries observed per project id, as encoded JSON for cheap
  /// comparison (the store returns sessions in a stable creation order).
  final Map<String, String> _lastSummaries = <String, String>{};

  /// When each project's base branches were last fetched.
  final Map<String, DateTime> _lastFetchAt = <String, DateTime>{};

  /// When each project's pull requests were last refreshed.
  final Map<String, DateTime> _lastPullRequestsAt = <String, DateTime>{};

  void start() {
    if (_closed) return;
    _timer ??= Timer.periodic(pollInterval, (_) => _pass());
  }

  /// Stops ticking. A pass already in flight may still touch its maps, but
  /// no further change events are emitted.
  void close() {
    _closed = true;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _pass() async {
    if (_passRunning || _closed || !_hasClients()) return;
    _passRunning = true;
    try {
      final List<Project> projects = _store.listProjects();
      await Future.wait(<Future<void>>[
        for (final Project project in projects) _passProject(project),
      ]);
    } finally {
      _passRunning = false;
    }
  }

  Future<void> _passProject(Project project) async {
    final List<Session> sessions = _store.listSessions(projectId: project.id);
    await Future.wait(<Future<void>>[
      _maybeFetch(project, sessions),
      _maybeRefreshPullRequests(project, sessions),
    ]);
    if (_closed) return;
    final List<SessionGitSummary> summaries = await _git.sessionSummaries(
      sessions,
      pullRequestFor: _pr.sessionPullRequests(
        project.id,
        _store.pullRequestClaims(project.id),
      ),
    );
    if (_closed) return;
    final String json = jsonEncode(summaries);
    final String? previous = _lastSummaries[project.id];
    _lastSummaries[project.id] = json;
    // A client may have read the summaries before the first pull request
    // refresh, so a first pass that found any must still be announced.
    final bool changed = previous == null
        ? summaries.any((SessionGitSummary s) => s.pullRequest != null)
        : previous != json;
    if (changed) _onChanged?.call(project.id);
  }

  /// Refreshes the project's pull requests when the last refresh is older
  /// than [pullRequestInterval]. Projects without sessions have nothing to
  /// badge, so they spend none of the user's GitHub API quota.
  Future<void> _maybeRefreshPullRequests(
    Project project,
    List<Session> sessions,
  ) async {
    if (sessions.isEmpty) return;
    final DateTime? last = _lastPullRequestsAt[project.id];
    final DateTime now = DateTime.now();
    if (last != null && now.difference(last) < pullRequestInterval) return;
    _lastPullRequestsAt[project.id] = now;
    await _pr.refreshPullRequests(project.id, project.path);
  }

  /// Makes the next pass refresh [projectId]'s pull requests, for when one is
  /// known to have just changed.
  void expirePullRequests(String projectId) {
    _lastPullRequestsAt.remove(projectId);
  }

  /// Fetches the project's distinct base branches when the last fetch is
  /// older than [fetchInterval]. Failures are swallowed: an offline remote
  /// must not fail the pass.
  Future<void> _maybeFetch(Project project, List<Session> sessions) async {
    final Set<String> branches = <String>{
      for (final Session session in sessions)
        if (session.baseBranch != null) session.baseBranch!,
    };
    if (branches.isEmpty) return;
    final DateTime? lastFetch = _lastFetchAt[project.id];
    final DateTime now = DateTime.now();
    if (lastFetch != null && now.difference(lastFetch) < fetchInterval) {
      return;
    }
    _lastFetchAt[project.id] = now;
    for (final String branch in branches) {
      try {
        await _git.fetch(project.path, branch);
      } on Object {
        // Offline / no remote / a raced ref lock: keep the stale origin ref.
      }
    }
  }
}
