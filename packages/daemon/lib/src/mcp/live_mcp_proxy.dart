import 'dart:async';
import 'dart:convert';

import '../store/daemon_store.dart';
import 'mcp_proxy.dart';

/// Keeps an authenticated bridge current even while its agent cannot reload.
class LiveMcpProxy {
  LiveMcpProxy({required this.servers, required this.cwd, this.connector});

  final List<StoredMcpServer> Function() servers;
  final String cwd;
  final McpUpstreamConnector? connector;
  final Set<_Generation> _generations = <_Generation>{};
  _Generation? _current;
  bool _closed = false;

  Future<McpProxyListResult> listTools() =>
      _use((McpProxySession proxy) => proxy.listTools());

  Future<Map<String, Object?>> callTool(
    String name,
    Map<String, Object?> arguments,
  ) => _use((McpProxySession proxy) => proxy.callTool(name, arguments));

  Future<T> _use<T>(Future<T> Function(McpProxySession) operation) async {
    if (_closed) throw StateError('MCP proxy session is closed');
    final List<StoredMcpServer> snapshot = servers();
    // Include effective secrets: OAuth can rotate tokens without changing the
    // profile. This key remains private to the daemon, like the snapshot itself.
    final String key = jsonEncode([
      for (final StoredMcpServer server in snapshot)
        {
          'profile': server.profile.toJson(),
          'secrets': {
            for (final String name in server.secrets.keys.toList()..sort())
              name: server.secrets[name],
          },
        },
    ]);
    _Generation? current = _current;
    if (current == null || current.key != key) {
      final _Generation? previous = current;
      current = _Generation(
        key,
        McpProxySession(servers: snapshot, cwd: cwd, connector: connector),
      );
      _current = current;
      _generations.add(current);
      if (previous != null) _releaseRetired(previous);
    }
    current.users++;
    try {
      return await operation(current.proxy);
    } finally {
      current.users--;
      _releaseRetired(current);
    }
  }

  void _releaseRetired(_Generation generation) {
    // A configuration change must not interrupt or replay a tool call already
    // using the old connection. Retire it when its last operation finishes.
    if (identical(generation, _current) || generation.users != 0) return;
    if (_generations.remove(generation)) unawaited(generation.proxy.close());
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final List<_Generation> generations = _generations.toList();
    _generations.clear();
    _current = null;
    await Future.wait(generations.map((value) => value.proxy.close()));
  }
}

class _Generation {
  _Generation(this.key, this.proxy);

  final String key;
  final McpProxySession proxy;
  int users = 0;
}
