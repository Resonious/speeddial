import 'dart:async';

import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../api/daemon_client.dart';
import 'store_base.dart';

/// Daemon-scoped metadata: harnesses, environment names, and the daemon's own
/// [DaemonInfo] (the provider catalog).
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

  /// Last successful [DaemonInfo] per daemon, plus its in-flight refreshes.
  final Map<String, DaemonInfo> _infoByDaemon = <String, DaemonInfo>{};
  final Map<String, Object> _infoErrors = <String, Object>{};
  final Map<String, Future<void>> _infoInFlight = <String, Future<void>>{};

  /// The cached [DaemonInfo] for [daemonId], or null before the first
  /// successful [refreshInfo]. Provider pickers paint from this immediately
  /// and let [refreshInfo] update them in place.
  DaemonInfo? infoFor(String daemonId) => _infoByDaemon[daemonId];

  /// The last [refreshInfo] failure for [daemonId], if any. A non-null value
  /// with a null [infoFor] means the first fetch failed.
  Object? infoErrorFor(String daemonId) => _infoErrors[daemonId];

  /// Refetches [daemonId]'s [DaemonInfo] — the provider catalog, whose probes
  /// spawn the agent CLIs and are the slow part of any provider picker.
  ///
  /// Fire-and-forget (like [GitStore.refresh]): failures are recorded for
  /// [infoErrorFor] and swallowed, so callers can kick it without an error
  /// path. Concurrent calls for one daemon share a single round-trip.
  Future<void> refreshInfo(String daemonId) {
    final Future<void>? inFlight = _infoInFlight[daemonId];
    if (inFlight != null) return inFlight;
    final Future<void> future = _fetchInfo(daemonId);
    _infoInFlight[daemonId] = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_infoInFlight[daemonId], future)) {
          _infoInFlight.remove(daemonId);
        }
      }),
    );
    return future;
  }

  Future<void> _fetchInfo(String daemonId) async {
    try {
      _infoByDaemon[daemonId] = await _clientFor(daemonId).info();
      _infoErrors.remove(daemonId);
    } catch (error) {
      _infoErrors[daemonId] = error;
    }
    notifyListeners();
  }

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
