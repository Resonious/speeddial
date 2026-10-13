import 'dart:async';

import 'package:speeddial_daemon/src/mcp/live_mcp_proxy.dart';
import 'package:speeddial_daemon/src/mcp/mcp_proxy.dart';
import 'package:speeddial_daemon/src/store/daemon_store.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:test/test.dart';

void main() {
  test(
    'new credentials retire connections after in-flight calls finish',
    () async {
      StoredMcpServer server = _server('old-token');
      final List<_Connection> connections = [];
      final LiveMcpProxy proxy = LiveMcpProxy(
        servers: () => [server],
        cwd: '/unused',
        connector: (stored, cwd) async {
          final connection = _Connection(stored.secrets['Authorization']!);
          connections.add(connection);
          return connection;
        },
      );
      addTearDown(proxy.close);
      await proxy.listTools();
      final _Connection old = connections.single;
      final Future<Map<String, Object?>> pending = proxy.callTool(
        'Resend__echo',
        {},
      );
      await old.called.future;

      // The profile (including updatedAt) is identical; only its token changes.
      server = _server('new-token');
      await proxy.listTools();
      expect(connections, hasLength(2));
      expect(old.closed, isFalse);
      final _Connection fresh = connections.last;
      final Future<Map<String, Object?>> next = proxy.callTool(
        'Resend__echo',
        {},
      );
      await fresh.called.future;
      fresh.result.complete({'token': fresh.token});
      expect(await next, {'token': 'new-token'});
      expect(old.calls, 1);
      expect(old.closed, isFalse);
      old.result.complete({'token': old.token});
      expect(await pending, {'token': 'old-token'});
      expect(old.closed, isTrue);
      expect(fresh.closed, isFalse);
      await proxy.listTools();
      expect(connections, hasLength(2));
      await proxy.close();
      expect(fresh.closed, isTrue);
      await expectLater(proxy.listTools(), throwsStateError);
    },
  );

  test('a stale discovery cannot overwrite the refreshed catalog', () async {
    List<StoredMcpServer> servers = [_server('old-token')];
    final Completer<McpUpstreamConnection> connecting = Completer();
    final Completer<void> started = Completer();
    final _Connection old = _Connection('old-token');
    final LiveMcpProxy proxy = LiveMcpProxy(
      servers: () => servers,
      cwd: '/unused',
      connector: (_, _) {
        started.complete();
        return connecting.future;
      },
    );
    addTearDown(proxy.close);
    final Future<McpProxyListResult> stale = proxy.listTools();
    await started.future;
    servers = [];
    expect((await proxy.listTools()).tools, isEmpty);
    connecting.complete(old);
    expect((await stale).tools, hasLength(1));
    expect(old.closed, isTrue);
    expect((await proxy.listTools()).tools, isEmpty);
    await expectLater(proxy.callTool('Resend__echo', {}), throwsArgumentError);
    expect(old.calls, 0);
  });
}

StoredMcpServer _server(String token) => (
  profile: McpServerProfile(
    id: 'resend',
    name: 'Resend',
    transport: McpTransport.http,
    enabled: true,
    secretNames: const ['Authorization'],
    url: 'https://example.test/mcp',
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  ),
  secrets: {'Authorization': token},
);

class _Connection implements McpUpstreamConnection {
  _Connection(this.token);

  final String token;
  final Completer<void> called = Completer();
  final Completer<Map<String, Object?>> result = Completer();
  bool closed = false;
  int calls = 0;

  @override
  Future<List<Map<String, Object?>>> listTools() async => [
    {
      'name': 'echo',
      'inputSchema': {'type': 'object'},
    },
  ];

  @override
  Future<Map<String, Object?>> callTool(
    String name,
    Map<String, Object?> arguments,
  ) {
    calls++;
    called.complete();
    return result.future;
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}
