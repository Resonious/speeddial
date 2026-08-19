import 'dart:async';

import 'store_base.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../api/daemon_client.dart';

/// Caches git status/branches per repo root and runs mutating operations
/// (checkout/commit/push/createPr) with a busy flag and per-root error.
///
/// Every method takes an optional [sessionId]: when given, the operation and
/// its cache entry are scoped to that session's working tree (its worktree),
/// not the project checkout. Cache keys are therefore `sessionId ?? projectId`.
///
/// [refresh] is fire-and-forget: failures land in [errorFor]. Mutators
/// rethrow their failures (so callers can react, e.g. an empty-message
/// commit) and also record them in [errorFor]. Mutators never auto-refresh
/// status; panes call [refresh] after a successful mutation.
class GitStore extends StoreBase {
  GitStore({required DaemonClient Function(String daemonId) clientFor})
      // ignore: prefer_initializing_formals
      : _clientFor = clientFor;

  final DaemonClient Function(String daemonId) _clientFor;

  final Map<String, GitStatus> _status = <String, GitStatus>{};
  final Map<String, List<Branch>> _branches = <String, List<Branch>>{};
  final Map<String, Object> _errors = <String, Object>{};
  final Set<String> _busy = <String>{};

  /// Left-rail badges: sessionId → summary. Session ids are globally unique
  /// (uuid), so the flat map cannot collide across daemons/projects.
  final Map<String, SessionGitSummary> _summaryBySession =
      <String, SessionGitSummary>{};

  /// `daemonId/projectId` → the session ids the last batch returned for that
  /// project, so the next batch replaces (not merges with) stale entries.
  final Map<String, Set<String>> _summarySessionIds =
      <String, Set<String>>{};
  final Map<String, Object> _summaryErrors = <String, Object>{};

  /// One `sessionUpdates`/`resynced` subscription per daemon, armed on the
  /// first [refreshSessionSummaries] for that daemon; alive until [dispose].
  final Map<String, StreamSubscription<Session>> _sessionUpdateSubs =
      <String, StreamSubscription<Session>>{};
  final Map<String, StreamSubscription<void>> _summaryResyncSubs =
      <String, StreamSubscription<void>>{};

  /// Session ids are globally unique (uuid), so `sessionId ?? projectId`
  /// cannot collide with a plain project id.
  String _key(String projectId, String? sessionId) => sessionId ?? projectId;

  GitStatus? statusFor(String projectId, {String? sessionId}) =>
      _status[_key(projectId, sessionId)];

  List<Branch>? branchesFor(String projectId, {String? sessionId}) {
    final List<Branch>? branches = _branches[_key(projectId, sessionId)];
    return branches == null ? null : List<Branch>.unmodifiable(branches);
  }

  bool isBusy(String projectId, {String? sessionId}) =>
      _busy.contains(_key(projectId, sessionId));

  Object? errorFor(String projectId, {String? sessionId}) =>
      _errors[_key(projectId, sessionId)];

  /// The last known git summary (left-rail badges) for [sessionId]; null
  /// until the first [refreshSessionSummaries] for its project.
  SessionGitSummary? sessionSummaryFor(String sessionId) =>
      _summaryBySession[sessionId];

  /// Refetches the per-session git summaries for [projectId], replacing the
  /// project's previous set wholesale (sessions that dropped out — archived,
  /// deleted — lose their badges).
  ///
  /// Fire-and-forget like [refresh]: failures are recorded (see
  /// [sessionSummaryErrorFor]) and swallowed — badges just stay stale.
  Future<void> refreshSessionSummaries(String daemonId, String projectId) async {
    _ensureDaemonSubscriptions(daemonId);
    final String projectKey = '$daemonId/$projectId';
    try {
      final List<SessionGitSummary> summaries =
          await _clientFor(daemonId).gitSessionSummaries(projectId);
      final Set<String> previous =
          _summarySessionIds[projectKey] ?? const <String>{};
      for (final String id in previous) {
        _summaryBySession.remove(id);
      }
      final Set<String> next = <String>{};
      for (final SessionGitSummary summary in summaries) {
        _summaryBySession[summary.sessionId] = summary;
        next.add(summary.sessionId);
      }
      _summarySessionIds[projectKey] = next;
      _summaryErrors.remove(projectKey);
    } catch (error) {
      _summaryErrors[projectKey] = error;
    }
    notifyListeners();
  }

  /// The last refresh failure for [projectId]'s summaries, if any.
  Object? sessionSummaryErrorFor(String daemonId, String projectId) =>
      _summaryErrors['$daemonId/$projectId'];

