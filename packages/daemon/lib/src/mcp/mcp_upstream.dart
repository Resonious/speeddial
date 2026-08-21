/// MCP stdio and Streamable HTTP clients owned by the SpeedDial daemon.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../store/daemon_store.dart';

const String _kLatestMcpVersion = '2025-11-25';
const Set<String> _kSupportedMcpVersions = <String>{
  '2024-11-05',
  '2025-03-26',
  '2025-06-18',
  _kLatestMcpVersion,
};
const int _kMaxHttpBodyBytes = 16 * 1024 * 1024;

typedef McpUpstreamConnector = Future<McpUpstreamConnection> Function(
  StoredMcpServer server,
  String cwd,
);

typedef McpProcessStarter = Future<Process> Function(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
  required Map<String, String> environment,
});

/// One HTTP exchange used by the Streamable HTTP MCP transport.
class McpHttpResponse {
  const McpHttpResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
  });

  final int statusCode;
  final Map<String, String> headers;
  final Stream<List<int>> body;
}

/// Injectable transport boundary; production uses [IoMcpHttpTransport].
abstract interface class McpHttpTransport {
  Future<McpHttpResponse> send({
    required String method,
    required Uri url,
    required Map<String, String> headers,
    String? body,
  });

  Future<void> close();
}

/// `dart:io` implementation of Streamable HTTP requests.
class IoMcpHttpTransport implements McpHttpTransport {
  IoMcpHttpTransport({
    this.timeout = const Duration(seconds: 30),
    HttpClient? client,
  }) : _client = client ?? HttpClient();

  final Duration timeout;
  final HttpClient _client;

  @override
  Future<McpHttpResponse> send({
    required String method,
    required Uri url,
    required Map<String, String> headers,
    String? body,
  }) async {
    final HttpClientRequest request = await _client
        .openUrl(method, url)
        .timeout(timeout);
    for (final MapEntry<String, String> header in headers.entries) {
      request.headers.set(header.key, header.value);
    }
    if (body != null) request.write(body);
    final HttpClientResponse response = await request.close().timeout(timeout);
    final Map<String, String> responseHeaders = <String, String>{};
    response.headers.forEach((String name, List<String> values) {
      responseHeaders[name.toLowerCase()] = values.join(',');
    });
    return McpHttpResponse(
      statusCode: response.statusCode,
      headers: responseHeaders,
      body: response,
    );
  }

  @override
  Future<void> close() async => _client.close(force: true);
}

/// Initialized connection to one configured upstream MCP server.
abstract interface class McpUpstreamConnection {
  Future<List<Map<String, Object?>>> listTools();

  Future<Map<String, Object?>> callTool(
    String name,
    Map<String, Object?> arguments,
  );

  Future<void> close();
}

/// Opens and initializes one configured upstream MCP transport.
Future<McpUpstreamConnection> connectMcpUpstream(
  StoredMcpServer stored,
  String cwd, {
  McpProcessStarter? processStarter,
  McpHttpTransport? httpTransport,
  Duration timeout = const Duration(seconds: 30),
}) => switch (stored.profile.transport) {
  McpTransport.stdio => _StdioMcpConnection.connect(
    stored,
    cwd,
    processStarter: processStarter,
    timeout: timeout,
  ),
  McpTransport.http => _HttpMcpConnection.connect(
    stored,
    cwd,
    transport: httpTransport,
    timeout: timeout,
  ),
};

