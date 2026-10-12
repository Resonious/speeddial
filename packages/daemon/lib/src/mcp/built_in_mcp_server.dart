/// Built-in MCP stdio server exposed to every SpeedDial agent session.
///
/// The agent launches this process from the ACP `mcpServers` configuration.
/// It speaks newline-delimited MCP JSON-RPC on stdio and uses a private,
/// authenticated WebSocket bridge back to the owning daemon for searches,
/// session archiving, and user-visible image and explainer events.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_protocol/speeddial_protocol.dart';

const String kBuiltInMcpArgument = '_internal-mcp';
const String kMcpDaemonUrlEnv = 'SPEEDDIAL_MCP_DAEMON_URL';
const String kMcpSecretEnv = 'SPEEDDIAL_MCP_SECRET';
const String kMcpSessionIdEnv = 'SPEEDDIAL_MCP_SESSION_ID';
const String kMcpSessionCwdEnv = 'SPEEDDIAL_MCP_SESSION_CWD';
const String kMcpServerName = 'speeddial';
const String kSessionSummaryInstruction =
    'Call speeddial set_session_summary with a brief session title when the task is clear or changes.';
const String _kLatestMcpVersion = '2025-11-25';
const Set<String> _kSupportedMcpVersions = <String>{
  '2024-11-05',
  '2025-03-26',
  '2025-06-18',
  _kLatestMcpVersion,
};

typedef McpDaemonCall = Future<Object?> Function(
  String method,
  Map<String, Object?> params,
);

/// Command and leading arguments that relaunch the current application in its
/// hidden MCP-server mode. Works for `dart run`, compiled daemon executables,
/// and the Flutter desktop executable that embeds the daemon.
({String command, List<String> args}) builtInMcpLaunchCommand() {
  final String executable = Platform.resolvedExecutable;
  final String executableName = p
      .basenameWithoutExtension(executable)
      .toLowerCase();
  if (executableName == 'dart' || executableName == 'dartaotruntime') {
    return (
      command: executable,
      args: <String>[Platform.script.toFilePath(), kBuiltInMcpArgument],
    );
  }
  return (command: executable, args: const <String>[kBuiltInMcpArgument]);
}

/// MCP request dispatcher. Transport is deliberately separate so tests can
/// exercise every tool without starting a subprocess or socket.
class BuiltInMcpServer {
  BuiltInMcpServer({
    required String sessionId,
    required String cwd,
    required McpDaemonCall daemonCall,
    this.onWarning,
  }) : _sessionId = sessionId, // ignore: prefer_initializing_formals
       _cwd = cwd, // ignore: prefer_initializing_formals
       _daemonCall = daemonCall; // ignore: prefer_initializing_formals

  final String _sessionId;
  final String _cwd;
  final McpDaemonCall _daemonCall;
  final void Function(String message)? onWarning;

  /// Handles one decoded MCP JSON-RPC message. Notifications return null;
  /// requests return a complete response envelope.
  Future<Map<String, Object?>?> handle(Map<String, Object?> message) async {
    final Object? id = message['id'];
    final Object? rawMethod = message['method'];
    if (message['jsonrpc'] != '2.0' || rawMethod is! String) {
      return _error(id, -32600, 'Invalid Request');
    }
    final Map<String, Object?> params = switch (message['params']) {
      final Map raw => raw.cast<String, Object?>(),
      null => const <String, Object?>{},
      _ => <String, Object?>{},
    };

    if (!message.containsKey('id')) {
      // `notifications/initialized` and cancellation/progress notifications
      // need no response. The server emits no notifications of its own.
      return null;
    }

    try {
      final Object result = switch (rawMethod) {
        'initialize' => _initialize(params),
        'ping' => const <String, Object?>{},
        'tools/list' => await _listTools(),
        'tools/call' => await _callTool(params),
        _ => throw const _McpRpcError(-32601, 'Method not found'),
      };
      return <String, Object?>{'jsonrpc': '2.0', 'id': id, 'result': result};
    } on _McpRpcError catch (error) {
      return _error(id, error.code, error.message);
    } on Object catch (error) {
      return _error(id, -32603, 'Internal error: $error');
    }
  }

