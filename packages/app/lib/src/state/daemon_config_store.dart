import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../api/daemon_client.dart';
import 'store_base.dart';

/// Daemon-scoped harness metadata and write-only environment configuration.
class DaemonConfigStore extends StoreBase {
  DaemonConfigStore({required DaemonClient Function(String daemonId) clientFor})
    // ignore: prefer_initializing_formals
    : _clientFor = clientFor;

  final DaemonClient Function(String daemonId) _clientFor;
  final Map<String, List<HarnessInfo>> _harnessesByDaemon =
      <String, List<HarnessInfo>>{};
  final Map<String, List<String>> _environmentNamesByDaemon =
      <String, List<String>>{};
  final Set<String> _loadingHarnesses = <String>{};
  final Set<String> _loadingEnvironment = <String>{};
  final Set<(String, String)> _updatingHarnesses = <(String, String)>{};
  Object? _lastError;

  List<HarnessInfo> harnessesFor(String daemonId) =>
      List<HarnessInfo>.unmodifiable(
        _harnessesByDaemon[daemonId] ?? const <HarnessInfo>[],
      );

  List<String> environmentNamesFor(String daemonId) =>
      List<String>.unmodifiable(
        _environmentNamesByDaemon[daemonId] ?? const <String>[],
      );

  bool isLoadingHarnesses(String daemonId) =>
      _loadingHarnesses.contains(daemonId);
  bool isLoadingEnvironment(String daemonId) =>
      _loadingEnvironment.contains(daemonId);
  bool isUpdatingHarness(String daemonId, String harnessId) =>
      _updatingHarnesses.contains((daemonId, harnessId));
  Object? get lastError => _lastError;

  Future<void> refreshHarnesses(String daemonId) async {
    _loadingHarnesses.add(daemonId);
    notifyListeners();
    try {
      _harnessesByDaemon[daemonId] = List<HarnessInfo>.of(
        await _clientFor(daemonId).listHarnesses(),
      );
      _lastError = null;
    } catch (error) {
      _lastError = error;
      rethrow;
    } finally {
      _loadingHarnesses.remove(daemonId);
      notifyListeners();
    }
  }

  Future<HarnessInfo> updateHarness(String daemonId, String harnessId) async {
    final (String, String) key = (daemonId, harnessId);
    _updatingHarnesses.add(key);
    notifyListeners();
    try {
      final HarnessInfo updated = await _clientFor(daemonId)
          .updateHarness(harnessId);
      final List<HarnessInfo>? harnesses = _harnessesByDaemon[daemonId];
      final int index =
          harnesses?.indexWhere(
            (HarnessInfo harness) => harness.id == harnessId,
          ) ??
          -1;
      if (index >= 0) harnesses![index] = updated;
      _lastError = null;
      return updated;
    } catch (error) {
      _lastError = error;
      rethrow;
    } finally {
      _updatingHarnesses.remove(key);
      notifyListeners();
    }
  }

  Future<void> refreshEnvironment(String daemonId) async {
    _loadingEnvironment.add(daemonId);
    notifyListeners();
    try {
      _environmentNamesByDaemon[daemonId] = List<String>.of(
        await _clientFor(daemonId).listEnvironmentNames(),
      );
      _lastError = null;
    } catch (error) {
      _lastError = error;
      rethrow;
    } finally {
      _loadingEnvironment.remove(daemonId);
      notifyListeners();
    }
  }

  Future<void> setEnvironmentVariable(
    String daemonId,
    String name,
    String value,
  ) async {
    try {
      _environmentNamesByDaemon[daemonId] = List<String>.of(
        await _clientFor(daemonId)
            .updateEnvironment(set: <String, String>{name: value}),
      );
      _lastError = null;
      notifyListeners();
    } catch (error) {
      _lastError = error;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> removeEnvironmentVariable(String daemonId, String name) async {
    try {
      _environmentNamesByDaemon[daemonId] = List<String>.of(
        await _clientFor(daemonId).updateEnvironment(remove: <String>[name]),
      );
      _lastError = null;
      notifyListeners();
    } catch (error) {
      _lastError = error;
      notifyListeners();
      rethrow;
    }
  }
}