class _StdioMcpConnection implements McpUpstreamConnection {
  _StdioMcpConnection({
    required Process process,
    required this.cwd,
    required this.timeout,
  }) : _process = process {
    _stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleLine, onError: _fail, onDone: _handleStdoutDone);
    _stderrSubscription = process.stderr.drain<void>();
    unawaited(process.exitCode.then(_handleExit));
  }

  static Future<_StdioMcpConnection> connect(
    StoredMcpServer stored,
    String cwd, {
    required McpProcessStarter? processStarter,
    required Duration timeout,
  }) async {
    final McpProcessStarter start = processStarter ?? _startMcpProcess;
    final Process process = await start(
      stored.profile.command!,
      stored.profile.args,
      workingDirectory: cwd,
      environment: stored.secrets,
    );
    final _StdioMcpConnection connection = _StdioMcpConnection(
      process: process,
      cwd: cwd,
      timeout: timeout,
    );
    try {
      await connection._initialize();
      return connection;
    } on Object {
      await connection.close();
      rethrow;
    }
  }

  final Process _process;
  final String cwd;
  final Duration timeout;
  final Map<int, Completer<Map<String, Object?>>> _pending =
      <int, Completer<Map<String, Object?>>>{};
  late final StreamSubscription<String> _stdoutSubscription;
  late final Future<void> _stderrSubscription;
  Future<void> _writeQueue = Future<void>.value();
  int _nextId = 1;
  bool _closed = false;
  bool _closing = false;

  Future<void> _initialize() async {
    final Map<String, Object?> result = await _request(
      'initialize',
      <String, Object?>{
        'protocolVersion': _kLatestMcpVersion,
        'capabilities': <String, Object?>{
          'roots': <String, Object?>{'listChanged': false},
        },
        'clientInfo': <String, Object?>{
          'name': 'speeddial',
          'title': 'SpeedDial MCP proxy',
          'version': '0.1.0',
        },
      },
    );
    _validateProtocolVersion(result);
    await _send(<String, Object?>{
      'jsonrpc': '2.0',
      'method': 'notifications/initialized',
    });
  }

  @override
  Future<List<Map<String, Object?>>> listTools() => _listAllTools(_request);

  @override
  Future<Map<String, Object?>> callTool(
    String name,
    Map<String, Object?> arguments,
  ) => _request('tools/call', <String, Object?>{
    'name': name,
    'arguments': arguments,
  });

  Future<Map<String, Object?>> _request(
    String method,
    Map<String, Object?> params,
  ) async {
    if (_closed) throw StateError('MCP stdio connection is closed');
    final int id = _nextId++;
    final Completer<Map<String, Object?>> completer =
        Completer<Map<String, Object?>>();
    _pending[id] = completer;
    try {
      await _send(<String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      });
      final Map<String, Object?> response = await completer.future.timeout(
        timeout,
        onTimeout: () {
          unawaited(
            _send(<String, Object?>{
              'jsonrpc': '2.0',
              'method': 'notifications/cancelled',
              'params': <String, Object?>{
                'requestId': id,
                'reason': 'SpeedDial MCP request timed out',
              },
            }),
          );
          throw TimeoutException('MCP request "$method" timed out', timeout);
        },
      );
      return _responseResult(response);
    } finally {
      _pending.remove(id);
    }
  }

  void _handleLine(String line) {
    if (line.isEmpty || _closed) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException catch (error) {
      _fail(FormatException('Invalid MCP stdout JSON: ${error.message}'));
      return;
    }
    if (decoded is! Map) {
      _fail(const FormatException('MCP stdout message must be an object'));
      return;
    }
    final Map<String, Object?> message = decoded.cast<String, Object?>();
    final Object? id = message['id'];
    if (id is int && !message.containsKey('method')) {
      final Completer<Map<String, Object?>>? completer = _pending[id];
      if (completer != null && !completer.isCompleted) {
        completer.complete(message);
      }
      return;
    }
    if (message['method'] is String && message.containsKey('id')) {
      unawaited(_answerServerRequest(message));
    }
  }

  Future<void> _answerServerRequest(Map<String, Object?> request) async {
    final Map<String, Object?> response = _clientResponse(request, cwd);
    try {
      await _send(response);
    } on Object catch (error) {
      _fail(error);
    }
  }

  Future<void> _send(Map<String, Object?> message) {
    final Completer<void> completer = Completer<void>();
    _writeQueue = _writeQueue
        .then((_) async {
          if (_closed) throw StateError('MCP stdio connection is closed');
          _process.stdin.writeln(jsonEncode(message));
          await _process.stdin.flush();
        })
        .then(completer.complete, onError: completer.completeError);
    // Keep the queue alive after one failed write; callers still receive the
    // original error through [completer].
    _writeQueue = _writeQueue.catchError((Object _) {});
    return completer.future;
  }

  void _handleStdoutDone() {
    if (!_closing) _fail(StateError('MCP server closed stdout'));
  }

  void _handleExit(int code) {
    if (!_closing) _fail(StateError('MCP server exited with status $code'));
  }

  void _fail(Object error) {
    if (_closed) return;
    _closed = true;
    for (final Completer<Map<String, Object?>> completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
  }

  @override
  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    _closed = true;
    for (final Completer<Map<String, Object?>> completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('MCP stdio connection closed'));
      }
    }
    _pending.clear();
    await _stdoutSubscription.cancel();
    try {
      await _process.stdin.close();
    } on Object {
      // The process may already have closed its input.
    }
    try {
      await _process.exitCode.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      _process.kill();
      try {
        await _process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        if (!Platform.isWindows) _process.kill(ProcessSignal.sigkill);
      }
    }
    await _stderrSubscription;
  }
}