  Map<String, Object?> _initialize(Map<String, Object?> params) {
    final Object? requested = params['protocolVersion'];
    final String version =
        requested is String && _kSupportedMcpVersions.contains(requested)
        ? requested
        : _kLatestMcpVersion;
    return <String, Object?>{
      'protocolVersion': version,
      'capabilities': <String, Object?>{
        'tools': <String, Object?>{'listChanged': false},
      },
      'serverInfo': <String, Object?>{
        'name': 'speeddial',
        'title': 'SpeedDial',
        'version': '0.1.0',
      },
      'instructions':
          '$kSessionSummaryInstruction\n\n'
          'SpeedDial exposes tools from enabled MCP servers through this single '
          'speeddial server, alongside project/session search, transcript browsing, '
          'session archiving, image display, and interactive explainers. When '
          'a visual walkthrough would help the user understand something (an '
          'architecture, a request flow, an algorithm, a state machine), call '
          'show_explainer to show a stepped, animated SVG diagram. '
          'Managed tools are named '
          '<server-name>__<tool-name> (for example, Linear__save_issue when a '
          'Linear server provides that tool); their descriptions identify the '
          'source server. Before reporting that an integration is unavailable, '
          'inspect the available speeddial tools and use tool discovery/search '
          'if your harness defers tool loading. Search by the integration name '
          'and requested operation. If managed tools are missing, call '
          'discover_mcp_tools to retry discovery and inspect warnings, then '
          'call_mcp_tool to invoke a discovered tool by name. '
          'MCP resource listings are not tool listings, '
          'and managed servers do not appear as separate MCP connections. '
          'Credentials stay in the SpeedDial daemon, so missing environment '
          'variables or local credentials do not mean an integration is '
          'unavailable. Use the exposed tools; report any actual tool error.',
    };
  }

  Future<Map<String, Object?>> _listTools() async {
    try {
      final Object? raw = await _daemonCall(
        'internal.mcpListTools',
        const <String, Object?>{},
      );
      if (raw is! Map) {
        throw const FormatException('managed MCP tool list must be an object');
      }
      final Map<String, Object?> result = raw.cast<String, Object?>();
      final Object? rawTools = result['tools'];
      if (rawTools is! List) {
        throw const FormatException('managed MCP tool list has no tools array');
      }
      final List<Map<String, Object?>> tools = <Map<String, Object?>>[
        ..._tools,
      ];
      for (final Object? rawTool in rawTools) {
        if (rawTool is! Map) {
          throw const FormatException(
            'managed MCP tool descriptor must be an object',
          );
        }
        tools.add(Map<String, Object?>.from(rawTool.cast<String, Object?>()));
      }
      final List<String> warnings = switch (result['warnings']) {
        final List values => values.whereType<String>().toList(growable: false),
        _ => const <String>[],
      };
      for (final String warning in warnings) {
        onWarning?.call('SpeedDial MCP proxy: $warning');
      }
      return <String, Object?>{
        'tools': tools,
        if (warnings.isNotEmpty)
          '_meta': <String, Object?>{'speeddial/warnings': warnings},
      };
    } on Object catch (error) {
      final String warning = 'managed MCP tools unavailable: $error';
      onWarning?.call('SpeedDial MCP proxy: $warning');
      return <String, Object?>{
        'tools': _tools,
        '_meta': <String, Object?>{
          'speeddial/warnings': <String>[warning],
        },
      };
    }
  }

  Future<Map<String, Object?>> _callTool(Map<String, Object?> params) async {
    final Object? rawName = params['name'];
    final Object? rawArguments = params['arguments'];
    if (rawName is! String || (rawArguments != null && rawArguments is! Map)) {
      throw const _McpRpcError(-32602, 'Invalid tools/call parameters');
    }
    final Map<String, Object?> arguments = rawArguments == null
        ? <String, Object?>{}
        : (rawArguments as Map).cast<String, Object?>();
    try {
      return switch (rawName) {
        'discover_mcp_tools' => await _discoverMcpTools(arguments),
        'call_mcp_tool' => await _callDiscoveredTool(arguments),
        'search_projects' => await _searchProjects(arguments),
        'search_sessions' => await _searchSessions(arguments),
        'read_session_transcript' => await _readSessionTranscript(arguments),
        'archive_session' => await _setSessionArchived(arguments, true),
        'unarchive_session' => await _setSessionArchived(arguments, false),
        'set_session_summary' => await _setSessionSummary(arguments),
        'display_image' => await _displayImage(arguments),
        'show_explainer' => await _showExplainer(arguments),
        _ => await _callManagedTool(rawName, arguments),
      };
    } on Object catch (error) {
      return <String, Object?>{
        'content': <Object?>[
          <String, Object?>{'type': 'text', 'text': error.toString()},
        ],
        'isError': true,
      };
    }
  }

