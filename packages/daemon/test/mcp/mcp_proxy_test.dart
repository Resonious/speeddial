import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_daemon/src/mcp/mcp_proxy.dart';
import 'package:speeddial_daemon/src/store/daemon_store.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:test/test.dart';

void main() {
  test(
    'aggregates, qualifies, routes, isolates failures, and closes',
    () async {
      final _FakeConnection first = _FakeConnection(
        'first',
        <Map<String, Object?>>[
          _tool('read.file', 'Reads from the first server.'),
        ],
      );
      final _FakeConnection second = _FakeConnection(
        'second',
        <Map<String, Object?>>[
          _tool('read file', 'Reads from the second server.'),
        ],
      );
      final StoredMcpServer firstServer = _stored(
        id: 'first',
        name: 'Server One',
        transport: McpTransport.stdio,
      );
      final StoredMcpServer secondServer = _stored(
        id: 'second',
        name: 'Server@One',
        transport: McpTransport.http,
      );
      final StoredMcpServer brokenServer = _stored(
        id: 'broken',
        name: 'Broken',
        transport: McpTransport.stdio,
      );
      final McpProxySession proxy = McpProxySession(
        servers: <StoredMcpServer>[firstServer, secondServer, brokenServer],
        cwd: Directory.current.path,
        connector: (StoredMcpServer server, String cwd) async =>
            switch (server.profile.id) {
              'first' => first,
              'second' => second,
              _ => throw StateError('connection refused'),
            },
      );
      addTearDown(proxy.close);

      final McpProxyListResult listed = await proxy.listTools();
      expect(
        listed.tools.map((Map<String, Object?> tool) => tool['name']),
        <String>['Server_One__read_file', 'Server_One__read_file__2'],
      );
      expect(listed.warnings, <String>['Broken: connection refused']);
      expect(
        listed.tools.first['description'],
        'MCP server "Server One". Reads from the first server.',
      );
      expect(
        (listed.tools.first['_meta']! as Map)['speeddial/upstreamToolName'],
        'read.file',
      );

      final Map<String, Object?> firstResult = await proxy.callTool(
        'Server_One__read_file',
        <String, Object?>{'path': 'one.txt'},
      );
      final Map<String, Object?> secondResult = await proxy.callTool(
        'Server_One__read_file__2',
        <String, Object?>{'path': 'two.txt'},
      );
      expect(firstResult['server'], 'first');
      expect(secondResult['server'], 'second');
      expect(first.calls.single.name, 'read.file');
      expect(second.calls.single.name, 'read file');

      await proxy.close();
      expect(first.closed, isTrue);
      expect(second.closed, isTrue);
    },
  );

  test(
    'stdio client initializes, answers roots, paginates, and calls',
    () async {
      final Directory cwd = await Directory.systemTemp.createTemp(
        'speeddial_mcp_stdio_test_',
      );
      addTearDown(() => cwd.delete(recursive: true));
      final String fixture = File(
        p.join('test', 'fixtures', 'fake_mcp_server.dart'),
      ).absolute.path;
      final StoredMcpServer server = _stored(
        id: 'stdio',
        name: 'fixture',
        transport: McpTransport.stdio,
        command: Platform.resolvedExecutable,
        args: <String>[fixture],
        secrets: const <String, String>{'FAKE_TOKEN': 'daemon-only'},
      );
      final McpUpstreamConnection connection = await connectMcpUpstream(
        server,
        cwd.path,
        timeout: const Duration(seconds: 10),
      );
      addTearDown(connection.close);

      final List<Map<String, Object?>> tools = await connection.listTools();
      expect(tools.map((Map<String, Object?> tool) => tool['name']), <String>[
        'echo',
        'environment',
      ]);
      final Map<String, Object?> result = await connection.callTool(
        'echo',
        <String, Object?>{'value': 7},
      );
      final List<Object?> content = result['content']! as List<Object?>;
      final Map<String, Object?> payload = (jsonDecode(
        (content.single! as Map)['text']! as String,
      ) as Map).cast<String, Object?>();
      expect(payload['name'], 'echo');
      expect(payload['arguments'], <String, Object?>{'value': 7});
      expect(payload['token'], 'daemon-only');
      expect(payload['cwd'], cwd.path);
      expect((payload['root']! as Map)['uri'], cwd.absolute.uri.toString());
    },
  );

  test(
    'HTTP client initializes, resumes SSE, answers roots, calls, and deletes',
    () async {
      final Directory cwd = await Directory.systemTemp.createTemp(
        'speeddial_mcp_http_test_',
      );
      addTearDown(() => cwd.delete(recursive: true));
      final _FakeHttpTransport transport = _FakeHttpTransport(cwd);
      final StoredMcpServer server = _stored(
        id: 'http',
        name: 'remote',
        transport: McpTransport.http,
        url: 'https://mcp.example.test/service',
        secrets: const <String, String>{'Authorization': 'Bearer daemon-only'},
      );
      final McpUpstreamConnection connection = await connectMcpUpstream(
        server,
        cwd.path,
        httpTransport: transport,
        timeout: const Duration(seconds: 10),
      );
      addTearDown(connection.close);

      final List<Map<String, Object?>> tools = await connection.listTools();
      expect(tools.single['name'], 'remote_echo');
      final Map<String, Object?> result = await connection.callTool(
        'remote_echo',
        <String, Object?>{'value': 'hello'},
      );
      expect(result['structuredContent'], <String, Object?>{'value': 'hello'});
      expect(transport.rootResponse?['roots'], <Object?>[
        <String, Object?>{
          'uri': cwd.absolute.uri.toString(),
          'name': p.basename(cwd.path),
        },
      ]);
      final _HttpExchange resumed = transport.exchanges.singleWhere(
        (_HttpExchange exchange) => exchange.method == 'GET',
      );
      expect(resumed.headers['Last-Event-ID'], 'list-stream-1');
      for (final _HttpExchange exchange in transport.exchanges.skip(1)) {
        expect(exchange.headers['Authorization'], 'Bearer daemon-only');
        expect(exchange.headers['MCP-Session-Id'], 'session-123');
        expect(exchange.headers['MCP-Protocol-Version'], '2025-11-25');
      }

      await connection.close();
      expect(transport.deleted, isTrue);
      expect(transport.closed, isTrue);
    },
  );
}

