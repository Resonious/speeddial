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
}