  Future<Map<String, Object?>> _discoverMcpTools(
    Map<String, Object?> arguments,
  ) async {
    final String query = (_optionalString(arguments, 'query') ?? '')
        .toLowerCase();
    final Map<String, Object?> listed = await _listTools();
    final Set<Object?> builtInNames = _tools
        .map((tool) => tool['name'])
        .toSet();
    final List<Map<String, Object?>> tools = (listed['tools']! as List)
        .cast<Map<String, Object?>>()
        .where((tool) => !builtInNames.contains(tool['name']))
        .where(
          (tool) =>
              query.isEmpty ||
              '${tool['name']} ${tool['description']}'.toLowerCase().contains(
                query,
              ),
        )
        .toList(growable: false);
    final Map<String, Object?>? metadata =
        listed['_meta'] as Map<String, Object?>?;
    return _textResult(
      _pretty(<String, Object?>{
        'tools': tools,
        'warnings': metadata?['speeddial/warnings'] ?? const <String>[],
      }),
    );
  }

  Future<Map<String, Object?>> _callDiscoveredTool(
    Map<String, Object?> arguments,
  ) async {
    final String? name = _optionalString(arguments, 'name');
    if (name == null) throw ArgumentError('name is required');
    final Object? rawArguments = arguments['arguments'];
    if (rawArguments is! Map) {
      throw ArgumentError('arguments must be an object');
    }
    return _callManagedTool(name, rawArguments.cast<String, Object?>());
  }

  Future<Map<String, Object?>> _callManagedTool(
    String name,
    Map<String, Object?> arguments,
  ) async {
    final Object? raw = await _daemonCall(
      'internal.mcpCallTool',
      <String, Object?>{'name': name, 'arguments': arguments},
    );
    if (raw is! Map) {
      throw const FormatException('managed MCP result must be an object');
    }
    return Map<String, Object?>.from(raw.cast<String, Object?>());
  }

  Future<Map<String, Object?>> _searchProjects(
    Map<String, Object?> arguments,
  ) async {
    final String query = _optionalString(arguments, 'query') ?? '';
    final Object? result = await _daemonCall(
      'internal.mcpSearchProjects',
      <String, Object?>{'query': query},
    );
    return _textResult(_pretty(result));
  }

  Future<Map<String, Object?>> _searchSessions(
    Map<String, Object?> arguments,
  ) async {
    final String query = _optionalString(arguments, 'query') ?? '';
    final String? projectId = _optionalString(arguments, 'projectId');
    final bool includeArchived = switch (arguments['includeArchived']) {
      final bool value => value,
      null => false,
      _ => throw ArgumentError('includeArchived must be a boolean'),
    };
    final int limit = switch (arguments['limit']) {
      final int value when value >= 1 && value <= 100 => value,
      null => 20,
      _ => throw ArgumentError('limit must be between 1 and 100'),
    };
    final Object? result = await _daemonCall(
      'internal.mcpSearchSessions',
      <String, Object?>{
        'query': query,
        'projectId': ?projectId,
        'includeArchived': includeArchived,
        'limit': limit,
      },
    );
    return _textResult(_pretty(result));
  }

  Future<Map<String, Object?>> _readSessionTranscript(
    Map<String, Object?> arguments,
  ) async {
    final String? sessionId = _optionalString(arguments, 'sessionId');
    if (sessionId == null) {
      throw ArgumentError('sessionId is required');
    }
    final int limit = switch (arguments['limit']) {
      final int value when value >= 1 && value <= 200 => value,
      null => 50,
      _ => throw ArgumentError('limit must be between 1 and 200'),
    };
    final int? beforeSeq = switch (arguments['beforeSeq']) {
      final int value when value >= 1 => value,
      null => null,
      _ => throw ArgumentError('beforeSeq must be a positive integer'),
    };
    final Object? result = await _daemonCall(
      'internal.mcpReadSessionTranscript',
      <String, Object?>{
        'sessionId': sessionId,
        'limit': limit,
        'beforeSeq': ?beforeSeq,
      },
    );
    return _textResult(_pretty(result));
  }

