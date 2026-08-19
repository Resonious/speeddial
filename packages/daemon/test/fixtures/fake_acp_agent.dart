// A minimal fake ACP v1 agent used by the ACP client tests.
//
// Talks newline-delimited JSON-RPC 2.0 over stdio. Behavior:
//
//   * `initialize` answers with protocolVersion 1 and capabilities. The
//     `loadSession` capability is advertised unless `<cwd>/agent.no_load_session`
//     exists at initialize time.
//   * `authenticate` answers with `{}`.
//   * `session/new` answers with session id `s1` and a `configOptions` list
//     carrying the model select option (omitted when `<cwd>/agent.no_model`
//     exists at initialize time) and the thinking select option (omitted
//     when `<cwd>/agent.no_thinking` exists at initialize time).
//   * `session/load` answers with the same `configOptions` for any session
//     id, unless `<cwd>/agent.load_fails` exists (answers with error
//     -32000).
//   * `session/set_config_option` with configId 'model' accepts ANY
//     non-empty string (lenient, like omp's fuzzy model ids), updates the
//     model option's currentValue, and records it to `<cwd>/agent.model`
//     (outside git trees); configId 'thinking' accepts only the advertised
//     levels and records to `<cwd>/agent.thinking`; unknown config ids or
//     values answer with error -32602. Both answer with the full updated
//     `configOptions` list.
//   * `session/set_mode` answers with `{}`.
//   * `session/prompt` runs a scripted turn. The turn text selects behavior:
//       - normal text: agent_message_chunk x2, tool_call, fs/read_text_file,
//         tool_call_update (completed), plan, session/request_permission
//         (blocking), usage_update, then `end_turn`.
//       - "cancel": sends nothing and leaves the turn pending; the
//         `session/cancel` notification resolves it with `cancelled`.
//       - "weird": emits an unknown update variant (must be dropped by the
//         client), then usage_update and `end_turn`.
//       - "die": parks a session/request_permission, then exits the process
//         when `<cwd>/agent.turn.die` appears (mid-request agent death).
//       - "hang": sends nothing and never resolves the turn.
//   * `session/cancel` (notification) resolves any pending prompt with
//     `cancelled`.
//   * the `FAKE_ACP_TARGET` environment variable is the target file path used
//     by the tool_call locations / fs/read requests (defaults to
//     `$cwd/example.txt`).
//
// Run standalone: `FAKE_ACP_TARGET=/path dart test/fixtures/fake_acp_agent.dart`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

const String sessionId = 's1';

/// The thinking level values the fake advertises, in order.
const List<String> _thinkingValues = <String>['off', 'auto', 'low', 'high', 'max'];

/// The fake's in-memory current thinking level, reported as the thinking
/// config option's currentValue and updated by `session/set_config_option`.
String _thinkingCurrent = 'auto';

/// The fake's in-memory current model, reported as the model config
/// option's currentValue and updated by `session/set_config_option`.
String _modelCurrent = 'fake-fast';

/// Whether the model config option is advertised; set once at `initialize`
/// from the `<cwd>/agent.no_model` marker.
bool _modelEnabled = true;

/// Whether the thinking config option is advertised; set once at
/// `initialize` from the `<cwd>/agent.no_thinking` marker.
bool _thinkingEnabled = true;

final Map<int, Completer<Map<String, Object?>>> _agentRequests =
    <int, Completer<Map<String, Object?>>>{};
final Map<Object, bool> _pendingPrompts = <Object, bool>{};
Future<void> _writeQueue = Future<void>.value();
int _nextId = 1;

void main() {
  // The target path travels via the environment: argv is unreliable across
  // Dart VM wrappers (flags like --executable_name can be spliced in).
  final targetPath = Platform.environment['FAKE_ACP_TARGET'] ??
      '${Directory.current.path}/example.txt';
  unawaited(_serve(targetPath));
}

