// Deterministic Ante JSONL server used by AnteClient and engine tests.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

const String _sessionId = 'ses_01M0H000000000000000000000';
String _model = 'fake-model';
String _effort = 'medium';
String _provider = 'fake-provider';
int _eventCounter = 0;
Future<void> _writeQueue = Future<void>.value();
({String parent, String turnId})? _pendingTurn;

Future<void> main(List<String> args) async {
  if (args.firstOrNull == 'catalog') {
    stdout.writeln(
      jsonEncode(<String, Object?>{
        'providers': <Object?>[
          <String, Object?>{
            'id': 'fake-provider',
            'display_name': 'Fake Provider',
            'preferred_models': <Object?>[
              <String, Object?>{
                'id': 'fake-model',
                'description': 'Fake model',
              },
              <String, Object?>{
                'id': 'fake-large',
                'description': 'Large fake model',
              },
            ],
          },
        ],
      }),
    );
    return;
  }

  final Stream<String> lines = utf8.decoder
      .bind(stdin)
      .transform(const LineSplitter());
  await for (final String line in lines) {
    if (line.trim().isEmpty) continue;
    final Object? decoded = jsonDecode(line);
    if (decoded is! Map) continue;
    await _dispatch(Map<String, Object?>.from(decoded));
  }
}

Future<void> _dispatch(Map<String, Object?> message) async {
  final String parent = message['id'] as String? ?? '';
  if (!_isCurrentOpId(parent)) {
    throw FormatException('Invalid or stale Ante operation id: $parent');
  }
  final Object? rawOp = message['op'];
  if (rawOp is String) {
    switch (rawOp) {
      case 'Interrupt':
        final pending = _pendingTurn;
        if (pending != null) {
          _pendingTurn = null;
          await _event(<String, Object?>{
            'TurnEnd': <String, Object?>{
              'turn_id': pending.turnId,
              'status': <String, Object?>{
                'Interrupted': <String, Object?>{'reason': 'cancelled'},
              },
              'steps': 1,
            },
          }, pending.parent);
        }
      case 'Shutdown':
        await _event(<String, Object?>{
          'SessionEnd': <String, Object?>{
            'session_id': _sessionId,
            'reason': 'Shutdown',
            'usage': <String, Object?>{
              'input_tokens': 120,
              'output_tokens': 30,
            },
          },
        }, parent);
        await _event('Goodbye', parent);
        await _writeQueue;
        exit(0);
    }
    return;
  }
  if (rawOp is! Map || rawOp.isEmpty) return;
  final MapEntry<Object?, Object?> variant = rawOp.entries.first;
  final String type = variant.key as String;
  final Map<String, Object?> value = variant.value is Map
      ? Map<String, Object?>.from(variant.value as Map)
      : <String, Object?>{};
  switch (type) {
    case 'StartSession':
      _model = value['model'] as String? ?? 'fake-model';
      _provider = value['provider'] as String? ?? 'fake-provider';
      await _sessionStart(parent);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await _captureMcpHome();
      await _extensions(parent);
    case 'ResumeSession':
      await _sessionStart(parent);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await _captureMcpHome();
      await _extensions(parent);
      await _event(<String, Object?>{'MessageDelta': 'replayed'}, 'op_old');
      await _event(<String, Object?>{
        'TurnEnd': <String, Object?>{
          'turn_id': 'op_old',
          'status': 'Completed',
          'steps': 1,
        },
      }, 'op_old');
    case 'UpdateSession':
      final Map<String, Object?> model = value['model'] is Map
          ? Map<String, Object?>.from(value['model'] as Map)
          : <String, Object?>{};
      _model = model['id'] as String? ?? _model;
      _effort = model['effort'] as String? ?? _effort;
      await _event(<String, Object?>{
        'SessionUpdated': _sessionPayload(),
      }, parent);
    case 'UserInput':
      final String text = variant.value as String? ?? '';
      await _runTurn(parent, text);
    case 'ApprovalResponse':
      final pending = _pendingTurn;
      if (pending == null) return;
      _pendingTurn = null;
      await _finishApprovedTurn(pending.parent, pending.turnId);
  }
}

Future<void> _captureMcpHome() async {
  final String? reportPath = Platform.environment['FAKE_ANTE_PROFILE_REPORT'];
  if (reportPath == null || reportPath.isEmpty) return;
  final String? anteHome = Platform.environment['ANTE_HOME'];
  if (anteHome == null) {
    throw StateError('Ante MCP home environment is missing.');
  }
  final File settingsFile = File(p.join(anteHome, 'settings.json'));
  await File(reportPath).writeAsString(await settingsFile.readAsString());
  await File('$reportPath.home').writeAsString(anteHome);
}

Future<void> _captureUserInput(String text) async {
  final String? reportPath =
      Platform.environment['FAKE_ANTE_USER_INPUT_REPORT'];
  if (reportPath == null || reportPath.isEmpty) return;
  await File(reportPath).writeAsString(text);
}

bool _isCurrentOpId(String id) {
  const String alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  if (!id.startsWith('op_') || id.length != 29) return false;
  final String encoded = id.substring(3);
  var timestamp = 0;
  for (var i = 0; i < encoded.length; i++) {
    final int digit = alphabet.indexOf(encoded[i]);
    if (digit < 0 || (i == 0 && digit > 7)) return false;
    if (i < 10) timestamp = timestamp * 32 + digit;
  }
  return (DateTime.now().millisecondsSinceEpoch - timestamp).abs() <
      const Duration(minutes: 1).inMilliseconds;
}