  Future<Map<String, Object?>> _setSessionArchived(
    Map<String, Object?> arguments,
    bool archived,
  ) async {
    final String? sessionId = _optionalString(arguments, 'sessionId');
    if (sessionId == null) {
      throw ArgumentError('sessionId is required');
    }
    final Object? result = await _daemonCall(
      'internal.mcpArchiveSession',
      <String, Object?>{'sessionId': sessionId, 'archived': archived},
    );
    return _textResult(_pretty(result));
  }

  Future<Map<String, Object?>> _setSessionSummary(
    Map<String, Object?> arguments,
  ) async {
    final String? summary = _optionalString(arguments, 'summary')?.trim();
    if (summary == null || summary.isEmpty) {
      throw ArgumentError('summary must be a non-empty string');
    }
    final Object? result = await _daemonCall(
      'internal.mcpSetSessionSummary',
      <String, Object?>{'summary': summary},
    );
    return _textResult(_pretty(result));
  }

  Future<Map<String, Object?>> _displayImage(
    Map<String, Object?> arguments,
  ) async {
    final String? path = _optionalString(arguments, 'path');
    final String? inlineData = _optionalString(arguments, 'data');
    if ((path == null) == (inlineData == null)) {
      throw ArgumentError('provide exactly one of path or data');
    }

    final String data;
    final String name;
    final String mimeType;
    if (path != null) {
      final File file = _imageFile(path);
      final List<int> bytes = file.readAsBytesSync();
      if (bytes.length > kMaxAttachmentBytes) {
        throw ArgumentError('image exceeds $kMaxAttachmentBytes bytes');
      }
      data = base64Encode(bytes);
      name = _optionalString(arguments, 'name') ?? p.basename(file.path);
      mimeType =
          _optionalString(arguments, 'mimeType') ?? mimeTypeForFileName(name);
    } else {
      data = inlineData!;
      final List<int> bytes;
      try {
        bytes = base64Decode(data);
      } on FormatException {
        throw ArgumentError('data must be valid base64');
      }
      if (bytes.length > kMaxAttachmentBytes) {
        throw ArgumentError('image exceeds $kMaxAttachmentBytes bytes');
      }
      name = _optionalString(arguments, 'name') ?? 'image';
      mimeType =
          _optionalString(arguments, 'mimeType') ?? mimeTypeForFileName(name);
    }
    if (!isImageMimeType(mimeType)) {
      throw ArgumentError('mimeType must be image/*');
    }

    await _daemonCall('internal.mcpDisplayImage', <String, Object?>{
      'name': name,
      'mimeType': mimeType,
      'data': data,
    });
    return <String, Object?>{
      'content': <Object?>[
        <String, Object?>{
          'type': 'image',
          'data': data,
          'mimeType': mimeType,
          'annotations': <String, Object?>{
            'audience': <String>['user'],
            'priority': 1.0,
          },
        },
        <String, Object?>{
          'type': 'text',
          'text': 'Displayed $name in SpeedDial session $_sessionId.',
        },
      ],
      'isError': false,
    };
  }

  Future<Map<String, Object?>> _showExplainer(
    Map<String, Object?> arguments,
  ) async {
    // Validate here first so the agent gets every problem in one result; the
    // daemon validates again before persisting.
    final ExplainerDocument document;
    try {
      document = ExplainerDocument.parse(ExplainerSpec.fromJson(arguments));
    } on FormatException catch (error) {
      return _explainerRejected(<String>[error.message]);
    } on ExplainerException catch (error) {
      return _explainerRejected(error.errors);
    }
    await _daemonCall('internal.mcpShowExplainer', <String, Object?>{
      'explainer': document.spec.toJson(),
    });
    final int steps = document.spec.steps.length;
    final int toggles = document.toggles.length;
    final StringBuffer text = StringBuffer(
      'Displayed explainer${document.spec.title == null ? '' : ' "${document.spec.title}"'} '
      'with $steps step${steps == 1 ? '' : 's'} and $toggles '
      'toggle${toggles == 1 ? '' : 's'} in SpeedDial session $_sessionId.',
    );
    if (document.warnings.isNotEmpty) {
      text.write('\nIgnored (fix if they matter):');
      for (final String warning in document.warnings) {
        text.write('\n- $warning');
      }
    }
    return _textResult(text.toString());
  }

  static Map<String, Object?> _explainerRejected(List<String> errors) =>
      <String, Object?>{
        'content': <Object?>[
          <String, Object?>{
            'type': 'text',
            'text':
                'Explainer rejected; nothing was shown. Fix every problem '
                'and call show_explainer again:\n'
                '${errors.map((String e) => '- $e').join('\n')}',
          },
        ],
        'isError': true,
      };

