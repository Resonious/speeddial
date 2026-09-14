import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_daemon/src/mcp/built_in_mcp_server.dart';
import 'package:speeddial_daemon/src/mcp/mcp_proxy.dart';
import 'package:speeddial_daemon/src/store/daemon_store.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:test/test.dart';

void main() {
  for (final bool stallConnection in <bool>[true, false]) {
    test(
      'stalled ${stallConnection ? 'connection' : 'listing'} preserves healthy '
      'and built-in tools, cleans up late results, and permits retry',
      () async {
        final Completer<McpUpstreamConnection> connecting =
            Completer<McpUpstreamConnection>();
        final Completer<List<Map<String, Object?>>> listing =
            Completer<List<Map<String, Object?>>>();
        final _FakeConnection healthy = _FakeConnection(
          'linear',
          <Map<String, Object?>>[_tool('save_issue', 'Update issue.')],
        );
        final _FakeConnection slow = _FakeConnection(
          'slow',
          <Map<String, Object?>>[_tool('old', 'Old tool.')],
          listing: stallConnection ? null : listing.future,
        );
        final _FakeConnection recovered = _FakeConnection(
          'recovered',
          <Map<String, Object?>>[_tool('new', 'New tool.')],
        );
        int attempts = 0;
        final McpProxySession proxy = McpProxySession(
          servers: <StoredMcpServer>[
            _stored(id: 'linear', name: 'Linear', transport: McpTransport.http),
            _stored(id: 'slow', name: 'Slow', transport: McpTransport.http),
          ],
          cwd: Directory.current.path,
          discoveryTimeout: const Duration(milliseconds: 30),
          connector: (StoredMcpServer server, String cwd) async {
            if (server.profile.id == 'linear') return healthy;
            attempts++;
            if (attempts > 1) return recovered;
            return stallConnection ? connecting.future : slow;
          },
        );
        addTearDown(proxy.close);
        final BuiltInMcpServer bridge = BuiltInMcpServer(
          sessionId: 'session',
          cwd: Directory.current.path,
          daemonCall: (String method, Map<String, Object?> params) async {
            final McpProxyListResult result = await proxy.listTools();
            return <String, Object?>{
              'tools': result.tools,
              'warnings': result.warnings,
            };
          },
        );
        final Map<String, Object?>? response = await bridge
            .handle(<String, Object?>{
              'jsonrpc': '2.0',
              'id': 1,
              'method': 'tools/list',
            })
            .timeout(const Duration(seconds: 2));
        final Map result = response!['result']! as Map;
        expect(
          (result['tools']! as List).map((dynamic tool) => tool['name']),
          containsAll(<String>['search_sessions', 'Linear__save_issue']),
        );
        expect((result['_meta']! as Map)['speeddial/warnings'], <Matcher>[
          startsWith('Slow: MCP discovery timed out'),
        ]);
        expect(
          await proxy.callTool('Linear__save_issue', <String, Object?>{}),
          containsPair('server', 'linear'),
        );
        expect(healthy.closed, isFalse);
        if (!stallConnection) expect(slow.closed, isTrue);

        // Retry before the original operation finishes: its late completion
        // must neither evict the recovered connection nor restore old routes.
        final McpProxyListResult retried = await proxy.listTools();
        expect(retried.warnings, isEmpty);
        expect(retried.tools.map((tool) => tool['name']), <String>[
          'Linear__save_issue',
          'Slow__new',
        ]);
        connecting.complete(slow);
        listing.complete(slow.tools);
        await Future<void>.delayed(Duration.zero);
        expect(slow.closed, isTrue);
        expect(recovered.closed, isFalse);
        expect(
          await proxy.callTool('Slow__new', <String, Object?>{}),
          containsPair('server', 'recovered'),
        );
        await proxy.listTools();
        expect(attempts, 2);
      },
    );
  }

  test('closing during connection discards the late connection', () async {
    final Completer<McpUpstreamConnection> connecting =
        Completer<McpUpstreamConnection>();
    final _FakeConnection connection = _FakeConnection(
      'late',
      <Map<String, Object?>>[],
    );
    final McpProxySession proxy = McpProxySession(
      servers: <StoredMcpServer>[
        _stored(id: 'late', name: 'Late', transport: McpTransport.http),
      ],
      cwd: Directory.current.path,
      connector: (StoredMcpServer server, String cwd) => connecting.future,
    );
    final Future<McpProxyListResult> listing = proxy.listTools();
    final Future<void> checked = expectLater(listing, throwsStateError);
    await proxy.close();
    connecting.complete(connection);
    await checked;
    expect(connection.closed, isTrue);
  });

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

  test('strips lookaround pattern constraints and warns, leaving clean schemas', () async {
    final _FakeConnection
    upstream = _FakeConnection('upstream', <Map<String, Object?>>[
      <String, Object?>{
        'name': 'create-contact',
        'description': 'Create a contact.',
        'inputSchema': <String, Object?>{
          'type': 'object',
          'required': <String>['email', 'names'],
          'properties': <String, Object?>{
            'email': <String, Object?>{
              'type': 'string',
              'format': 'email',
              'pattern':
                  "^(?!\\.)(?!.*\\.\\.)([A-Za-z0-9_'+\\-\\.]*)@example\\.com\$",
            },
            'names': <String, Object?>{
              'type': 'array',
              'items': <String, Object?>{
                'type': 'string',
                'pattern': '^a(?=b)\$',
                'minLength': 1,
              },
            },
            'label': <String, Object?>{
              'type': 'string',
              'pattern': '^[a-z]+\$',
            },
          },
        },
      },
    ]);
    final StoredMcpServer server = _stored(
      id: 'upstream',
      name: 'Resend.com',
      transport: McpTransport.http,
    );
    final McpProxySession proxy = McpProxySession(
      servers: <StoredMcpServer>[server],
      cwd: Directory.current.path,
      connector: (StoredMcpServer s, String cwd) async => upstream,
    );
    addTearDown(proxy.close);

    final McpProxyListResult listed = await proxy.listTools();
    final Map<String, Object?> tool = listed.tools.single;
    expect(tool['name'], 'Resend_com__create-contact');
    expect(tool['description'], 'MCP server "Resend.com". Create a contact.');
    final Map<String, Object?> properties = (tool['inputSchema']! as Map)
        .cast<String, Object?>();
    final Map<String, Object?> propertiesMap =
        (properties['properties']! as Map).cast<String, Object?>();
    final Map<String, Object?> emailProp = (propertiesMap['email']! as Map)
        .cast<String, Object?>();
    expect(emailProp, isNot(contains('pattern')));
    expect(emailProp['format'], 'email');
    expect(emailProp['type'], 'string');
    final Map<String, Object?> names = (propertiesMap['names']! as Map)
        .cast<String, Object?>();
    final Map<String, Object?> items = (names['items']! as Map)
        .cast<String, Object?>();
    expect(items, isNot(contains('pattern')));
    expect(items['minLength'], 1);
    final Map<String, Object?> label = (propertiesMap['label']! as Map)
        .cast<String, Object?>();
    expect(label['pattern'], '^[a-z]+\$');
    expect(listed.warnings, <String>[
      'Resend.com: removed 2 JSON-schema pattern constraint(s) using regex '
          'lookaround unsupported by model providers',
    ]);

    await proxy.callTool('Resend_com__create-contact', <String, Object?>{
      'email': 'a@example.com',
    });
    expect(upstream.calls.single.name, 'create-contact');
  });

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
  _FakeConnection(this.label, this.tools, {this.listing});

  final Future<List<Map<String, Object?>>>? listing;

  final String label;
  final List<Map<String, Object?>> tools;
  final List<({String name, Map<String, Object?> arguments})> calls =
      <({String name, Map<String, Object?> arguments})>[];
  bool closed = false;

  @override
  Future<List<Map<String, Object?>>> listTools() async =>
      listing == null ? tools : await listing!;

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
