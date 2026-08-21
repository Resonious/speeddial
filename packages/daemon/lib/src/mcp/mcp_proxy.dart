/// Daemon-owned MCP clients and per-agent tool aggregation.
///
/// SpeedDial-managed MCP credentials and commands terminate here. Agents see
/// only the built-in `speeddial` MCP server; its dynamic tools are routed to
/// the matching upstream connection owned by [McpProxySession].
library;

import 'dart:async';
import 'dart:io';

import '../store/daemon_store.dart';
import 'mcp_upstream.dart';

export 'mcp_upstream.dart';

/// Result of a best-effort list across every configured upstream server.
class McpProxyListResult {
  const McpProxyListResult({required this.tools, required this.warnings});

  final List<Map<String, Object?>> tools;
  final List<String> warnings;
}

/// Aggregates a fixed snapshot of the managed MCP profiles visible to one
/// agent session. Each authenticated built-in bridge owns one instance.
class McpProxySession {
  McpProxySession({
    required List<StoredMcpServer> servers,
    required this.cwd,
    McpUpstreamConnector? connector,
  }) : _servers = List<StoredMcpServer>.unmodifiable(servers),
       _connector = connector ?? connectMcpUpstream;

  final List<StoredMcpServer> _servers;
  final String cwd;
  final McpUpstreamConnector _connector;
  final Map<String, McpUpstreamConnection> _connections =
      <String, McpUpstreamConnection>{};
  final Map<String, Future<McpUpstreamConnection>> _connecting =
      <String, Future<McpUpstreamConnection>>{};
  final Map<String, _ToolRoute> _routes = <String, _ToolRoute>{};
  Future<McpProxyListResult>? _listing;
  bool _closed = false;

  Future<McpProxyListResult> listTools() {
    if (_closed) throw StateError('MCP proxy session is closed');
    final Future<McpProxyListResult>? active = _listing;
    if (active != null) return active;
    final Future<McpProxyListResult> listing = _listTools();
    _listing = listing;
    return listing.whenComplete(() {
      if (identical(_listing, listing)) _listing = null;
    });
  }

  Future<McpProxyListResult> _listTools() async {
    final List<_ServerTools> listed = await Future.wait(
      _servers.map(_listServerTools),
    );
    final List<Map<String, Object?>> tools = <Map<String, Object?>>[];
    final List<String> warnings = <String>[];
    final Map<String, _ToolRoute> routes = <String, _ToolRoute>{};

    for (final _ServerTools server in listed) {
      final Object? error = server.error;
      if (error != null) {
        warnings.add('${server.stored.profile.name}: ${_errorMessage(error)}');
        continue;
      }
      final Set<String> allocated = routes.keys.toSet();
      for (final Map<String, Object?> upstream in server.tools) {
        final Object? rawName = upstream['name'];
        if (rawName is! String || rawName.isEmpty) {
          warnings.add(
            '${server.stored.profile.name}: ignored a tool without a name',
          );
          continue;
        }
        final String baseName =
            '${_toolComponent(server.stored.profile.name)}__${_toolComponent(rawName)}';
        String publicName = baseName;
        for (int suffix = 2; allocated.contains(publicName); suffix++) {
          publicName = '${baseName}__$suffix';
        }
        allocated.add(publicName);

        final Map<String, Object?> proxyTool = Map<String, Object?>.from(
          upstream,
        );
        proxyTool['name'] = publicName;
        final Object? description = upstream['description'];
        final String source = 'MCP server "${server.stored.profile.name}".';
        proxyTool['description'] =
            description is String && description.isNotEmpty
            ? '$source $description'
            : source;
        final Map<String, Object?> metadata = switch (upstream['_meta']) {
          final Map value => Map<String, Object?>.from(
            value.cast<String, Object?>(),
          ),
          _ => <String, Object?>{},
        };
        metadata['speeddial/serverId'] = server.stored.profile.id;
        metadata['speeddial/serverName'] = server.stored.profile.name;
        metadata['speeddial/upstreamToolName'] = rawName;
        proxyTool['_meta'] = metadata;
        tools.add(proxyTool);
        routes[publicName] = _ToolRoute(
          connection: server.connection!,
          upstreamName: rawName,
        );
      }
    }

    _routes
      ..clear()
      ..addAll(routes);
    return McpProxyListResult(
      tools: List<Map<String, Object?>>.unmodifiable(tools),
      warnings: List<String>.unmodifiable(warnings),
    );
  }