Future<void> _sessionStart(String parent) {
  return _event(<String, Object?>{'SessionStart': _sessionPayload()}, parent);
}

Map<String, Object?> _sessionPayload() => <String, Object?>{
  'model': <String, Object?>{
    'id': _model,
    'description': 'Fake model',
    'context_limit': 200000,
    'effort': _effort,
    'support_vision': false,
    'weight_class': 'middle',
  },
  'provider': <String, Object?>{
    'id': _provider,
    'display_name': 'Fake Provider',
    'base_url': 'https://example.invalid/v1',
  },
  'session_id': _sessionId,
  'cwd': Directory.current.path,
  'permission_mode': 'strict',
};

Future<void> _extensions(String parent) {
  return _event(<String, Object?>{
    'ExtensionRefreshed': <String, Object?>{
      'session_id': _sessionId,
      'skills': <Object?>[
        <String, Object?>{'name': 'commit', 'description': 'Commit changes'},
      ],
      'subagents': <Object?>[
        <String, Object?>{'name': 'explore', 'description': 'Explore code'},
      ],
      'mcp_servers': <Object?>[
        <String, Object?>{
          'name': 'filesystem',
          'tools': <Object?>[
            <String, Object?>{'name': 'read_file'},
          ],
        },
      ],
    },
  }, parent);
}

Future<void> _runTurn(String parent, String text) async {
  await _captureUserInput(text);
  await _event(<String, Object?>{'UserInput': text}, parent);
  await _event(<String, Object?>{
    'TurnStart': <String, Object?>{'turn_id': parent},
  }, parent);
  if (text == 'cancel') {
    _pendingTurn = (parent: parent, turnId: parent);
    return;
  }
  if (text == 'error') {
    await _event(<String, Object?>{
      'TurnEnd': <String, Object?>{
        'turn_id': parent,
        'status': <String, Object?>{
          'Error': <String, Object?>{
            'kind': 'provider',
            'headline': 'Provider failed',
            'details': <String>['bad credentials'],
          },
        },
        'steps': 1,
      },
    }, parent);
    return;
  }
  await _event(<String, Object?>{'ThinkingDelta': 'Considering'}, parent);
  await _event(<String, Object?>{'Thinking': 'Considering'}, parent);
  await _event(<String, Object?>{'MessageDelta': 'Hello '}, parent);
  await _event(<String, Object?>{
    'ToolStart': <String, Object?>{
      'id': 'tool-1',
      'name': 'Read',
      'args': <String, Object?>{'file_path': '/tmp/example.dart'},
    },
  }, parent);
  await _event(<String, Object?>{
    'ToolUpdate': <String, Object?>{
      'tool_use_id': 'tool-1',
      'seq': 0,
      'message': 'Reading file',
    },
  }, parent);
  _pendingTurn = (parent: parent, turnId: parent);
  await _event(<String, Object?>{
    'TurnPause': <String, Object?>{
      'turn_id': parent,
      'reason': <String, Object?>{
        'Approval': <String, Object?>{
          'tools': <Object?>[
            <String, Object?>{
              'id': 'tool-1',
              'name': 'Read',
              'args': <String, Object?>{'file_path': '/tmp/example.dart'},
            },
          ],
          'message': 'Allow reading the file?',
        },
      },
    },
  }, parent);
}

Future<void> _finishApprovedTurn(String parent, String turnId) async {
  await _event(<String, Object?>{
    'TurnResume': <String, Object?>{'turn_id': turnId},
  }, parent);
  await _event(<String, Object?>{
    'ToolEnd': <String, Object?>{
      'tool_use_id': 'tool-1',
      'status': 'Completed',
      'result_json': <String, Object?>{'content': 'file contents'},
      'is_error': false,
    },
  }, parent);
  await _event(<String, Object?>{'MessageDelta': 'world'}, parent);
  await _event(<String, Object?>{'AgentMessage': 'Hello world'}, parent);
  await _event(<String, Object?>{
    'UsageUpdate': <String, Object?>{
      'usage': <String, Object?>{
        'input_tokens': 120,
        'output_tokens': 30,
        'cache_read_tokens': 80,
        'cache_creation_tokens': 5,
      },
      'context': <String, Object?>{'used_tokens': 4096, 'limit_tokens': 200000},
    },
  }, parent);
  await _event(<String, Object?>{'Info': 'Checking work'}, parent);
  await _event(<String, Object?>{
    'InfoBlockStart': <String, Object?>{
      'id': 'warmup',
      'header': 'Warming extensions',
      'loading': true,
    },
  }, parent);
  await _event(<String, Object?>{
    'InfoBlockAppend': <String, Object?>{'id': 'warmup', 'detail': 'Ready'},
  }, parent);
  await _event(<String, Object?>{
    'TurnEnd': <String, Object?>{
      'turn_id': turnId,
      'status': 'Completed',
      'steps': 1,
    },
  }, parent);
}

Future<void> _event(Object event, String parent) {
  _eventCounter++;
  final String suffix = _eventCounter.toString().padLeft(26, '0');
  final String line = jsonEncode(<String, Object?>{
    'timestamp': DateTime.now().toUtc().toIso8601String(),
    'id': 'evt_$suffix',
    'event': event,
    'parent': parent,
  });
  final Future<void> write = _writeQueue.then((_) async {
    stdout.writeln(line);
    await stdout.flush();
  });
  _writeQueue = write.catchError((Object _) {});
  return write;
}