  File _imageFile(String requestedPath) {
    final String candidate = p.isAbsolute(requestedPath)
        ? p.normalize(requestedPath)
        : p.normalize(p.join(_cwd, requestedPath));
    final File file = File(candidate);
    if (!file.existsSync()) {
      throw ArgumentError('image file not found: $requestedPath');
    }
    return file;
  }

  static String? _optionalString(Map<String, Object?> arguments, String name) {
    final Object? value = arguments[name];
    if (value == null) return null;
    if (value is! String || value.isEmpty) {
      throw ArgumentError('$name must be a non-empty string');
    }
    return value;
  }

  static Map<String, Object?> _textResult(String text) => <String, Object?>{
    'content': <Object?>[
      <String, Object?>{'type': 'text', 'text': text},
    ],
    'isError': false,
  };

  static String _pretty(Object? value) =>
      const JsonEncoder.withIndent('  ').convert(value);

  static Map<String, Object?> _error(Object? id, int code, String message) =>
      <String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'error': <String, Object?>{'code': code, 'message': message},
      };

  static const List<Map<String, Object?>> _tools = <Map<String, Object?>>[
    <String, Object?>{
      'name': 'discover_mcp_tools',
      'description': 'Discover or retry tools from enabled MCP integrations such as Linear. Use before reporting an integration unavailable. Returns tool names, input schemas, and discovery warnings. Invoke recovered tools with call_mcp_tool without restarting the session.',
      'inputSchema': <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'query': <String, Object?>{
            'type': 'string',
            'description': 'Optional substring of the integration name or tool description. Omit to list all managed tools.',
          },
        },
        'additionalProperties': false,
      },
      'annotations': <String, Object?>{'readOnlyHint': true},
    },
    <String, Object?>{
      'name': 'call_mcp_tool',
      'description': 'Invoke a managed MCP tool returned by discover_mcp_tools. Supply its exact name and arguments matching its input schema. The operation may modify external data depending on the selected tool.',
      'inputSchema': <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'name': <String, Object?>{'type': 'string'},
          'arguments': <String, Object?>{
            'type': 'object',
            'additionalProperties': true,
          },
        },
        'required': <String>['name', 'arguments'],
        'additionalProperties': false,
      },
      'annotations': <String, Object?>{
        'readOnlyHint': false,
        'destructiveHint': true,
        'idempotentHint': false,
        'openWorldHint': true,
      },
    },
    <String, Object?>{
      'name': 'search_projects',
      'title': 'Search SpeedDial projects',
      'description': 'Find projects known to this SpeedDial daemon by name or path. An empty query lists all projects.',
      'inputSchema': <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'query': <String, Object?>{
            'type': 'string',
            'description': 'Case-insensitive name/path search. Optional.',
          },
        },
        'additionalProperties': false,
      },
      'annotations': <String, Object?>{'readOnlyHint': true},
    },
    <String, Object?>{
      'name': 'search_sessions',
      'title': 'Search other SpeedDial sessions',
      'description': 'Search titles and conversation history in sessions other than the current session.',
      'inputSchema': <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'query': <String, Object?>{
            'type': 'string',
            'description': 'Case-insensitive title/history search. Empty returns recent sessions.',
          },
          'projectId': <String, Object?>{
            'type': 'string',
            'description': 'Optional project id filter.',
          },
          'includeArchived': <String, Object?>{
            'type': 'boolean',
            'default': false,
            'description': 'Include archived sessions. Results identify them with archived: true.',
          },
          'limit': <String, Object?>{
            'type': 'integer',
            'minimum': 1,
            'maximum': 100,
            'default': 20,
          },
        },
        'additionalProperties': false,
      },
      'annotations': <String, Object?>{'readOnlyHint': true},
    },
    <String, Object?>{
      'name': 'read_session_transcript',
      'title': 'Read a SpeedDial session transcript',
      'description': 'Browse a session transcript in chronological pages. Returns user messages, streamed assistant message chunks, and session errors; thoughts and tool payloads are omitted. Use nextBeforeSeq as beforeSeq to read the previous page.',
      'inputSchema': <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'sessionId': <String, Object?>{
            'type': 'string',
            'description': 'The session id returned by search_sessions.',
          },
          'limit': <String, Object?>{
            'type': 'integer',
            'minimum': 1,
            'maximum': 200,
            'default': 50,
            'description': 'Maximum transcript events to return.',
          },
          'beforeSeq': <String, Object?>{
            'type': 'integer',
            'minimum': 1,
            'description': 'Return the page before this sequence number.',
          },
        },
        'required': <String>['sessionId'],
        'additionalProperties': false,
      },
      'annotations': <String, Object?>{
        'readOnlyHint': true,
        'openWorldHint': false,
      },
    },
    <String, Object?>{
      'name': 'archive_session',
      'title': 'Archive a SpeedDial session',
      'description': 'Archive another SpeedDial session so it is hidden from default session lists and searches. Archiving is reversible in SpeedDial.',
      'inputSchema': <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'sessionId': <String, Object?>{
            'type': 'string',
            'description': 'The session id returned by search_sessions.',
          },
        },
        'required': <String>['sessionId'],
        'additionalProperties': false,
      },
      'annotations': <String, Object?>{
        'readOnlyHint': false,
        'destructiveHint': true,
        'idempotentHint': true,
        'openWorldHint': false,
      },
    },
    <String, Object?>{
      'name': 'unarchive_session',
      'title': 'Revive a SpeedDial session',
      'description': 'Unarchive another SpeedDial session so it returns to default session lists and searches.',
      'inputSchema': <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'sessionId': <String, Object?>{
            'type': 'string',
            'description':
                'The archived session id returned by search_sessions.',
          },
        },
        'required': <String>['sessionId'],
        'additionalProperties': false,
      },
      'annotations': <String, Object?>{
        'readOnlyHint': false,
        'destructiveHint': false,
        'idempotentHint': true,
        'openWorldHint': false,
      },
    },
    <String, Object?>{
      'name': 'set_session_summary',
      'title': 'Set this session summary',
      'description': 'Set a brief summary of the current session as its title in the SpeedDial session list.',
      'inputSchema': <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'summary': <String, Object?>{'type': 'string', 'minLength': 1},
        },
        'required': <String>['summary'],
        'additionalProperties': false,
      },
      'annotations': <String, Object?>{
        'readOnlyHint': false,
        'destructiveHint': false,
        'idempotentHint': true,
        'openWorldHint': false,
      },
    },
    <String, Object?>{
      'name': 'display_image',
      'title': 'Display an image',
      'description': 'Display an image in the user\'s SpeedDial timeline and return it to the model. Provide an absolute or session-relative path, or base64 data.',
      'inputSchema': <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'path': <String, Object?>{
            'type': 'string',
            'description': 'Image path on the daemon host. Relative paths resolve from the current session working directory.',
          },
          'data': <String, Object?>{
            'type': 'string',
            'description': 'Base64 image bytes.',
          },
          'mimeType': <String, Object?>{'type': 'string', 'pattern': '^image/'},
          'name': <String, Object?>{'type': 'string'},
        },
        'oneOf': <Object?>[
          <String, Object?>{
            'required': <String>['path'],
            'not': <String, Object?>{
              'required': <String>['data'],
            },
          },
          <String, Object?>{
            'required': <String>['data'],
            'not': <String, Object?>{
              'required': <String>['path'],
            },
          },
        ],
        'additionalProperties': false,
      },
    },
    <String, Object?>{
      'name': 'show_explainer',
      'title': 'Show an interactive explainer',
      'description': kShowExplainerDescription,
      'inputSchema': <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'title': <String, Object?>{'type': 'string', 'maxLength': 200},
          'svg': <String, Object?>{
            'type': 'string',
            'description': 'The scene: one <svg viewBox="..."> document in the subset described above.',
          },
          'steps': <String, Object?>{
            'type': 'array',
            'maxItems': kMaxExplainerSteps,
            'items': <String, Object?>{
              'type': 'object',
              'properties': <String, Object?>{
                'caption': <String, Object?>{'type': 'string'},
                'set': _kExplainerChangesSchema,
              },
              'required': <String>['caption'],
              'additionalProperties': false,
            },
          },
          'toggles': <String, Object?>{
            'type': 'array',
            'maxItems': kMaxExplainerToggles,
            'items': <String, Object?>{
              'type': 'object',
              'properties': <String, Object?>{
                'label': <String, Object?>{'type': 'string', 'maxLength': 60},
                'on': <String, Object?>{'type': 'boolean', 'default': false},
                'set': _kExplainerChangesSchema,
              },
              'required': <String>['label', 'set'],
              'additionalProperties': false,
            },
          },
        },
        'required': <String>['svg'],
        'additionalProperties': false,
      },
      'annotations': <String, Object?>{
        'readOnlyHint': false,
        'destructiveHint': false,
        'idempotentHint': false,
        'openWorldHint': false,
      },
    },
  ];
}