Future<void> _serve(String targetPath) async {
  final lines = utf8.decoder.bind(stdin).transform(const LineSplitter());
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      continue;
    }
    if (decoded is! Map) continue;
    unawaited(
      _dispatch(decoded.cast<String, Object?>(), targetPath).catchError(
        (Object error, StackTrace stack) {
          stderr.writeln('fake agent error: $error\n$stack');
        },
      ),
    );
  }
}

/// Serializes stdout writes so JSON lines never interleave.
Future<void> _send(Object message) {
  final json = jsonEncode(message);
  final future = _writeQueue
      .then((_) => stdout.writeln(json))
      .catchError((Object _) {});
  _writeQueue = future;
  return future;
}

Future<void> _sendResponse(Object id, Map<String, Object?> result) {
  return _send(<String, Object?>{
    'jsonrpc': '2.0',
    'id': id,
    'result': result,
  });
}

Future<void> _sendError(Object id, int code, String message) {
  return _send(<String, Object?>{
    'jsonrpc': '2.0',
    'id': id,
    'error': <String, Object?>{'code': code, 'message': message},
  });
}

Future<void> _sendUpdate(Map<String, Object?> update) {
  return _send(<String, Object?>{
    'jsonrpc': '2.0',
    'method': 'session/update',
    'params': <String, Object?>{'sessionId': sessionId, 'update': update},
  });
}

/// Sends an agent-to-client request and awaits the client's response.
Future<Map<String, Object?>> _request(
  String method,
  Map<String, Object?> params,
) async {
  final id = _nextId++;
  final completer = Completer<Map<String, Object?>>();
  _agentRequests[id] = completer;
  await _send(<String, Object?>{
    'jsonrpc': '2.0',
    'id': id,
    'method': method,
    'params': params,
  });
  return completer.future;
}

void _resolvePrompt(Object promptId, String stopReason) {
  if (_pendingPrompts[promptId] == true) return;
  _pendingPrompts[promptId] = true;
  unawaited(_sendResponse(promptId, <String, Object?>{'stopReason': stopReason}));
}

String _promptText(Map<String, Object?> params) {
  final blocks = params['prompt'];
  if (blocks is List) {
    for (final block in blocks) {
      if (block is Map && block['type'] == 'text') {
        final text = block['text'];
        if (text is String) return text;
      }
    }
  }
  return '';
}

