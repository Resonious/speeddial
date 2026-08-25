@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_daemon/src/mcp/built_in_mcp_server.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late List<({String method, Map<String, Object?> params})> calls;
  late BuiltInMcpServer server;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('built_in_mcp_test');
    calls = <({String method, Map<String, Object?> params})>[];
    server = BuiltInMcpServer(
      sessionId: 'current-session',
      cwd: tempDir.path,
      daemonCall: (String method, Map<String, Object?> params) async {
        calls.add((method: method, params: params));
        return switch (method) {
          'internal.mcpSearchProjects' => <String, Object?>{
            'projects': <Object?>[
              <String, Object?>{'id': 'p1', 'name': 'Demo'},
            ],
          },
          'internal.mcpSearchSessions' => <String, Object?>{
            'sessions': <Object?>[
              <String, Object?>{
                'id': 'other-session',
                'title': 'Useful',
                'archived': true,
              },
            ],
          },
          'internal.mcpArchiveSession' => <String, Object?>{
            'session': <String, Object?>{
              'id': params['sessionId'],
              'title': 'Useful',
              'archived': params['archived'],
            },
          },
          'internal.mcpListTools' => <String, Object?>{
            'tools': <Object?>[
              <String, Object?>{
                'name': 'workspace__read',
                'description': 'Read a workspace file.',
                'inputSchema': <String, Object?>{'type': 'object'},
              },
            ],
            'warnings': <String>['offline: connection refused'],
          },
          'internal.mcpCallTool' => <String, Object?>{
            'content': <Object?>[
              <String, Object?>{'type': 'text', 'text': 'proxied'},
            ],
            'structuredContent': params['arguments'],
            'isError': false,
          },
          _ => <String, Object?>{'ok': true},
        };
      },
    );
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } on Object {
      // Cleanup failure is not a test failure.
    }
  });

  Future<Map<String, Object?>> request(
    int id,
    String method, [
    Map<String, Object?> params = const <String, Object?>{},
  ]) async {
    return (await server.handle(<String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    }))!;
  }

  test('initialize and tools/list advertise all built-in tools', () async {
    final Map<String, Object?> initialized = await request(
      1,
      'initialize',
      <String, Object?>{'protocolVersion': '2025-11-25'},
    );
    final result = (initialized['result'] as Map).cast<String, Object?>();
    expect(result['protocolVersion'], '2025-11-25');
    expect(result['capabilities'], contains('tools'));

    final Map<String, Object?> listed = await request(2, 'tools/list');
    final listedResult = (listed['result'] as Map).cast<String, Object?>();
    final tools = (listedResult['tools'] as List<Object?>)
        .cast<Map<String, Object?>>();
    expect(tools.map((Map<String, Object?> tool) => tool['name']), <String>[
      'search_projects',
      'search_sessions',
      'archive_session',
      'unarchive_session',
      'display_image',
      'workspace__read',
    ]);
    final Map<String, Object?> archiveTool = tools.singleWhere(
      (Map<String, Object?> tool) => tool['name'] == 'archive_session',
    );
    expect(archiveTool['annotations'], containsPair('destructiveHint', true));
    expect(archiveTool['annotations'], containsPair('idempotentHint', true));
    expect(
      ((listedResult['_meta']! as Map)['speeddial/warnings']! as List).single,
      'offline: connection refused',
    );
  });

  test('search tools forward filters and return daemon results', () async {
    final Map<String, Object?> projects = await request(
      1,
      'tools/call',
      <String, Object?>{
        'name': 'search_projects',
        'arguments': <String, Object?>{'query': 'dem'},
      },
    );
    final projectResult = (projects['result'] as Map).cast<String, Object?>();
    expect(jsonEncode(projectResult), contains('Demo'));

    final Map<String, Object?> sessions = await request(
      2,
      'tools/call',
      <String, Object?>{
        'name': 'search_sessions',
        'arguments': <String, Object?>{
          'query': 'use',
          'projectId': 'p1',
          'includeArchived': true,
          'limit': 7,
        },
      },
    );
    final sessionResult = (sessions['result'] as Map).cast<String, Object?>();
    expect(jsonEncode(sessionResult), contains('other-session'));
    expect(calls, hasLength(2));
    expect(calls.first.method, 'internal.mcpSearchProjects');
    expect(calls.first.params, <String, Object?>{'query': 'dem'});
    expect(calls.last.method, 'internal.mcpSearchSessions');
    expect(calls.last.params, <String, Object?>{
      'query': 'use',
      'projectId': 'p1',
      'includeArchived': true,
      'limit': 7,
    });
  });

  test('archive_session forwards the selected session id', () async {
    final Map<String, Object?> response = await request(
      1,
      'tools/call',
      <String, Object?>{
        'name': 'archive_session',
        'arguments': <String, Object?>{'sessionId': 'other-session'},
      },
    );
    final Map<String, Object?> result = (response['result']! as Map)
        .cast<String, Object?>();
    expect(result['isError'], isFalse);
    final List<Object?> content = result['content']! as List<Object?>;
    expect((content.single! as Map)['text'], contains('"archived": true'));
    expect(calls.single.method, 'internal.mcpArchiveSession');
    expect(calls.single.params, <String, Object?>{
      'sessionId': 'other-session',
      'archived': true,
    });
  });

  test('unarchive_session forwards the selected session id', () async {
    final Map<String, Object?> response = await request(
      1,
      'tools/call',
      <String, Object?>{
        'name': 'unarchive_session',
        'arguments': <String, Object?>{'sessionId': 'other-session'},
      },
    );
    final Map<String, Object?> result = (response['result']! as Map)
        .cast<String, Object?>();
    expect(result['isError'], isFalse);
    final List<Object?> content = result['content']! as List<Object?>;
    expect((content.single! as Map)['text'], contains('"archived": false'));
    expect(calls.single.method, 'internal.mcpArchiveSession');
    expect(calls.single.params, <String, Object?>{
      'sessionId': 'other-session',
      'archived': false,
    });
  });

  test('managed tool calls route through the daemon bridge', () async {
    final Map<String, Object?> response = await request(
      1,
      'tools/call',
      <String, Object?>{
        'name': 'workspace__read',
        'arguments': <String, Object?>{'path': 'README'},
      },
    );
    final Map<String, Object?> result = (response['result']! as Map)
        .cast<String, Object?>();
    expect(result['structuredContent'], <String, Object?>{'path': 'README'});
    expect(calls.single.method, 'internal.mcpCallTool');
    expect(calls.single.params, <String, Object?>{
      'name': 'workspace__read',
      'arguments': <String, Object?>{'path': 'README'},
    });
  });

  test('display_image reads a confined file and returns MCP image content', () async {
    const String png =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';
    final File image = File(p.join(tempDir.path, 'pixel.png'))
      ..writeAsBytesSync(base64Decode(png));

    final Map<String, Object?> response = await request(
      1,
      'tools/call',
      <String, Object?>{
        'name': 'display_image',
        'arguments': <String, Object?>{'path': p.basename(image.path)},
      },
    );
    final result = (response['result'] as Map).cast<String, Object?>();
    expect(result['isError'], isFalse);
    final content = (result['content'] as List<Object?>)
        .cast<Map<String, Object?>>();
    expect(content.first['type'], 'image');
    expect(content.first['data'], png);
    expect(content.first['mimeType'], 'image/png');
    expect(calls.single.method, 'internal.mcpDisplayImage');
    expect(calls.single.params['name'], 'pixel.png');
    expect(calls.single.params['data'], png);
  });

  test('display_image rejects paths outside the session cwd', () async {
    final Directory cwd = Directory(p.join(tempDir.path, 'cwd'))..createSync();
    final File outside = File(p.join(tempDir.path, 'outside.png'))
      ..writeAsBytesSync(const <int>[1, 2, 3]);
    server = BuiltInMcpServer(
      sessionId: 'current-session',
      cwd: cwd.path,
      daemonCall: (String method, Map<String, Object?> params) async =>
          <String, Object?>{},
    );

    final Map<String, Object?> response = await request(
      1,
      'tools/call',
      <String, Object?>{
        'name': 'display_image',
        'arguments': <String, Object?>{'path': outside.path},
      },
    );
    final result = (response['result'] as Map).cast<String, Object?>();
    expect(result['isError'], isTrue);
    expect(
      jsonEncode(result),
      contains('escapes the session working directory'),
    );
  });
}