const Map<String, Object?> _kExplainerChangesSchema = <String, Object?>{
  'type': 'object',
  'description':
      'Selector (#id, .class, tag, or a comma list) to attribute changes.',
  'additionalProperties': <String, Object?>{
    'type': 'object',
    'additionalProperties': <String, Object?>{
      'type': <String>['string', 'number'],
    },
  },
};

/// The agent-facing explainer format. Keep in sync with PROTOCOL.md
/// "Explainers" and the parser in speeddial_protocol.
const String kShowExplainerDescription = r'''
Show an interactive explainer in the user's SpeedDial timeline: an SVG diagram the user pages through step by step, with animated transitions, optional toggles, and hover/tap tooltips. Use it when a visual walkthrough explains better than prose: architectures, request flows, algorithms, data structures, state machines. Invalid input is rejected with every problem listed; fix them all and call again.

SVG subset. Root <svg viewBox="0 0 W H"> is required (W 600-800 suits the chat column). Elements: g, rect, circle, ellipse, line, polyline, polygon, path (all commands incl. arcs), text, tspan (x/y/dx/dy; dy may use em), defs, marker (arrowheads via marker-end="url(#id)"), title (tooltip for its parent element), style (simple selectors only: tag, .class, #id, tag.class). Attributes: fill, stroke, stroke-width, stroke-dasharray, stroke-linecap, stroke-linejoin, opacity, fill-opacity, stroke-opacity, font-size, font-weight, font-family (sans or monospace), font-style, text-anchor, dominant-baseline, display, visibility, transform, and geometry. Not supported: gradients, filters, clipPath, mask, image, use, foreignObject, scripts, event handlers, CSS/SMIL animation, % and em lengths (except dy/dx).

Colors. Use theme tokens so the diagram reads in light and dark themes: var(--fg) text and default fill, var(--muted) secondary text and arrows, var(--bg), var(--surface) box fill, var(--border) box outline, var(--accent) the focus, var(--success), var(--warning), var(--danger), var(--info), var(--purple), var(--code) code background. Literal colors (hex, rgb(), names) also work; tint with fill-opacity. Text defaults to 16px sans; 12-15 suits most labels. Allow about 0.6 x font-size per character so labels fit their boxes.

Steps: [{"caption", "set"}]. The first step is the initial view. "set" maps selectors (#id, .class, tag, or comma lists) to attribute changes, e.g. {"#cache": {"fill": "var(--accent)"}, ".reply": {"opacity": 1}}. Changes accumulate: each step starts from the previous one, and moving back restores earlier states. Numbers, colors, opacity, transforms, points, and same-shape path data animate. The attribute "text" replaces a text or tspan's content. Draw later elements with opacity="0" and reveal them in a step. Keep captions to one or two sentences; the diagram carries the detail. Give every element you change an id or class.

Toggles: [{"label", "on", "set"}] are switches under the diagram whose "set" applies on top of the current step while on, e.g. an overlay of latencies.

Example: {"title": "Cache-aside read", "svg": "<svg viewBox=\"0 0 640 160\"><defs><marker id=\"arrow\" viewBox=\"0 0 10 10\" refX=\"9\" refY=\"5\" markerWidth=\"7\" markerHeight=\"7\" orient=\"auto\"><path d=\"M0 0L10 5L0 10z\" fill=\"var(--muted)\"/></marker></defs><style>.box{fill:var(--surface);stroke:var(--border)} .edge{stroke:var(--muted);stroke-width:2;marker-end:url(#arrow);opacity:0}</style><g font-size=\"14\" text-anchor=\"middle\" dominant-baseline=\"central\"><rect class=\"box\" id=\"app\" x=\"20\" y=\"60\" width=\"120\" height=\"44\" rx=\"8\"/><text x=\"80\" y=\"82\">App</text><rect class=\"box\" id=\"cache\" x=\"260\" y=\"60\" width=\"120\" height=\"44\" rx=\"8\"><title>In-memory, 5 min TTL</title></rect><text x=\"320\" y=\"82\">Cache</text><rect class=\"box\" id=\"db\" x=\"500\" y=\"60\" width=\"120\" height=\"44\" rx=\"8\"/><text x=\"560\" y=\"82\">Database</text></g><line class=\"edge\" id=\"ask\" x1=\"140\" y1=\"82\" x2=\"256\" y2=\"82\"/><line class=\"edge\" id=\"miss\" x1=\"380\" y1=\"82\" x2=\"496\" y2=\"82\"/></svg>", "steps": [{"caption": "The app needs a user record."}, {"caption": "It asks the cache first.", "set": {"#ask": {"opacity": 1}, "#cache": {"stroke": "var(--accent)"}}}, {"caption": "On a miss it reads the database and fills the cache.", "set": {"#miss": {"opacity": 1}, "#cache": {"stroke": "var(--warning)"}, "#db": {"stroke": "var(--accent)"}}}]}
''';

