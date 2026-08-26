import 'dart:async';
import 'dart:convert';
import 'dart:io';

const String _threadId = 'thr_fake_01M0H000000000000000000';
const String _turnId = 'turn_fake_1';
const int _approvalRequestId = 900;

Map<String, Object?>? _pendingTurn;

Future<void> _emit(Map<String, Object?> message) async {
  stdout.writeln(jsonEncode(message));
  await stdout.flush();
}

Future<void> _respond(Object id, Map<String, Object?> result) =>
    _emit(<String, Object?>{'id': id, 'result': result});

Future<void> _notify(String method, Map<String, Object?> params) =>
    _emit(<String, Object?>{'method': method, 'params': params});

Future<void> _writeReport(String environmentName, Object? value) async {
  final String? path = Platform.environment[environmentName];
  if (path == null || path.isEmpty) return;
  await File(path).writeAsString(jsonEncode(value), flush: true);
}

Future<void> _startTurn(Map<String, Object?> params) async {
  await _writeReport('FAKE_CODEX_TURN_REPORT', params);
  await _writeReport('FAKE_CODEX_INPUT_REPORT', params['input']);
  final List<Object?> input = params['input']! as List<Object?>;
  final String text = input
      .whereType<Map>()
      .where((Map<Object?, Object?> item) => item['type'] == 'text')
      .map((Map<Object?, Object?> item) => item['text'])
      .whereType<String>()
      .join('\n');
  if (text.contains('delay turn start')) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  await _respond(params.remove('_requestId')!, <String, Object?>{
    'turn': <String, Object?>{
      'id': _turnId,
      'status': 'inProgress',
      'items': <Object?>[],
      'error': null,
    },
  });
  await _notify('turn/started', <String, Object?>{
    'threadId': _threadId,
    'turn': <String, Object?>{
      'id': _turnId,
      'status': 'inProgress',
      'items': <Object?>[],
      'error': null,
    },
  });

  if (text.contains('wait for cancel')) {
    _pendingTurn = params;
    return;
  }
  if (text.contains('fail turn')) {
    await _notify('error', <String, Object?>{
      'threadId': _threadId,
      'turnId': _turnId,
      'error': <String, Object?>{
        'message': 'Provider failed: bad credentials',
        'codexErrorInfo': 'Unauthorized',
      },
    });
    await _notify('turn/completed', <String, Object?>{
      'threadId': _threadId,
      'turn': <String, Object?>{
        'id': _turnId,
        'status': 'failed',
        'items': <Object?>[],
        'error': <String, Object?>{
          'message': 'Provider failed: bad credentials',
        },
      },
    });
    return;
  }

  await _notify('item/started', <String, Object?>{
    'threadId': _threadId,
    'turnId': _turnId,
    'item': <String, Object?>{
      'type': 'reasoning',
      'id': 'reason-1',
      'summary': <String>[],
      'content': <String>[],
    },
  });
  await _notify('item/reasoning/summaryTextDelta', <String, Object?>{
    'threadId': _threadId,
    'turnId': _turnId,
    'itemId': 'reason-1',
    'summaryIndex': 0,
    'delta': 'Think',
  });
  await _notify('item/reasoning/summaryTextDelta', <String, Object?>{
    'threadId': _threadId,
    'turnId': _turnId,
    'itemId': 'reason-1',
    'summaryIndex': 0,
    'delta': 'ing',
  });
  await _notify('item/completed', <String, Object?>{
    'threadId': _threadId,
    'turnId': _turnId,
    'item': <String, Object?>{
      'type': 'reasoning',
      'id': 'reason-1',
      'summary': <String>['Thinking'],
      'content': <String>[],
    },
  });
  await _notify('turn/plan/updated', <String, Object?>{
    'threadId': _threadId,
    'turnId': _turnId,
    'explanation': 'Work in order',
    'plan': <Object?>[
      <String, Object?>{'step': 'Inspect', 'status': 'completed'},
      <String, Object?>{'step': 'Edit', 'status': 'inProgress'},
    ],
  });
  await _notify('item/started', <String, Object?>{
    'threadId': _threadId,
    'turnId': _turnId,
    'item': <String, Object?>{
      'type': 'commandExecution',
      'id': 'command-1',
      'command': 'dart test',
      'cwd': Directory.current.path,
      'status': 'inProgress',
      'commandActions': <Object?>[
        <String, Object?>{'type': 'read', 'path': 'pubspec.yaml'},
      ],
    },
  });
  _pendingTurn = params;
  await _emit(<String, Object?>{
    'id': _approvalRequestId,
    'method': 'item/commandExecution/requestApproval',
    'params': <String, Object?>{
      'threadId': _threadId,
      'turnId': _turnId,
      'itemId': 'command-1',
      'command': 'dart test',
      'cwd': Directory.current.path,
      'reason': 'Run the regression suite',
      'proposedExecpolicyAmendment': <String>['dart', 'test'],
    },
  });
}

