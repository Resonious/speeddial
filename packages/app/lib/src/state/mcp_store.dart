import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../api/daemon_client.dart';
import 'store_base.dart';

/// Caches daemon-managed MCP server profiles and performs settings mutations.
class McpStore extends StoreBase {
  McpStore({required DaemonClient Function(String daemonId) clientFor})
    // ignore: prefer_initializing_formals
    : _clientFor = clientFor;

  final DaemonClient Function(String daemonId) _clientFor;
  final Map<String, List<McpServerProfile>> _serversByDaemon =
      <String, List<McpServerProfile>>{};
  final Set<String> _loading = <String>{};
  Object? _lastError;

  List<McpServerProfile> serversFor(String daemonId) =>
      List<McpServerProfile>.unmodifiable(
        _serversByDaemon[daemonId] ?? const <McpServerProfile>[],
      );

  bool isLoading(String daemonId) => _loading.contains(daemonId);
  Object? get lastError => _lastError;

  Future<void> refresh(String daemonId) async {
    _loading.add(daemonId);
    notifyListeners();
    try {
      _serversByDaemon[daemonId] = List<McpServerProfile>.of(
        await _clientFor(daemonId).listMcpServers(),
      );
      _lastError = null;
    } catch (error) {
      _lastError = error;
      rethrow;
    } finally {
      _loading.remove(daemonId);
      notifyListeners();
    }
  }

  Future<McpServerProfile> create(
    String daemonId, {
    required String name,
    required McpTransport transport,
    required bool enabled,
    String? projectId,
    String? command,
    List<String> args = const <String>[],
    String? url,
    Map<String, String> secrets = const <String, String>{},
    McpAuthType authType = McpAuthType.none,
    String? oauthClientId,
    String? oauthClientSecret,
  }) async {
    try {
      final McpServerProfile profile = await _clientFor(daemonId)
          .createMcpServer(
            name: name,
            transport: transport,
            enabled: enabled,
            projectId: projectId,
            command: command,
            args: args,
            url: url,
            secrets: secrets,
            authType: authType,
            oauthClientId: oauthClientId,
            oauthClientSecret: oauthClientSecret,
          );
      _serversByDaemon
          .putIfAbsent(daemonId, () => <McpServerProfile>[])
          .add(profile);
      _serversByDaemon[daemonId]!.sort(_compareProfiles);
      _lastError = null;
      notifyListeners();
      return profile;
    } catch (error) {
      _lastError = error;
      notifyListeners();
      rethrow;
    }
  }

  Future<McpServerProfile> update(
    String daemonId, {
    required String id,
    required String name,
    required McpTransport transport,
    required bool enabled,
    String? command,
    List<String> args = const <String>[],
    String? url,
    Map<String, String> secrets = const <String, String>{},
    List<String> removeSecretNames = const <String>[],
    McpAuthType authType = McpAuthType.none,
    String? oauthClientId,
    String? oauthClientSecret,
  }) async {
    try {
      final McpServerProfile profile = await _clientFor(daemonId)
          .updateMcpServer(
            id: id,
            name: name,
            transport: transport,
            enabled: enabled,
            command: command,
            args: args,
            url: url,
            secrets: secrets,
            removeSecretNames: removeSecretNames,
            authType: authType,
            oauthClientId: oauthClientId,
            oauthClientSecret: oauthClientSecret,
          );
      final List<McpServerProfile>? servers = _serversByDaemon[daemonId];
      final int index =
          servers?.indexWhere((McpServerProfile server) => server.id == id) ??
          -1;
      if (index >= 0) {
        servers![index] = profile;
        servers.sort(_compareProfiles);
      }
      _lastError = null;
      notifyListeners();
      return profile;
    } catch (error) {
      _lastError = error;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> remove(String daemonId, String id) async {
    try {
      await _clientFor(daemonId).deleteMcpServer(id);
      _serversByDaemon[daemonId]?.removeWhere(
        (McpServerProfile profile) => profile.id == id,
      );
      _lastError = null;
      notifyListeners();
    } catch (error) {
      _lastError = error;
      notifyListeners();
      rethrow;
    }
  }

  Future<McpOAuthFlow> beginOAuth(String daemonId, String id) async {
    try {
      final McpOAuthFlow flow = await _clientFor(daemonId).beginMcpOAuth(id);
      _lastError = null;
      return flow;
    } catch (error) {
      _lastError = error;
      notifyListeners();
      rethrow;
    }
  }

  Future<McpServerProfile> oauthStatus(
    String daemonId,
    String id,
    String flowId,
  ) async {
    try {
      final McpServerProfile profile = await _clientFor(daemonId)
          .mcpOAuthStatus(id, flowId);
      _replaceProfile(daemonId, profile);
      _lastError = null;
      notifyListeners();
      return profile;
    } catch (error) {
      _lastError = error;
      notifyListeners();
      rethrow;
    }
  }

  Future<McpServerProfile> disconnectOAuth(String daemonId, String id) async {
    try {
      final McpServerProfile profile = await _clientFor(daemonId)
          .disconnectMcpOAuth(id);
      _replaceProfile(daemonId, profile);
      _lastError = null;
      notifyListeners();
      return profile;
    } catch (error) {
      _lastError = error;
      notifyListeners();
      rethrow;
    }
  }

  void _replaceProfile(String daemonId, McpServerProfile profile) {
    final List<McpServerProfile>? servers = _serversByDaemon[daemonId];
    final int index =
        servers?.indexWhere(
          (McpServerProfile server) => server.id == profile.id,
        ) ??
        -1;
    if (index >= 0) servers![index] = profile;
  }

  static int _compareProfiles(McpServerProfile a, McpServerProfile b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase());
}