Future<void> _dispatch(Map<String, Object?> message, String targetPath) async {
  final method = message['method'];
  final rawId = message['id'];
  final id = rawId is num ? rawId.toInt() : null;

  // Response to one of our agent-to-client requests.
  if (method == null && id != null) {
    final completer = _agentRequests.remove(id);
    if (completer == null) return; // Stale response.
    final error = message['error'];
    if (error != null) {
      completer.completeError(
        StateError('Agent request $id failed: ${jsonEncode(error)}'),
      );
    } else {
      final result = message['result'];
      completer.complete(
        result is Map ? result.cast<String, Object?>() : const <String, Object?>{},
      );
    }
    return;
  }

  switch (method) {
    case 'initialize':
      _modelEnabled =
          !File('${Directory.current.path}/agent.no_model').existsSync();
      _thinkingEnabled =
          !File('${Directory.current.path}/agent.no_thinking').existsSync();
      await _sendResponse(id!, <String, Object?>{
        'protocolVersion': 1,
        'agentCapabilities': <String, Object?>{
          'loadSession': !File(
                  '${Directory.current.path}/agent.no_load_session')
              .existsSync(),
          'promptCapabilities': <String, Object?>{
            'image': false,
            'audio': false,
            'embeddedContext': false,
          },
          'mcpCapabilities': <String, Object?>{'http': false, 'sse': false},
          'sessionCapabilities': <String, Object?>{},
          'auth': <String, Object?>{},
        },
        'authMethods': <Object?>[],
        'agentInfo': <String, Object?>{
          'name': 'fake-acp-agent',
          'title': 'Fake ACP Agent',
          'version': '0.1.0',
        },
      });
    case 'authenticate':
      await _sendResponse(id!, const <String, Object?>{});
    case 'session/new':
      await _sendResponse(id!, <String, Object?>{
        'sessionId': sessionId,
        'modes': <String, Object?>{
          'currentModeId': 'build',
          'availableModes': <Object?>[
            <String, Object?>{'id': 'build', 'name': 'Build'},
            <String, Object?>{'id': 'plan', 'name': 'Plan'},
          ],
        },
        'configOptions': _configOptions(),
      });
    case 'session/load':
      // The fake keeps no state of its own; like a real agent reloading its
      // on-disk session, any id is accepted unless the test planted the
      // failure signal.
      if (File('${Directory.current.path}/agent.load_fails').existsSync()) {
        await _sendError(id!, -32000, 'Unknown session');
      } else {
        await _sendResponse(id!, <String, Object?>{
          'configOptions': _configOptions(),
        });
      }
    case 'session/set_config_option':
      final configParams = params(message);
      final configId = configParams['configId'];
      final value = configParams['value'];
      if (configId == 'model' &&
          _modelEnabled &&
          value is String &&
          value.isNotEmpty) {
        // Model ids are deliberately lenient (omp accepts fuzzy ids); any
        // non-empty string is applied.
        _modelCurrent = value;
        final cwd = Directory.current.path;
        if (!Directory(p.join(cwd, '.git')).existsSync() &&
            !File(p.join(cwd, '.git')).existsSync()) {
          // Recorded so tests can observe that the agent really applied the
          // value (e.g. a resumption reapplying a persisted choice).
          File(p.join(cwd, 'agent.model')).writeAsStringSync(_modelCurrent);
        }
        await _sendResponse(id!, <String, Object?>{
          'configOptions': _configOptions(),
        });
      } else if (configId == 'thinking' &&
          _thinkingEnabled &&
          value is String &&
          _thinkingValues.contains(value)) {
        _thinkingCurrent = value;
        final cwd = Directory.current.path;
        if (!Directory(p.join(cwd, '.git')).existsSync() &&
            !File(p.join(cwd, '.git')).existsSync()) {
          // Recorded so tests can observe that the agent really applied the
          // value (e.g. a resumption reapplying a persisted choice).
          File(p.join(cwd, 'agent.thinking')).writeAsStringSync(_thinkingCurrent);
        }
        await _sendResponse(id!, <String, Object?>{
          'configOptions': _configOptions(),
        });
      } else {
        await _sendError(id!, -32602, 'Unknown config option or value');
      }
    case 'session/set_mode':
      await _sendResponse(id!, const <String, Object?>{});
    case 'session/prompt':
      unawaited(_runTurn(id!, params(message), targetPath));
    case 'session/cancel':
      for (final promptId in _pendingPrompts.keys.toList()) {
        _resolvePrompt(promptId, 'cancelled');
      }
    default:
      if (id != null) {
        await _sendError(id, -32601, 'Method not found: $method');
      }
  }
}

Map<String, Object?> params(Map<String, Object?> message) {
  final raw = message['params'];
  return raw is Map ? raw.cast<String, Object?>() : const <String, Object?>{};
}

/// The config options advertised by `session/new`, `session/load`, and
/// `session/set_config_option`: the model select option unless the
/// `agent.no_model` marker was present at initialize, and the thinking
/// select option unless the `agent.no_thinking` marker was present.
List<Object?> _configOptions() {
  final options = <Object?>[];
  if (_modelEnabled) {
    options.add(<String, Object?>{
      'id': 'model',
      'name': 'Model',
      'category': 'model',
      'type': 'select',
      'currentValue': _modelCurrent,
      'options': <Object?>[
        <String, Object?>{'value': 'fake-fast', 'name': 'Fake Fast'},
        <String, Object?>{'value': 'fake-smart', 'name': 'Fake Smart'},
      ],
    });
  }
  if (_thinkingEnabled) {
    options.add(<String, Object?>{
      'id': 'thinking',
      'name': 'Thinking',
      'category': 'thought_level',
      'type': 'select',
      'currentValue': _thinkingCurrent,
      'options': <Object?>[
        for (final value in _thinkingValues)
          <String, Object?>{
            'value': value,
            'name': value[0].toUpperCase() + value.substring(1),
          },
      ],
    });
  }
  return options;
}

