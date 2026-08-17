import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../api/daemon_client.dart';

/// Caches the project list per daemon and surfaces load state.
///
/// [refresh] is fire-and-forget for the UI: failures are recorded in
/// [lastError] and rethrown nowhere. Mutating methods ([add], [remove])
/// update the cache on success, record failures in [lastError], and rethrow
/// so callers can react.
///
/// On first use of a daemon the store subscribes to its `projectsChanged`
/// notifications and refetches the listing, so daemon-side project changes
/// surface without a manual [refresh]; the subscription lives until the
/// store is disposed.
class ProjectsStore extends ChangeNotifier {
  ProjectsStore({required DaemonClient Function(String daemonId) clientFor})
      // ignore: prefer_initializing_formals
      : _clientFor = clientFor;

  final DaemonClient Function(String daemonId) _clientFor;

  final Map<String, List<Project>> _projectsByDaemon =
      <String, List<Project>>{};

  /// One `projectsChanged` subscription per daemon, alive from first use
  /// until [dispose].
  final Map<String, StreamSubscription<void>> _projectSubs =
      <String, StreamSubscription<void>>{};

  final Set<String> _loading = <String>{};
  Object? _lastError;

  /// Projects known for [daemonId]; empty until the first refresh succeeds.
  List<Project> projectsFor(String daemonId) => List<Project>.unmodifiable(
      _projectsByDaemon[daemonId] ?? const <Project>[]);

  bool isLoading(String daemonId) => _loading.contains(daemonId);

  /// Last error from any operation, cleared on success.
  Object? get lastError => _lastError;

  Future<void> refresh(String daemonId) async {
    _ensureDaemonSubscriptions(daemonId);
    _loading.add(daemonId);
    notifyListeners();
    try {
      final List<Project> projects = await _clientFor(daemonId).listProjects();
      // Clients may hand back unmodifiable views (the fake does); cache a
      // growable copy so [add]/[remove] can mutate the bucket in place.
      _projectsByDaemon[daemonId] = List<Project>.of(projects);
      _lastError = null;
    } catch (error) {
      _lastError = error;
    } finally {
      _loading.remove(daemonId);
      notifyListeners();
    }
  }

  Future<Project> add(String daemonId, String path, {String? name}) async {
    _ensureDaemonSubscriptions(daemonId);
    try {
      final Project project =
          await _clientFor(daemonId).addProject(path, name: name);
      // Update the cache only if a listing already exists, so a stale
      // empty bucket never hides other projects.
      _projectsByDaemon[daemonId]?.add(project);
      _lastError = null;
      notifyListeners();
      return project;
    } catch (error) {
      _lastError = error;
      rethrow;
    }
  }

  Future<void> remove(String daemonId, String projectId) async {
    _ensureDaemonSubscriptions(daemonId);
    try {
      await _clientFor(daemonId).removeProject(projectId);
      _projectsByDaemon[daemonId]?.removeWhere(
          (Project p) => p.id == projectId);
      _lastError = null;
      notifyListeners();
    } catch (error) {
      _lastError = error;
      rethrow;
    }
  }

  /// Subscribes to the daemon's `projectsChanged` notifications so
  /// daemon-side add/rename/remove surface via a refetch.
  void _ensureDaemonSubscriptions(String daemonId) {
    if (_projectSubs.containsKey(daemonId)) return;
    final DaemonClient client = _clientFor(daemonId);
    _projectSubs[daemonId] = client.projectsChanged.listen((void _) {
      unawaited(refresh(daemonId));
    });
  }

  @override
  void dispose() {
    for (final StreamSubscription<void> sub in _projectSubs.values) {
      sub.cancel();
    }
    _projectSubs.clear();
    super.dispose();
  }
}