Map<String, Object?> _tool(String name, String description) =>
    <String, Object?>{
      'name': name,
      'description': description,
      'inputSchema': <String, Object?>{
        'type': 'object',
        'additionalProperties': true,
      },
    };

StoredMcpServer _stored({
  required String id,
  required String name,
  required McpTransport transport,
  String? command,
  List<String> args = const <String>[],
  String? url,
  Map<String, String> secrets = const <String, String>{},
}) => (
  profile: McpServerProfile(
    id: id,
    name: name,
    transport: transport,
    enabled: true,
    command: command ?? (transport == McpTransport.stdio ? '/bin/false' : null),
    args: args,
    url:
        url ??
        (transport == McpTransport.http ? 'https://example.test/mcp' : null),
    secretNames: secrets.keys.toList(growable: false),
    createdAt: DateTime.utc(2026, 8, 21),
    updatedAt: DateTime.utc(2026, 8, 21),
  ),
  secrets: secrets,
);

class _FakeConnection implements McpUpstreamConnection {
  _FakeConnection(this.label, this.tools);

  final String label;
  final List<Map<String, Object?>> tools;
  final List<({String name, Map<String, Object?> arguments})> calls =
      <({String name, Map<String, Object?> arguments})>[];
  bool closed = false;

  @override
  Future<List<Map<String, Object?>>> listTools() async => tools;

  @override
  Future<Map<String, Object?>> callTool(
    String name,
    Map<String, Object?> arguments,
  ) async {
    calls.add((name: name, arguments: arguments));
    return <String, Object?>{'server': label};
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

class _FakeHttpTransport implements McpHttpTransport {
  _FakeHttpTransport(this.cwd);

  final Directory cwd;
  final List<_HttpExchange> exchanges = <_HttpExchange>[];
  Map<String, Object?>? rootResponse;
  bool deleted = false;
  bool closed = false;

  @override
  Future<McpHttpResponse> send({
    required String method,
    required Uri url,
    required Map<String, String> headers,
    String? body,
  }) async {
    exchanges.add(
      _HttpExchange(method: method, headers: Map<String, String>.from(headers)),
    );
    if (method == 'DELETE') {
      deleted = true;
      return _response(HttpStatus.ok, 'text/plain', '');
    }
    if (method == 'GET') {
      return _response(
        HttpStatus.ok,
        'text/event-stream',
        'data: ${jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 2,
          'result': <String, Object?>{
            'tools': <Object?>[_tool('remote_echo', 'Remote echo.')],
          },
        })}\n\n',
      );
    }

    final Map<String, Object?> message = (jsonDecode(body!) as Map)
        .cast<String, Object?>();
    switch (message['method']) {
      case 'initialize':
        return _response(
          HttpStatus.ok,
          'application/json',
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'id': message['id'],
            'result': <String, Object?>{
              'protocolVersion': '2025-11-25',
              'capabilities': <String, Object?>{
                'tools': <String, Object?>{'listChanged': false},
              },
              'serverInfo': <String, Object?>{
                'name': 'fake-http',
                'version': '1.0.0',
              },
            },
          }),
          extraHeaders: const <String, String>{'mcp-session-id': 'session-123'},
        );
      case 'notifications/initialized':
        return _response(HttpStatus.accepted, 'text/plain', '');
      case 'tools/list':
        return _response(
          HttpStatus.ok,
          'text/event-stream',
          'id: list-stream-1\n'
              'data: ${jsonEncode(<String, Object?>{'jsonrpc': '2.0', 'id': 'roots-from-server', 'method': 'roots/list', 'params': const <String, Object?>{}})}\n\n'
              'retry: 0\n\n',
        );
      case 'tools/call':
        final Map<String, Object?> params = (message['params']! as Map)
            .cast<String, Object?>();
        return _response(
          HttpStatus.ok,
          'application/json',
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'id': message['id'],
            'result': <String, Object?>{
              'content': <Object?>[
                <String, Object?>{'type': 'text', 'text': 'ok'},
              ],
              'structuredContent': params['arguments'],
              'isError': false,
            },
          }),
        );
      case null:
        if (message['id'] == 'roots-from-server') {
          rootResponse = (message['result']! as Map).cast<String, Object?>();
          return _response(HttpStatus.accepted, 'text/plain', '');
        }
    }
    throw StateError('Unexpected fake HTTP MCP message: $message');
  }

  McpHttpResponse _response(
    int status,
    String contentType,
    String body, {
    Map<String, String> extraHeaders = const <String, String>{},
  }) => McpHttpResponse(
    statusCode: status,
    headers: <String, String>{'content-type': contentType, ...extraHeaders},
    body: Stream<List<int>>.value(utf8.encode(body)),
  );

  @override
  Future<void> close() async {
    closed = true;
  }
}

class _HttpExchange {
  const _HttpExchange({required this.method, required this.headers});

  final String method;
  final Map<String, String> headers;
}