  /// Arms the per-daemon subscriptions that keep badges fresh without
  /// polling:
  /// - a session landing on `idle`/`error` means a turn just ended (agents
  ///   commit mid-turn) → refetch that project's summaries;
  /// - a resync after reconnect means the daemon's state may have moved
  ///   while the socket was down → refetch every known project.
  ///
  /// Refreshes are gated on the project having been fetched once (the rail
  /// fetches on expansion), so projects nobody is looking at cost nothing.
  void _ensureDaemonSubscriptions(String daemonId) {
    if (_sessionUpdateSubs.containsKey(daemonId)) return;
    final DaemonClient client = _clientFor(daemonId);
    _sessionUpdateSubs[daemonId] = client.sessionUpdates.listen(
        (Session session) => _onSessionUpdate(daemonId, session));
    _summaryResyncSubs[daemonId] =
        client.resynced.listen((void _) => _onResync(daemonId));
  }

  void _onSessionUpdate(String daemonId, Session session) {
    if (session.status != SessionStatus.idle &&
        session.status != SessionStatus.error) {
      return;
    }
    if (!_summarySessionIds.containsKey('$daemonId/${session.projectId}')) {
      return;
    }
    unawaited(refreshSessionSummaries(daemonId, session.projectId));
  }

  void _onResync(String daemonId) {
    final String prefix = '$daemonId/';
    for (final String key in _summarySessionIds.keys.toList()) {
      if (key.startsWith(prefix)) {
        unawaited(refreshSessionSummaries(daemonId, key.substring(prefix.length)));
      }
    }
  }

  Future<void> refresh(String daemonId, String projectId,
      {String? sessionId}) async {
    final String key = _key(projectId, sessionId);
    _busy.add(key);
    notifyListeners();
    try {
      final DaemonClient client = _clientFor(daemonId);
      final GitStatus status =
          await client.gitStatus(projectId, sessionId: sessionId);
      final List<Branch> branches =
          await client.gitBranches(projectId, sessionId: sessionId);
      _status[key] = status;
      _branches[key] = branches;
      _errors.remove(key);
    } catch (error) {
      _errors[key] = error;
    } finally {
      _busy.remove(key);
      notifyListeners();
    }
  }

  Future<List<GitDiff>> diff(
    String daemonId,
    String projectId, {
    String? sessionId,
    String? path,
    bool staged = false,
  }) async {
    final String key = _key(projectId, sessionId);
    try {
      final List<GitDiff> diffs = await _clientFor(daemonId).gitDiff(projectId,
          sessionId: sessionId, path: path, staged: staged);
      _errors.remove(key);
      return diffs;
    } catch (error) {
      _errors[key] = error;
      rethrow;
    }
  }

  Future<void> checkout(String daemonId, String projectId, String branch,
          {String? sessionId}) =>
      _runMutating(
          daemonId,
          _key(projectId, sessionId),
          () => _clientFor(daemonId)
              .gitCheckout(projectId, branch, sessionId: sessionId));

  Future<String> commit(String daemonId, String projectId, String message,
          {String? sessionId, bool stageAll = false}) =>
      _runMutating(
          daemonId,
          _key(projectId, sessionId),
          () => _clientFor(daemonId).gitCommit(projectId, message,
              sessionId: sessionId, stageAll: stageAll));

  Future<void> push(String daemonId, String projectId, {String? sessionId}) =>
      _runMutating(daemonId, _key(projectId, sessionId),
          () => _clientFor(daemonId).gitPush(projectId, sessionId: sessionId));

  Future<MergeResult> mergeToBase(String daemonId, String projectId,
          {required String sessionId}) =>
      _runMutating(daemonId, _key(projectId, sessionId),
          () => _clientFor(daemonId)
              .gitMergeToBase(projectId, sessionId: sessionId));

  Future<String> createPr(String daemonId, String projectId,
          {String? sessionId,
          String? title,
          String? body,
          String? base,
          bool draft = false}) =>
      _runMutating(
          daemonId,
          _key(projectId, sessionId),
          () => _clientFor(daemonId).gitCreatePr(projectId,
              sessionId: sessionId,
              title: title,
              body: body,
              base: base,
              draft: draft));

  Future<T> _runMutating<T>(
    String daemonId,
    String key,
    Future<T> Function() action,
  ) async {
    _busy.add(key);
    notifyListeners();
    try {
      final T result = await action();
      _errors.remove(key);
      return result;
    } catch (error) {
      _errors[key] = error;
      rethrow;
    } finally {
      _busy.remove(key);
      notifyListeners();
    }
  }

  @override
  void dispose() {
    for (final StreamSubscription<Session> sub in _sessionUpdateSubs.values) {
      sub.cancel();
    }
    _sessionUpdateSubs.clear();
    for (final StreamSubscription<void> sub in _summaryResyncSubs.values) {
      sub.cancel();
    }
    _summaryResyncSubs.clear();
    super.dispose();
  }
}