class _McpRpcError implements Exception {
  const _McpRpcError(this.code, this.message);
  final int code;
  final String message;
}

/// Runs the hidden stdio entrypoint. Environment values are injected into the
/// ACP MCP-server config; no daemon token or database path is exposed.
Future<int> runBuiltInMcpServer({Map<String, String>? environment}) async {
  final Map<String, String> env = environment ?? Platform.environment;
  final String? daemonUrl = env[kMcpDaemonUrlEnv];
  final String? secret = env[kMcpSecretEnv];
  final String? sessionId = env[kMcpSessionIdEnv];
  final String? cwd = env[kMcpSessionCwdEnv];
  if (daemonUrl == null || secret == null || sessionId == null || cwd == null) {
    stderr.writeln('SpeedDial MCP environment is incomplete');
    return 64;
  }

  final _McpDaemonBridge bridge = _McpDaemonBridge(
    daemonUrl: daemonUrl,
    secret: secret,
    sessionId: sessionId,
  );
  final BuiltInMcpServer server = BuiltInMcpServer(
    sessionId: sessionId,
    cwd: cwd,
    daemonCall: bridge.call,
    onWarning: stderr.writeln,
  );
  try {
    await for (final String line
        in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.isEmpty) continue;
      Map<String, Object?>? response;
      try {
        final Object? decoded = jsonDecode(line);
        if (decoded is! Map) {
          response = <String, Object?>{
            'jsonrpc': '2.0',
            'id': null,
            'error': <String, Object?>{
              'code': -32600,
              'message': 'Invalid Request',
            },
          };
        } else {
          response = await server.handle(decoded.cast<String, Object?>());
        }
      } on FormatException {
        response = <String, Object?>{
          'jsonrpc': '2.0',
          'id': null,
          'error': <String, Object?>{'code': -32700, 'message': 'Parse error'},
        };
      }
      if (response != null) stdout.writeln(jsonEncode(response));
    }
    await stdout.flush();
    return 0;
  } finally {
    await bridge.dispose();
  }
}