class _HttpMcpConnection implements McpUpstreamConnection {
  _HttpMcpConnection({
    required this.url,
    required this.cwd,
    required this.headers,
    required this.transport,
    required this.timeout,
  });

  static Future<_HttpMcpConnection> connect(
    StoredMcpServer stored,
    String cwd, {
    required McpHttpTransport? transport,
    required Duration timeout,
  }) async {
    final _HttpMcpConnection connection = _HttpMcpConnection(
      url: Uri.parse(stored.profile.url!),
      cwd: cwd,
      headers: Map<String, String>.unmodifiable(stored.secrets),
      transport: transport ?? IoMcpHttpTransport(timeout: timeout),
      timeout: timeout,
    );
    try {
      await connection._ensureInitialized();
      return connection;
    } on Object {
      await connection.close();
      rethrow;
    }
  }

  final Uri url;
  final String cwd;
  final Map<String, String> headers;
  final McpHttpTransport transport;
  final Duration timeout;
  int _nextId = 1;
  String? _sessionId;
  String? _protocolVersion;
  Future<void>? _initializing;
  Future<void>? _restarting;
  bool _initialized = false;
  bool _closed = false;

  Future<void> _ensureInitialized() {
    if (_closed) throw StateError('MCP HTTP connection is closed');
    if (_initialized) return Future<void>.value();
    final Future<void>? active = _initializing;
    if (active != null) return active;
    final Future<void> initializing = _initialize();
    _initializing = initializing;
    return initializing.whenComplete(() {
      if (identical(_initializing, initializing)) _initializing = null;
    });
  }

