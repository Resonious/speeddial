/// Built-in MCP stdio server exposed to every SpeedDial agent session.
///
/// The agent launches this process from the ACP `mcpServers` configuration.
/// It speaks newline-delimited MCP JSON-RPC on stdio and uses a private,
/// authenticated WebSocket bridge back to the owning daemon for searches,
/// session archiving, and user-visible image events.
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
      'instructions': 'Search other SpeedDial projects and sessions, browse session transcripts, archive or revive other sessions, or display an image in the user timeline.',
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
        'search_projects' => await _searchProjects(arguments),
        'search_sessions' => await _searchSessions(arguments),
        'read_session_transcript' => await _readSessionTranscript(arguments),
        'archive_session' => await _setSessionArchived(arguments, true),
        'unarchive_session' => await _setSessionArchived(arguments, false),
        'display_image' => await _displayImage(arguments),
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
      final File file = _confinedFile(path);
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

  File _confinedFile(String requestedPath) {
    final String candidate = p.isAbsolute(requestedPath)
        ? p.normalize(requestedPath)
        : p.normalize(p.join(_cwd, requestedPath));
    final File file = File(candidate);
    if (!file.existsSync()) {
      throw ArgumentError('image file not found: $requestedPath');
    }
    final String realRoot = Directory(_cwd).resolveSymbolicLinksSync();
    final String realFile = file.resolveSymbolicLinksSync();
    final String prefix = realRoot.endsWith(p.separator)
        ? realRoot
        : '$realRoot${p.separator}';
    if (realFile != realRoot && !realFile.startsWith(prefix)) {
      throw ArgumentError('image path escapes the session working directory');
    }
    return File(realFile);
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
      'name': 'display_image',
      'title': 'Display an image',
      'description': 'Display an image in the user\'s SpeedDial timeline and return it to the model. Provide a session-relative path or base64 data.',
      'inputSchema': <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'path': <String, Object?>{
            'type': 'string',
            'description':
                'Image path inside the current session working directory.',
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
  ];
}

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