class _McpDaemonBridge {
  _McpDaemonBridge({
    required this.daemonUrl,
    required this.secret,
    required this.sessionId,
  });

  final String daemonUrl;
  final String secret;
  final String sessionId;
  WebSocket? _socket;
  RpcPeer? _peer;
  StreamController<Object?>? _incoming;
  Future<void>? _connecting;

  Future<Object?> call(String method, Map<String, Object?> params) async {
    await (_connecting ??= _connect());
    return _peer!.call(method, params);
  }

  Future<void> _connect() async {
    final WebSocket socket = await WebSocket.connect(daemonUrl);
    final StreamController<Object?> incoming = StreamController<Object?>();
    final RpcPeer peer = RpcPeer(
      incoming: incoming.stream,
      send: (Object? message) => socket.add(jsonEncode(message)),
    );
    socket.listen(
      (Object? data) {
        if (data is! String) return;
        try {
          incoming.add(jsonDecode(data));
        } on FormatException {
          // The daemon only emits valid JSON; ignore a malformed transport frame.
        }
      },
      onError: incoming.addError,
      onDone: incoming.close,
    );
    _socket = socket;
    _incoming = incoming;
    _peer = peer;
    await peer.call('internal.mcpAuthenticate', <String, Object?>{
      'secret': secret,
      'sessionId': sessionId,
    });
  }

  Future<void> dispose() async {
    _peer?.close();
    await _socket?.close();
    final StreamController<Object?>? incoming = _incoming;
    if (incoming != null && !incoming.isClosed) await incoming.close();
  }
}