  Future<void> _initialize() async {
    final int id = _nextId++;
    final Map<String, Object?> response = await _exchangeRequest(
      <String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'method': 'initialize',
        'params': <String, Object?>{
          'protocolVersion': _kLatestMcpVersion,
          'capabilities': <String, Object?>{
            'roots': <String, Object?>{'listChanged': false},
          },
          'clientInfo': <String, Object?>{
            'name': 'speeddial',
            'title': 'SpeedDial MCP proxy',
            'version': '0.1.0',
          },
        },
      },
      id,
      initializing: true,
    );
    final Map<String, Object?> result = _responseResult(response);
    _protocolVersion = _validateProtocolVersion(result);
    await _sendOneWay(<String, Object?>{
      'jsonrpc': '2.0',
      'method': 'notifications/initialized',
    });
    _initialized = true;
  }

  @override
  Future<List<Map<String, Object?>>> listTools() async {
    await _ensureInitialized();
    return _listAllTools(_request);
  }

  @override
  Future<Map<String, Object?>> callTool(
    String name,
    Map<String, Object?> arguments,
  ) async {
    await _ensureInitialized();
    return _request('tools/call', <String, Object?>{
      'name': name,
      'arguments': arguments,
    });
  }

  Future<Map<String, Object?>> _request(
    String method,
    Map<String, Object?> params,
  ) async {
    await _ensureInitialized();
    final int id = _nextId++;
    final Map<String, Object?> request = <String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    };
    try {
      return _responseResult(await _exchangeRequest(request, id));
    } on _McpSessionExpired {
      await _restartSession();
      return _responseResult(await _exchangeRequest(request, id));
    }
  }

  Future<void> _restartSession() {
    final Future<void>? active = _restarting;
    if (active != null) return active;
    final Future<void> restarting = () async {
      _initialized = false;
      _sessionId = null;
      _protocolVersion = null;
      _initializing = null;
      await _ensureInitialized();
    }();
    _restarting = restarting;
    return restarting.whenComplete(() {
      if (identical(_restarting, restarting)) _restarting = null;
    });
  }

  Future<Map<String, Object?>> _exchangeRequest(
    Map<String, Object?> message,
    Object id, {
    bool initializing = false,
  }) async {
    final DateTime deadline = DateTime.now().add(timeout);
    String method = 'POST';
    String? lastEventId;
    Duration retryDelay = const Duration(seconds: 1);

    while (true) {
      final McpHttpResponse response = await transport
          .send(
            method: method,
            url: url,
            headers: _requestHeaders(
              sseOnly: method == 'GET',
              initializing: initializing,
              lastEventId: lastEventId,
            ),
            body: method == 'POST' ? jsonEncode(message) : null,
          )
          .timeout(_remaining(deadline));
      if (initializing) {
        _sessionId = response.headers['mcp-session-id'];
      }
      if (response.statusCode == HttpStatus.notFound && _sessionId != null) {
        await response.body.drain<void>();
        throw const _McpSessionExpired();
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final String body = await _readBody(response.body, deadline: deadline);
        throw StateError(
          'MCP HTTP ${response.statusCode}${body.isEmpty ? '' : ': $body'}',
        );
      }

      final String mediaType = _mediaType(response.headers['content-type']);
      if (mediaType == 'application/json') {
        final String body = await _readBody(response.body, deadline: deadline);
        final Object? decoded = jsonDecode(body);
        if (decoded is! Map) {
          throw const FormatException('MCP HTTP response must be an object');
        }
        return decoded.cast<String, Object?>();
      }
      if (mediaType != 'text/event-stream') {
        await response.body.drain<void>();
        throw StateError('Unsupported MCP HTTP content type: $mediaType');
      }

      final _SseResult result = await _readSseResponse(
        response.body,
        expectedId: id,
        deadline: deadline,
      );
      if (result.response != null) return result.response!;
      lastEventId = result.lastEventId;
      retryDelay = result.retryDelay;
      if (lastEventId == null) {
        throw StateError('MCP SSE stream ended before its response');
      }
      final Duration remaining = _remaining(deadline);
      if (retryDelay >= remaining) {
        throw TimeoutException('MCP SSE response timed out', timeout);
      }
      await Future<void>.delayed(retryDelay);
      method = 'GET';
      initializing = false;
    }
  }

  Future<_SseResult> _readSseResponse(
    Stream<List<int>> body, {
    required Object expectedId,
    required DateTime deadline,
  }) async {
    final StreamIterator<String> lines = StreamIterator<String>(
      body.transform(utf8.decoder).transform(const LineSplitter()),
    );
    final List<String> data = <String>[];
    String? lastEventId;
    Duration retryDelay = const Duration(seconds: 1);

    Future<Map<String, Object?>?> dispatchEvent() async {
      if (data.isEmpty) return null;
      final String payload = data.join('\n');
      data.clear();
      if (payload.isEmpty) return null;
      final Object? decoded = jsonDecode(payload);
      if (decoded is! Map) {
        throw const FormatException('MCP SSE data must be an object');
      }
      final Map<String, Object?> message = decoded.cast<String, Object?>();
      if (message['id'] == expectedId && !message.containsKey('method')) {
        return message;
      }
      if (message['method'] is String && message.containsKey('id')) {
        await _sendOneWay(_clientResponse(message, cwd));
      }
      return null;
    }

    try {
      while (await lines.moveNext().timeout(_remaining(deadline))) {
        final String line = lines.current;
        if (line.isEmpty) {
          final Map<String, Object?>? response = await dispatchEvent();
          if (response != null) {
            return _SseResult(
              response: response,
              lastEventId: lastEventId,
              retryDelay: retryDelay,
            );
          }
          continue;
        }
        if (line.startsWith(':')) continue;
        final int separator = line.indexOf(':');
        final String field = separator < 0
            ? line
            : line.substring(0, separator);
        String value = separator < 0 ? '' : line.substring(separator + 1);
        if (value.startsWith(' ')) value = value.substring(1);
        switch (field) {
          case 'data':
            data.add(value);
          case 'id':
            if (!value.contains('\u0000')) lastEventId = value;
          case 'retry':
            final int? milliseconds = int.tryParse(value);
            if (milliseconds != null && milliseconds >= 0) {
              retryDelay = Duration(milliseconds: milliseconds);
            }
        }
      }
      final Map<String, Object?>? response = await dispatchEvent();
      return _SseResult(
        response: response,
        lastEventId: lastEventId,
        retryDelay: retryDelay,
      );
    } finally {
      await lines.cancel();
    }
  }

  Future<void> _sendOneWay(Map<String, Object?> message) async {
    final McpHttpResponse response = await transport
        .send(
          method: 'POST',
          url: url,
          headers: _requestHeaders(),
          body: jsonEncode(message),
        )
        .timeout(timeout);
    await response.body.drain<void>().timeout(timeout);
    if (response.statusCode != HttpStatus.accepted &&
        response.statusCode != HttpStatus.noContent) {
      throw StateError('MCP HTTP notification returned ${response.statusCode}');
    }
  }

  Map<String, String> _requestHeaders({
    bool sseOnly = false,
    bool initializing = false,
    String? lastEventId,
  }) {
    final Map<String, String> result = <String, String>{...headers};
    result['Accept'] = sseOnly
        ? 'text/event-stream'
        : 'application/json, text/event-stream';
    if (!sseOnly) result['Content-Type'] = 'application/json';
    if (!initializing) {
      final String? sessionId = _sessionId;
      final String? protocolVersion = _protocolVersion;
      if (sessionId != null) result['MCP-Session-Id'] = sessionId;
      if (protocolVersion != null) {
        result['MCP-Protocol-Version'] = protocolVersion;
      }
    }
    if (lastEventId != null) result['Last-Event-ID'] = lastEventId;
    return result;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final String? sessionId = _sessionId;
    if (sessionId != null) {
      try {
        final McpHttpResponse response = await transport
            .send(method: 'DELETE', url: url, headers: _requestHeaders())
            .timeout(const Duration(seconds: 2));
        await response.body.drain<void>().timeout(const Duration(seconds: 2));
      } on Object {
        // Session cleanup is best effort; the transport is closed below.
      }
    }
    await transport.close();
  }
}

