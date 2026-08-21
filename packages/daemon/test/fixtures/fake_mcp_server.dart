import 'dart:async';
import 'dart:convert';
import 'dart:io';

Map<String, Object?>? _pendingToolsRequest;
Map<String, Object?>? _root;

Future<void> main() async {
  await for (final String line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) continue;
    final Map<String, Object?> message = (jsonDecode(line) as Map)
        .cast<String, Object?>();
    final Object? id = message['id'];
    final String? method = message['method'] as String?;
    switch (method) {
      case 'initialize':
        _write(<String, Object?>{
          'jsonrpc': '2.0',
          'id': id,
          'result': <String, Object?>{
            'protocolVersion': '2025-11-25',
            'capabilities': <String, Object?>{
              'tools': <String, Object?>{'listChanged': false},
            },
            'serverInfo': <String, Object?>{
              'name': 'fake-upstream',
              'version': '1.0.0',
            },
          },
        });
      case 'notifications/initialized':
        _write(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 'roots-check',
          'method': 'roots/list',
          'params': const <String, Object?>{},
        });
      case 'tools/list':
        final Map<String, Object?> params = switch (message['params']) {
          final Map value => value.cast<String, Object?>(),
          _ => const <String, Object?>{},
        };
        if (params['cursor'] == 'page-2') {
          _write(<String, Object?>{
            'jsonrpc': '2.0',
            'id': id,
            'result': <String, Object?>{
              'tools': <Object?>[
                _tool('environment', 'Reports process context.'),
              ],
            },
          });
        } else if (_root == null) {
          _pendingToolsRequest = message;
        } else {
          _writeFirstToolsPage(message);
        }
      case 'tools/call':
        final Map<String, Object?> params = (message['params']! as Map)
            .cast<String, Object?>();
        _write(<String, Object?>{
          'jsonrpc': '2.0',
          'id': id,
          'result': <String, Object?>{
            'content': <Object?>[
              <String, Object?>{
                'type': 'text',
                'text': jsonEncode(<String, Object?>{
                  'name': params['name'],
                  'arguments': params['arguments'],
                  'token': Platform.environment['FAKE_TOKEN'],
                  'cwd': Directory.current.path,
                  'root': _root,
                }),
              },
            ],
            'isError': false,
          },
        });
      case null:
        if (id == 'roots-check' && message['result'] is Map) {
          final Map<String, Object?> result = (message['result']! as Map)
              .cast<String, Object?>();
          final List<Object?> roots = result['roots']! as List<Object?>;
          _root = (roots.single! as Map).cast<String, Object?>();
          final Map<String, Object?>? pending = _pendingToolsRequest;
          _pendingToolsRequest = null;
          if (pending != null) _writeFirstToolsPage(pending);
        }
    }
  }
}

void _writeFirstToolsPage(Map<String, Object?> request) {
  _write(<String, Object?>{
    'jsonrpc': '2.0',
    'id': request['id'],
    'result': <String, Object?>{
      'tools': <Object?>[_tool('echo', 'Echoes its arguments.')],
      'nextCursor': 'page-2',
    },
  });
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

void _write(Map<String, Object?> message) {
  stdout.writeln(jsonEncode(message));
}