Future<void> _finishTurn(Map<String, Object?> approvalResponse) async {
  if (_pendingTurn == null) return;
  _pendingTurn = null;
  await _writeReport('FAKE_CODEX_APPROVAL_REPORT', approvalResponse['result']);
  await _notify('item/commandExecution/outputDelta', <String, Object?>{
    'threadId': _threadId,
    'turnId': _turnId,
    'itemId': 'command-1',
    'delta': 'All tests passed\n',
  });
  await _notify('item/completed', <String, Object?>{
    'threadId': _threadId,
    'turnId': _turnId,
    'item': <String, Object?>{
      'type': 'commandExecution',
      'id': 'command-1',
      'command': 'dart test',
      'cwd': Directory.current.path,
      'status': 'completed',
      'commandActions': <Object?>[
        <String, Object?>{'type': 'read', 'path': 'pubspec.yaml'},
      ],
      'aggregatedOutput': 'All tests passed\n',
      'exitCode': 0,
      'durationMs': 42,
    },
  });

  final Map<String, Object?> fileItem = <String, Object?>{
    'type': 'fileChange',
    'id': 'patch-1',
    'status': 'inProgress',
    'changes': <Object?>[
      <String, Object?>{
        'path': 'lib/main.dart',
        'kind': <String, Object?>{
          'type': 'update',
          'move_path': 'lib/renamed.dart',
        },
        'diff': '@@ -1 +1 @@\n-old\n+new',
      },
    ],
  };
  await _notify('item/started', <String, Object?>{
    'threadId': _threadId,
    'turnId': _turnId,
    'item': fileItem,
  });
  await _notify('turn/diff/updated', <String, Object?>{
    'threadId': _threadId,
    'turnId': _turnId,
    'diff':
        'diff --git a/lib/main.dart b/lib/main.dart\n'
        '@@ -1 +1 @@\n-old\n+new',
  });
  await _notify('item/completed', <String, Object?>{
    'threadId': _threadId,
    'turnId': _turnId,
    'item': <String, Object?>{...fileItem, 'status': 'completed'},
  });

  final Map<String, Object?> deleteItem = <String, Object?>{
    'type': 'fileChange',
    'id': 'delete-1',
    'status': 'inProgress',
    'changes': <Object?>[
      <String, Object?>{
        'path': 'lib/obsolete.dart',
        'kind': <String, Object?>{'type': 'delete'},
        'diff': '@@ -1 +0,0 @@\n-obsolete',
      },
    ],
  };
  await _notify('item/started', <String, Object?>{
    'threadId': _threadId,
    'turnId': _turnId,
    'item': deleteItem,
  });
  await _notify('item/completed', <String, Object?>{
    'threadId': _threadId,
    'turnId': _turnId,
    'item': <String, Object?>{...deleteItem, 'status': 'completed'},
  });

  final Map<String, Object?> mcpItem = <String, Object?>{
    'type': 'mcpToolCall',
    'id': 'mcp-1',
    'server': 'speeddial',
    'tool': 'attachments.read',
    'status': 'inProgress',
    'arguments': <String, Object?>{'attachmentId': 'att-1'},
    'readOnlyHint': true,
  };
  await _notify('item/started', <String, Object?>{
    'threadId': _threadId,
    'turnId': _turnId,
    'item': mcpItem,
  });
  await _notify('item/completed', <String, Object?>{
    'threadId': _threadId,
    'turnId': _turnId,
    'item': <String, Object?>{
      ...mcpItem,
      'status': 'completed',
      'result': <String, Object?>{'content': 'notes'},
    },
  });

  final Map<String, Object?> dynamicItem = <String, Object?>{
    'type': 'dynamicToolCall',
    'id': 'dynamic-1',
    'namespace': 'workspace',
    'tool': 'read_file',
    'status': 'inProgress',
    'arguments': <String, Object?>{'path': 'pubspec.yaml'},
  };
  await _notify('item/started', <String, Object?>{
    'threadId': _threadId,
    'turnId': _turnId,
    'item': dynamicItem,
  });
  await _notify('item/completed', <String, Object?>{
    'threadId': _threadId,
    'turnId': _turnId,
    'item': <String, Object?>{
      ...dynamicItem,
      'status': 'completed',
      'success': true,
      'contentItems': <Object?>[
        <String, Object?>{'type': 'inputText', 'text': 'pubspec contents'},
      ],
    },
  });

  final Map<String, Object?> collabItem = <String, Object?>{
    'type': 'collabAgentToolCall',
    'id': 'collab-1',
    'tool': 'spawnAgent',
    'status': 'inProgress',
    'senderThreadId': _threadId,
    'receiverThreadIds': <String>['thr_child'],
    'agentsStates': <String, Object?>{
      'thr_child': <String, Object?>{'status': 'running'},
    },
  };
  await _notify('item/started', <String, Object?>{
    'threadId': _threadId,
    'turnId': _turnId,
    'item': collabItem,
  });
  await _notify('item/completed', <String, Object?>{
    'threadId': _threadId,
    'turnId': _turnId,
    'item': <String, Object?>{
      ...collabItem,
      'status': 'completed',
      'agentsStates': <String, Object?>{
        'thr_child': <String, Object?>{'status': 'completed'},
      },
    },
  });

  final Map<String, Object?> subAgentItem = <String, Object?>{
    'type': 'subAgentActivity',
    'id': 'subagent-1',
    'agentPath': 'reviewer',
    'agentThreadId': 'thr_child',
    'kind': 'started',
  };
  await _notify('item/started', <String, Object?>{
    'threadId': _threadId,
    'turnId': _turnId,
    'item': subAgentItem,
  });
  await _notify('item/completed', <String, Object?>{
    'threadId': _threadId,
    'turnId': _turnId,
    'item': subAgentItem,
  });

  final Map<String, Object?> searchItem = <String, Object?>{
    'type': 'webSearch',
    'id': 'search-1',
    'query': 'Codex app-server',
  };
  await _notify('item/started', <String, Object?>{
    'threadId': _threadId,
    'turnId': _turnId,
    'item': searchItem,
  });
  await _notify('item/completed', <String, Object?>{
    'threadId': _threadId,
    'turnId': _turnId,
    'item': <String, Object?>{
      ...searchItem,
      'results': <Object?>[
        <String, Object?>{'title': 'Codex', 'url': 'https://openai.com/codex'},
      ],
    },
  });

  final Map<String, Object?> imageItem = <String, Object?>{
    'type': 'imageView',
    'id': 'image-1',
    'path': '/tmp/screenshot.png',
  };
  await _notify('item/started', <String, Object?>{
    'threadId': _threadId,
    'turnId': _turnId,
    'item': imageItem,
  });
  await _notify('item/completed', <String, Object?>{
    'threadId': _threadId,
    'turnId': _turnId,
    'item': imageItem,
  });

  final Map<String, Object?> compaction = <String, Object?>{
    'type': 'contextCompaction',
    'id': 'compact-1',
  };
  await _notify('item/started', <String, Object?>{
    'threadId': _threadId,
    'turnId': _turnId,
    'item': compaction,
  });
  await _notify('item/completed', <String, Object?>{
    'threadId': _threadId,
    'turnId': _turnId,
    'item': compaction,
  });
  await _notify('model/rerouted', <String, Object?>{
    'threadId': _threadId,
    'turnId': _turnId,
    'fromModel': 'gpt-test',
    'toModel': 'gpt-fast',
    'reason': 'Test fallback',
  });
  await _notify('thread/tokenUsage/updated', <String, Object?>{
    'threadId': _threadId,
    'turnId': _turnId,
    'tokenUsage': <String, Object?>{
      'modelContextWindow': 200000,
      'last': <String, Object?>{
        'inputTokens': 120,
        'cachedInputTokens': 80,
        'cacheWriteInputTokens': 5,
        'outputTokens': 30,
        'reasoningOutputTokens': 10,
        'totalTokens': 150,
      },
      'total': <String, Object?>{
        'inputTokens': 500,
        'cachedInputTokens': 400,
        'cacheWriteInputTokens': 7,
        'outputTokens': 100,
        'reasoningOutputTokens': 25,
        'totalTokens': 600,
      },
    },
  });

  final Map<String, Object?> message = <String, Object?>{
    'type': 'agentMessage',
    'id': 'message-1',
    'text': 'Hello Codex',
    'phase': 'final_answer',
  };
  await _notify('item/started', <String, Object?>{
    'threadId': _threadId,
    'turnId': _turnId,
    'item': <String, Object?>{...message, 'text': ''},
  });
  await _notify('item/agentMessage/delta', <String, Object?>{
    'threadId': _threadId,
    'turnId': _turnId,
    'itemId': 'message-1',
    'delta': 'Hello ',
  });
  await _notify('item/agentMessage/delta', <String, Object?>{
    'threadId': _threadId,
    'turnId': _turnId,
    'itemId': 'message-1',
    'delta': 'Codex',
  });
  await _notify('item/completed', <String, Object?>{
    'threadId': _threadId,
    'turnId': _turnId,
    'item': message,
  });
  await _notify('turn/completed', <String, Object?>{
    'threadId': _threadId,
    'turn': <String, Object?>{
      'id': _turnId,
      'status': 'completed',
      'items': <Object?>[message],
      'error': null,
    },
  });
}

