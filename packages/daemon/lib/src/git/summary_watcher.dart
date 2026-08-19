import 'dart:async';

import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../store/daemon_store.dart';
import 'git_service.dart';

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
///
/// Passes are skipped while [hasClients] reports false: nothing consumes
/// the change events, so no git processes are spawned. Baselines persist
/// across such gaps, so the first pass after clients (re)connect reports
/// everything that moved meanwhile.
class SummaryWatcher {
  SummaryWatcher({
    required DaemonStore store,
    required GitService git,
    required bool Function() hasClients,
    this.pollInterval = const Duration(seconds: 15),
    this.fetchInterval = const Duration(minutes: 2),
    void Function(String projectId)? onChanged,
  })  : _store = store, // ignore: prefer_initializing_formals — public API name
        _git = git, // ignore: prefer_initializing_formals — public API name
        _hasClients = hasClients, // ignore: prefer_initializing_formals — public API name
        _onChanged = onChanged; // ignore: prefer_initializing_formals — public API name

  final DaemonStore _store;
  final GitService _git;
  final bool Function() _hasClients;

  /// How often summaries are recomputed from local state.
  final Duration pollInterval;

  /// Minimum time between `git fetch`es of a project's base branches.
  final Duration fetchInterval;

  final void Function(String projectId)? _onChanged;

  Timer? _timer;
  bool _passRunning = false;
  bool _closed = false;

  /// Last summaries observed per project id, as JSON for cheap comparison.
  final Map<String, List<Map<String, Object?>>> _lastSummaries =
      <String, List<Map<String, Object?>>>{};

  /// When each project's base branches were last fetched.
  final Map<String, DateTime> _lastFetchAt = <String, DateTime>{};

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
    await _maybeFetch(project, sessions);
    if (_closed) return;
    final List<SessionGitSummary> summaries =
        await _git.sessionSummaries(sessions);
    if (_closed) return;
    final List<Map<String, Object?>> json = summaries
        .map((SessionGitSummary s) => s.toJson())
        .toList(growable: false);
    final List<Map<String, Object?>>? previous = _lastSummaries[project.id];
    _lastSummaries[project.id] = json;
    if (previous != null && !_summariesEqual(previous, json)) {
      _onChanged?.call(project.id);
    }
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

  /// Same order, same fields (the store returns sessions in a stable
  /// creation order, so a list comparison is meaningful). Values are
  /// String/bool/int/null, so `==` compares them structurally.
  bool _summariesEqual(
    List<Map<String, Object?>> a,
    List<Map<String, Object?>> b,
  ) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      final Map<String, Object?> x = a[i];
      final Map<String, Object?> y = b[i];
      if (x.length != y.length) return false;
      for (final MapEntry<String, Object?> entry in x.entries) {
        if (entry.value != y[entry.key]) return false;
      }
    }
    return true;
  }
}