  Future<_ServerTools> _listServerTools(StoredMcpServer stored) async {
    McpUpstreamConnection? connection;
    try {
      connection = await _connectionFor(stored);
      return _ServerTools(
        stored: stored,
        connection: connection,
        tools: await connection.listTools(),
      );
    } on Object catch (error) {
      if (connection != null) {
        _connections.remove(stored.profile.id);
        unawaited(_closeUpstream(connection));
      }
      return _ServerTools(stored: stored, error: error);
    }
  }

  Future<McpUpstreamConnection> _connectionFor(StoredMcpServer stored) async {
    final String id = stored.profile.id;
    final McpUpstreamConnection? existing = _connections[id];
    if (existing != null) return existing;
    final Future<McpUpstreamConnection>? active = _connecting[id];
    if (active != null) return active;

    final Future<McpUpstreamConnection> connecting = _connector(stored, cwd);
    _connecting[id] = connecting;
    try {
      final McpUpstreamConnection connection = await connecting;
      if (_closed) {
        await _closeUpstream(connection);
        throw StateError('MCP proxy session is closed');
      }
      _connections[id] = connection;
      return connection;
    } finally {
      if (identical(_connecting[id], connecting)) _connecting.remove(id);
    }
  }

  Future<Map<String, Object?>> callTool(
    String name,
    Map<String, Object?> arguments,
  ) async {
    if (_closed) throw StateError('MCP proxy session is closed');
    if (_routes.isEmpty) await listTools();
    final _ToolRoute? route = _routes[name];
    if (route == null) throw ArgumentError('Unknown managed MCP tool: $name');
    return route.connection.callTool(route.upstreamName, arguments);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final List<McpUpstreamConnection> connections = _connections.values.toList(
      growable: false,
    );
    _connections.clear();
    _routes.clear();
    await Future.wait(connections.map(_closeUpstream));
  }
}

Future<void> _closeUpstream(McpUpstreamConnection connection) async {
  try {
    await connection.close();
  } on Object {
    // A broken upstream must not turn bridge or daemon cleanup into an error.
  }
}

String _toolComponent(String value) {
  final StringBuffer buffer = StringBuffer();
  bool separator = false;
  for (final int rune in value.runes) {
    final bool allowed =
        (rune >= 0x30 && rune <= 0x39) ||
        (rune >= 0x41 && rune <= 0x5a) ||
        (rune >= 0x61 && rune <= 0x7a) ||
        rune == 0x5f ||
        rune == 0x2d;
    if (allowed) {
      buffer.writeCharCode(rune);
      separator = false;
    } else if (!separator && buffer.isNotEmpty) {
      buffer.write('_');
      separator = true;
    }
  }
  final String result = buffer.toString().replaceFirst(RegExp(r'_+$'), '');
  return result.isEmpty ? 'unnamed' : result;
}

String _errorMessage(Object error) => switch (error) {
  final TimeoutException value => value.message ?? 'request timed out',
  final FormatException value => value.message,
  final StateError value => value.message,
  final ProcessException value => value.message,
  _ => error.toString(),
};

class _ToolRoute {
  const _ToolRoute({required this.connection, required this.upstreamName});

  final McpUpstreamConnection connection;
  final String upstreamName;
}

class _ServerTools {
  const _ServerTools({
    required this.stored,
    this.connection,
    this.tools = const <Map<String, Object?>>[],
    this.error,
  });

  final StoredMcpServer stored;
  final McpUpstreamConnection? connection;
  final List<Map<String, Object?>> tools;
  final Object? error;
}