Future<Process> _startMcpProcess(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
  required Map<String, String> environment,
}) => Process.start(
  executable,
  arguments,
  workingDirectory: workingDirectory,
  environment: environment,
  includeParentEnvironment: true,
  mode: ProcessStartMode.normal,
);

Future<List<Map<String, Object?>>> _listAllTools(
  Future<Map<String, Object?>> Function(
    String method,
    Map<String, Object?> params,
  )
  request,
) async {
  final List<Map<String, Object?>> tools = <Map<String, Object?>>[];
  final Set<String> cursors = <String>{};
  String? cursor;
  do {
    final Map<String, Object?> result = await request(
      'tools/list',
      <String, Object?>{'cursor': ?cursor},
    );
    final Object? rawTools = result['tools'];
    if (rawTools is! List) {
      throw const FormatException('MCP tools/list result has no tools array');
    }
    for (final Object? rawTool in rawTools) {
      if (rawTool is! Map) {
        throw const FormatException('MCP tool descriptor must be an object');
      }
      tools.add(Map<String, Object?>.from(rawTool.cast<String, Object?>()));
    }
    final Object? rawCursor = result['nextCursor'];
    if (rawCursor == null) {
      cursor = null;
    } else if (rawCursor is String && rawCursor.isNotEmpty) {
      if (!cursors.add(rawCursor)) {
        throw const FormatException('MCP tools/list repeated its cursor');
      }
      cursor = rawCursor;
    } else {
      throw const FormatException('MCP tools/list returned an invalid cursor');
    }
  } while (cursor != null);
  return List<Map<String, Object?>>.unmodifiable(tools);
}

