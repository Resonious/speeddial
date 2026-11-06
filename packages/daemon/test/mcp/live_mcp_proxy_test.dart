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

  test('a change to one server leaves the others connected', () async {
    StoredMcpServer browser = _server('browser-token', id: 'browser');
    StoredMcpServer linear = _server('old-token', id: 'linear');
    final Map<String, List<_Connection>> connections = {};
    final LiveMcpProxy proxy = LiveMcpProxy(
      servers: () => [browser, linear],
      cwd: '/unused',
      connector: (stored, cwd) async {
        final connection = _Connection(stored.secrets['Authorization']!);
        (connections[stored.profile.id] ??= []).add(connection);
        return connection;
      },
    );
    addTearDown(proxy.close);
    await proxy.listTools();

    linear = _server('new-token', id: 'linear');
    await proxy.listTools();
    expect(connections['linear'], hasLength(2));
    expect(connections['linear']!.first.closed, isTrue);
    expect(connections['browser'], hasLength(1));
    expect(connections['browser']!.single.closed, isFalse);

    // Metadata feeds the catalog but does not touch the running process.
    browser = _server('browser-token', id: 'browser', name: 'Firefox');
    final McpProxyListResult renamed = await proxy.listTools();
    expect(
      renamed.tools.map((tool) => tool['name']),
      contains('Firefox__echo'),
    );
    expect(connections['browser'], hasLength(1));
    expect(connections['browser']!.single.closed, isFalse);

    await proxy.close();
    expect(connections['browser']!.single.closed, isTrue);
  });

  test('an adopted connection keeps in-flight calls and ownership', () async {
    final StoredMcpServer browser = _server('browser-token', id: 'browser');
    StoredMcpServer linear = _server('old-token', id: 'linear');
    final Map<String, _Connection> connections = {};
    final LiveMcpProxy proxy = LiveMcpProxy(
      servers: () => [browser, linear],
      cwd: '/unused',
      connector: (stored, cwd) async {
        return connections[stored.profile.id] = _Connection(
          stored.secrets['Authorization']!,
        );
      },
    );
    addTearDown(proxy.close);
    await proxy.listTools();
    final _Connection kept = connections['browser']!;
    final Future<Map<String, Object?>> pending = proxy.callTool(
      'Resend__echo',
      {},
    );
    await kept.called.future;

    linear = _server('new-token', id: 'linear');
    await proxy.listTools();
    kept.result.complete({'token': kept.token});
    expect(await pending, {'token': 'browser-token'});

    // The retired generation has finished; it must not close what it handed on.
    expect(kept.closed, isFalse);
    expect(identical(connections['browser'], kept), isTrue);
  });

  test('a retired discovery failure spares an adopted connection', () async {
    final StoredMcpServer browser = _server('browser-token', id: 'browser');
    StoredMcpServer linear = _server('old-token', id: 'linear');
    final Map<String, _Connection> connections = {};
    final LiveMcpProxy proxy = LiveMcpProxy(
      servers: () => [browser, linear],
      cwd: '/unused',
      connector: (stored, cwd) async {
        return connections[stored.profile.id] = _Connection('unused');
      },
    );
    addTearDown(proxy.close);
    await proxy.listTools();
    final _Connection kept = connections['browser']!;
    final Completer<List<Map<String, Object?>>> listing = Completer();
    kept.nextListing = listing;
    final Future<McpProxyListResult> retired = proxy.listTools();

    linear = _server('new-token', id: 'linear');
    await proxy.listTools();
    listing.completeError(StateError('listing failed'));
    expect((await retired).warnings, isNotEmpty);

    expect(kept.closed, isFalse);
    await proxy.close();
    expect(kept.closed, isTrue);
  });

  test('a removed server closes while the others stay connected', () async {
    final StoredMcpServer browser = _server('browser-token', id: 'browser');
    final StoredMcpServer linear = _server('token', id: 'linear');
    List<StoredMcpServer> servers = [browser, linear];
    final Map<String, _Connection> connections = {};
    final LiveMcpProxy proxy = LiveMcpProxy(
      servers: () => servers,
      cwd: '/unused',
      connector: (stored, cwd) async {
        return connections[stored.profile.id] = _Connection('unused');
      },
    );
    addTearDown(proxy.close);
    await proxy.listTools();

    servers = [browser];
    await proxy.listTools();
    expect(connections['linear']!.closed, isTrue);
    expect(connections['browser']!.closed, isFalse);
  });

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

StoredMcpServer _server(
  String token, {
  String id = 'resend',
  String name = 'Resend',
}) => (
  profile: McpServerProfile(
    id: id,
    name: name,
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

  /// Answers the next listing only, leaving later ones healthy.
  Completer<List<Map<String, Object?>>>? nextListing;

  @override
  Future<List<Map<String, Object?>>> listTools() async {
    final Completer<List<Map<String, Object?>>>? listing = nextListing;
    nextListing = null;
    if (listing != null) return listing.future;
    return [
      {
        'name': 'echo',
        'inputSchema': {'type': 'object'},
      },
    ];
  }

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