Future<void> _runTurn(
  Object promptId,
  Map<String, Object?> promptParams,
  String targetPath,
) async {
  _pendingPrompts[promptId] = false;
  // Expose the prompt blocks (text/image/resource) as JSON for tests; the
  // file is overwritten on every prompt and lives in the agent's cwd (the
  // session cwd). Never write it into a git working tree: the e2e test runs
  // a session inside its own repo, and a stray file would dirty `git status`.
  final cwd = Directory.current.path;
  if (!Directory(p.join(cwd, '.git')).existsSync() &&
      !File(p.join(cwd, '.git')).existsSync()) {
    File(p.join(cwd, 'agent.last_prompt.json'))
        .writeAsStringSync(jsonEncode(promptParams['prompt']));
  }
  final text = _promptText(promptParams);

  if (text == 'cancel') return; // Left pending; session/cancel resolves it.
  if (text == 'hang') return; // Never resolves; used with dispose().
  if (text == 'die') {
    // Park a permission request at the engine, then wait for the test's kill
    // signal (`<cwd>/agent.turn.die`) and exit mid-request: the engine must
    // expire the parked request and mark the session error. This simulates
    // an agent process dying while a permission is outstanding.
    await _sendUpdate(<String, Object?>{
      'sessionUpdate': 'agent_message_chunk',
      'content': <String, Object?>{
        'type': 'text',
        'text': 'I will inspect the target file.',
      },
      'messageId': 'm1',
    });
    unawaited(
      _request('session/request_permission', <String, Object?>{
        'sessionId': sessionId,
        'toolCall': <String, Object?>{
          'toolCallId': 'tc1',
          'title': 'Read example.txt',
          'kind': 'read',
          'status': 'in_progress',
        },
        'options': <Object?>[
          <String, Object?>{
            'optionId': 'allow',
            'name': 'Allow reading',
            'kind': 'allow_always',
          },
          <String, Object?>{
            'optionId': 'reject',
            'name': 'Reject reading',
            'kind': 'reject_once',
          },
        ],
      }).catchError((Object _) => <String, Object?>{}),
    );
    final dieFile =
        File('${Directory.current.path}/agent.turn.die');
    while (!dieFile.existsSync()) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    exit(0);
  }
  if (text == 'weird') {
    // Unknown update variant: the client must drop it without crashing.
    await _sendUpdate(<String, Object?>{'sessionUpdate': 'experimental_update', 'payload': 'hi'});
    await _sendUpdate(<String, Object?>{
      'sessionUpdate': 'usage_update',
      'size': 100,
      'used': 10,
    });
    return _resolvePrompt(promptId, 'end_turn');
  }

  if (text == 'stream raw output') {
    // Progressive raw output on running updates: the daemon must trim the
    // raw fields from non-terminal snapshots while the terminal one keeps
    // the full merged state.
    await _sendUpdate(<String, Object?>{
      'sessionUpdate': 'tool_call',
      'toolCallId': 'tc1',
      'title': 'Run job',
      'kind': 'execute',
      'status': 'in_progress',
      'content': <Object?>[],
      'rawInput': <String, Object?>{'cmd': 'job'},
    });
    if (_cancelled(promptId)) return;
    await _sendUpdate(<String, Object?>{
      'sessionUpdate': 'tool_call_update',
      'toolCallId': 'tc1',
      'rawOutput': <String, Object?>{'progress': 1},
    });
    if (_cancelled(promptId)) return;
    await _sendUpdate(<String, Object?>{
      'sessionUpdate': 'tool_call_update',
      'toolCallId': 'tc1',
      'rawOutput': <String, Object?>{'progress': 2},
    });
    if (_cancelled(promptId)) return;
    await _sendUpdate(<String, Object?>{
      'sessionUpdate': 'tool_call_update',
      'toolCallId': 'tc1',
      'status': 'completed',
    });
    return _resolvePrompt(promptId, 'end_turn');
  }

  try {
    await _sendUpdate(<String, Object?>{
      'sessionUpdate': 'agent_message_chunk',
      'content': <String, Object?>{'type': 'text', 'text': 'I will inspect the target file.'},
      'messageId': 'm1',
    });
    if (_cancelled(promptId)) return;
    await _sendUpdate(<String, Object?>{
      'sessionUpdate': 'agent_message_chunk',
      'content': <String, Object?>{'type': 'text', 'text': 'Reading its contents first.'},
      'messageId': 'm1',
    });
    if (_cancelled(promptId)) return;

    await _sendUpdate(<String, Object?>{
      'sessionUpdate': 'tool_call',
      'toolCallId': 'tc1',
      'title': 'Read example.txt',
      'kind': 'read',
      'status': 'in_progress',
      'content': <Object?>[],
      'locations': <Object?>[
        <String, Object?>{'path': targetPath, 'line': 1},
      ],
      'rawInput': <String, Object?>{'path': targetPath},
    });
    if (_cancelled(promptId)) return;

    final readResult = await _request(
      'fs/read_text_file',
      <String, Object?>{'sessionId': sessionId, 'path': targetPath},
    );
    if (_cancelled(promptId)) return;
    final content = readResult['content'] as String? ?? '';

    await _sendUpdate(<String, Object?>{
      'sessionUpdate': 'tool_call_update',
      'toolCallId': 'tc1',
      'status': 'completed',
      'rawOutput': <String, Object?>{'content': content},
    });
    if (_cancelled(promptId)) return;

    await _sendUpdate(<String, Object?>{
      'sessionUpdate': 'plan',
      'entries': <Object?>[
        <String, Object?>{
          'content': 'Read the target file',
          'priority': 'high',
          'status': 'in_progress',
        },
        <String, Object?>{
          'content': 'Apply the edit',
          'priority': 'medium',
          'status': 'pending',
        },
      ],
    });
    if (_cancelled(promptId)) return;

    final permissionResult = await _request(
      'session/request_permission',
      <String, Object?>{
        'sessionId': sessionId,
        'toolCall': <String, Object?>{
          'toolCallId': 'tc1',
          'title': 'Read example.txt',
          'kind': 'read',
          'status': 'in_progress',
        },
        'options': <Object?>[
          <String, Object?>{
            'optionId': 'allow',
            'name': 'Allow reading',
            'kind': 'allow_always',
          },
          <String, Object?>{
            'optionId': 'reject',
            'name': 'Reject reading',
            'kind': 'reject_once',
          },
        ],
      },
    );
    if (_cancelled(promptId)) return;
    final outcome = permissionResult['outcome'];
    if (outcome is Map && outcome['outcome'] == 'cancelled') {
      return _resolvePrompt(promptId, 'cancelled');
    }

    await _sendUpdate(<String, Object?>{
      'sessionUpdate': 'usage_update',
      'size': 10000,
      'used': 250,
      'cost': <String, Object?>{'amount': 0.012, 'currency': 'USD'},
    });
    return _resolvePrompt(promptId, 'end_turn');
  } on Object catch (error, stack) {
    stderr.writeln('fake turn error: $error\n$stack');
    return _resolvePrompt(promptId, 'refusal');
  }
}

bool _cancelled(Object promptId) => _pendingPrompts[promptId] == true;