Map<String, Object?> _responseResult(Map<String, Object?> response) {
  final Object? rawError = response['error'];
  if (rawError is Map) {
    final Map<String, Object?> error = rawError.cast<String, Object?>();
    throw _McpRemoteError(
      code: error['code'] is int ? error['code']! as int : -32603,
      message: error['message'] is String
          ? error['message']! as String
          : 'Unknown MCP error',
    );
  }
  final Object? rawResult = response['result'];
  if (rawResult is! Map) {
    throw const FormatException('MCP response result must be an object');
  }
  return rawResult.cast<String, Object?>();
}

String _validateProtocolVersion(Map<String, Object?> result) {
  final Object? rawVersion = result['protocolVersion'];
  if (rawVersion is! String || !_kSupportedMcpVersions.contains(rawVersion)) {
    throw FormatException('Unsupported MCP protocol version: $rawVersion');
  }
  return rawVersion;
}

Map<String, Object?> _clientResponse(Map<String, Object?> request, String cwd) {
  final Object? id = request['id'];
  final Object? rawMethod = request['method'];
  final Object result;
  if (rawMethod == 'roots/list') {
    result = <String, Object?>{
      'roots': <Object?>[
        <String, Object?>{
          'uri': Directory(cwd).absolute.uri.toString(),
          'name': p.basename(Directory(cwd).absolute.path),
        },
      ],
    };
  } else if (rawMethod == 'ping') {
    result = const <String, Object?>{};
  } else {
    return <String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'error': <String, Object?>{'code': -32601, 'message': 'Method not found'},
    };
  }
  return <String, Object?>{'jsonrpc': '2.0', 'id': id, 'result': result};
}

Future<String> _readBody(
  Stream<List<int>> body, {
  required DateTime deadline,
}) async {
  final BytesBuilder bytes = BytesBuilder(copy: false);
  await for (final List<int> chunk in body.timeout(_remaining(deadline))) {
    if (bytes.length + chunk.length > _kMaxHttpBodyBytes) {
      throw const FormatException('MCP HTTP response exceeds 16 MiB');
    }
    bytes.add(chunk);
  }
  return utf8.decode(bytes.takeBytes());
}

Duration _remaining(DateTime deadline) {
  final Duration remaining = deadline.difference(DateTime.now());
  if (remaining <= Duration.zero) {
    throw TimeoutException('MCP HTTP request timed out');
  }
  return remaining;
}

String _mediaType(String? contentType) =>
    (contentType ?? '').split(';').first.trim().toLowerCase();

class _SseResult {
  const _SseResult({
    required this.response,
    required this.lastEventId,
    required this.retryDelay,
  });

  final Map<String, Object?>? response;
  final String? lastEventId;
  final Duration retryDelay;
}

class _McpRemoteError implements Exception {
  const _McpRemoteError({required this.code, required this.message});

  final int code;
  final String message;

  @override
  String toString() => 'MCP error $code: $message';
}

class _McpSessionExpired implements Exception {
  const _McpSessionExpired();
}