Future<void> _handle(Map<String, Object?> message) async {
  final Object? id = message['id'];
  final String? method = message['method'] as String?;
  if (method == null && id == _approvalRequestId) {
    await _finishTurn(message);
    return;
  }
  if (id == null || method == null) return;
  final Map<String, Object?> params = message['params'] is Map
      ? Map<String, Object?>.from(message['params']! as Map)
      : <String, Object?>{};
  switch (method) {
    case 'initialize':
      await _respond(id, <String, Object?>{
        'userAgent': 'fake-codex/1.0',
        'codexHome': Directory.current.path,
        'platformFamily': 'unix',
        'platformOs': Platform.operatingSystem,
      });
    case 'model/list':
      await _respond(id, <String, Object?>{
        'data': <Object?>[
          <String, Object?>{
            'id': 'gpt-test',
            'model': 'gpt-test',
            'displayName': 'GPT Test',
            'description': 'Deterministic test model',
            'defaultReasoningEffort': 'medium',
            'supportedReasoningEfforts': <Object?>[
              <String, Object?>{
                'reasoningEffort': 'low',
                'description': 'Fast',
              },
              <String, Object?>{
                'reasoningEffort': 'medium',
                'description': 'Balanced',
              },
              <String, Object?>{
                'reasoningEffort': 'high',
                'description': 'Deep',
              },
            ],
            'hidden': false,
            'isDefault': true,
          },
          <String, Object?>{
            'id': 'gpt-fast',
            'model': 'gpt-fast',
            'displayName': 'GPT Fast',
            'description': 'Fast test model',
            'defaultReasoningEffort': 'low',
            'supportedReasoningEfforts': <Object?>[
              <String, Object?>{
                'reasoningEffort': 'low',
                'description': 'Fast',
              },
            ],
            'hidden': false,
            'isDefault': false,
          },
        ],
        'nextCursor': null,
      });
    case 'thread/start':
      await _writeReport('FAKE_CODEX_START_REPORT', params);
      await _respond(id, <String, Object?>{
        'thread': <String, Object?>{'id': _threadId},
        'model': params['model'] ?? 'gpt-test',
        'reasoningEffort': 'medium',
      });
      await _notify('mcpServer/startupStatus/updated', <String, Object?>{
        'threadId': _threadId,
        'name': 'speeddial',
        'status': 'ready',
        'error': null,
        'failureReason': null,
      });
    case 'thread/resume':
      await _writeReport('FAKE_CODEX_RESUME_REPORT', params);
      await _respond(id, <String, Object?>{
        'thread': <String, Object?>{'id': params['threadId']},
        'model': 'gpt-test',
        'reasoningEffort': 'medium',
      });
    case 'turn/start':
      params['_requestId'] = id;
      await _startTurn(params);
    case 'turn/interrupt':
      await _respond(id, const <String, Object?>{});
      if (_pendingTurn != null) {
        _pendingTurn = null;
        await _notify('turn/completed', <String, Object?>{
          'threadId': _threadId,
          'turn': <String, Object?>{
            'id': _turnId,
            'status': 'interrupted',
            'items': <Object?>[],
            'error': null,
          },
        });
      }
    default:
      await _emit(<String, Object?>{
        'id': id,
        'error': <String, Object?>{
          'code': -32601,
          'message': 'Unknown method: $method',
        },
      });
  }
}

Future<void> main(List<String> args) async {
  await for (final String line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    final Object? decoded = jsonDecode(line);
    if (decoded is Map) {
      await _handle(Map<String, Object?>.from(decoded));
    }
  }
}
