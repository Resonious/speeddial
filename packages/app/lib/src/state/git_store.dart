import 'package:flutter/foundation.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../api/daemon_client.dart';

/// Caches git status/branches per project and runs mutating operations
/// (checkout/commit/push/createPr) with a busy flag and per-project error.
///
/// [refresh] is fire-and-forget: failures land in [errorFor]. Mutators
/// rethrow their failures (so callers can react, e.g. an empty-message
/// commit) and also record them in [errorFor]. Mutators never auto-refresh
/// status; panes call [refresh] after a successful mutation.
class GitStore extends ChangeNotifier {
  GitStore({required DaemonClient Function(String daemonId) clientFor})
      // ignore: prefer_initializing_formals
      : _clientFor = clientFor;

  final DaemonClient Function(String daemonId) _clientFor;

  final Map<String, GitStatus> _status = <String, GitStatus>{};
  final Map<String, List<Branch>> _branches = <String, List<Branch>>{};
  final Map<String, Object> _errors = <String, Object>{};
  final Set<String> _busy = <String>{};

  GitStatus? statusFor(String projectId) => _status[projectId];

  List<Branch>? branchesFor(String projectId) {
    final List<Branch>? branches = _branches[projectId];
    return branches == null ? null : List<Branch>.unmodifiable(branches);
  }

  bool isBusy(String projectId) => _busy.contains(projectId);

  Object? errorFor(String projectId) => _errors[projectId];

  Future<void> refresh(String daemonId, String projectId) async {
    _busy.add(projectId);
    notifyListeners();
    try {
      final DaemonClient client = _clientFor(daemonId);
      final GitStatus status = await client.gitStatus(projectId);
      final List<Branch> branches = await client.gitBranches(projectId);
      _status[projectId] = status;
      _branches[projectId] = branches;
      _errors.remove(projectId);
    } catch (error) {
      _errors[projectId] = error;
    } finally {
      _busy.remove(projectId);
      notifyListeners();
    }
  }

  Future<List<GitDiff>> diff(
    String daemonId,
    String projectId, {
    String? path,
    bool staged = false,
  }) async {
    try {
      final List<GitDiff> diffs =
          await _clientFor(daemonId).gitDiff(projectId, path: path, staged: staged);
      _errors.remove(projectId);
      return diffs;
    } catch (error) {
      _errors[projectId] = error;
      rethrow;
    }
  }

  Future<void> checkout(String daemonId, String projectId, String branch) =>
      _runMutating(
          daemonId, projectId, () => _clientFor(daemonId).gitCheckout(projectId, branch));

  Future<String> commit(String daemonId, String projectId, String message,
          {bool stageAll = false}) =>
      _runMutating(daemonId, projectId,
          () => _clientFor(daemonId).gitCommit(projectId, message, stageAll: stageAll));

  Future<void> push(String daemonId, String projectId) => _runMutating(
      daemonId, projectId, () => _clientFor(daemonId).gitPush(projectId));

  Future<String> createPr(String daemonId, String projectId,
          {String? title, String? body, String? base, bool draft = false}) =>
      _runMutating(
          daemonId,
          projectId,
          () => _clientFor(daemonId).gitCreatePr(
              projectId, title: title, body: body, base: base, draft: draft));

  Future<T> _runMutating<T>(
    String daemonId,
    String projectId,
    Future<T> Function() action,
  ) async {
    _busy.add(projectId);
    notifyListeners();
    try {
      final T result = await action();
      _errors.remove(projectId);
      return result;
    } catch (error) {
      _errors[projectId] = error;
      rethrow;
    } finally {
      _busy.remove(projectId);
      notifyListeners();
    }
  }
}
