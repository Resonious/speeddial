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
      int strippedInServer = 0;
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
        final Object? rawSchema = upstream['inputSchema'];
        final ({Map<String, Object?> schema, int stripped}) sanitized =
            rawSchema is Map
            ? _sanitizeInputSchema(rawSchema.cast<String, Object?>())
            : (schema: const <String, Object?>{}, stripped: 0);
        if (sanitized.stripped > 0) {
          proxyTool['inputSchema'] = sanitized.schema;
          strippedInServer += sanitized.stripped;
        }
        tools.add(proxyTool);
        routes[publicName] = _ToolRoute(
          connection: server.connection!,
          upstreamName: rawName,
        );
      }
      if (strippedInServer > 0) {
        warnings.add(
          '${server.stored.profile.name}: '
          'removed $strippedInServer JSON-schema pattern constraint(s) using '
          'regex lookaround unsupported by model providers',
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

/// JSON-schema `pattern` constraints are advisory and validated by model
/// providers before a turn runs. OpenAI- and Anthropic-family tool schema
/// validators compile patterns with an RE2-style engine that rejects regex
/// lookaround (`(?=`, `(?!`, `(?<=`, `(?<!`), returning an HTTP 400 that
/// fails every turn carrying the tool catalog. Upstream MCP servers such as
/// Resend publish email patterns with lookahead; the daemon is the only path
/// these descriptors take into agent configuration, so it strips the
/// unsupported constraint here. `format: email` stays intact, the tool stays
/// callable, and server-side validation remains authoritative.
final RegExp _kUnsupportedLookaround = RegExp(r'\(\?(?:=|!|<[!=])');

/// Returns a copy of [schema] with unsupported `pattern` constraints removed,
/// plus how many were dropped. Callers replace `inputSchema` only when
/// [stripped] is non-zero so untouched descriptors keep their upstream
/// identity.
({Map<String, Object?> schema, int stripped}) _sanitizeInputSchema(
  Map<String, Object?> schema,
) {
  int stripped = 0;
  final Map<String, Object?> sanitized = _stripLookaround(schema, () {
    stripped++;
  });
  return (schema: sanitized, stripped: stripped);
}

Map<String, Object?> _stripLookaround(
  Map<String, Object?> object,
  void Function() onRemoved,
) {
  final Map<String, Object?> out = <String, Object?>{};
  for (final MapEntry<String, Object?> entry in object.entries) {
    final Object? value = entry.value;
    if (entry.key == 'pattern' &&
        value is String &&
        _kUnsupportedLookaround.hasMatch(value)) {
      onRemoved();
      continue;
    }
    out[entry.key] = _stripLookaroundValue(value, onRemoved);
  }
  return out;
}

Object? _stripLookaroundValue(Object? value, void Function() onRemoved) {
  switch (value) {
    case Map<String, Object?> map:
      return _stripLookaround(map, onRemoved);
    case Map raw:
      return _stripLookaround(raw.cast<String, Object?>(), onRemoved);
    case List<Object?> list:
      bool changed = false;
      final List<Object?> out = <Object?>[];
      for (final Object? item in list) {
        final Object? sanitized = _stripLookaroundValue(item, onRemoved);
        if (!identical(sanitized, item)) changed = true;
        out.add(sanitized);
      }
      return changed ? out : value;
    default:
      return value;
  }
}

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
