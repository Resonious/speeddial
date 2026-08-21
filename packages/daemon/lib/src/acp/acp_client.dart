/// A client for the Agent Client Protocol (ACP) v1.
///
/// Talks to an agent process over newline-delimited JSON-RPC 2.0 on its
/// stdio streams. The client performs the `initialize` handshake, creates
/// sessions, drives prompt turns, and delegates agent-to-client requests
/// (`session/request_permission`, `fs/read_text_file`, `fs/write_text_file`)
/// to the handlers supplied at spawn time.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:speeddial_protocol/speeddial_protocol.dart';

import 'acp_types.dart';
import '../agents/agent_client.dart';

/// Serves `fs/read_text_file` requests from an ACP agent.
typedef AcpReadTextFileHandler = Future<String> Function(
  String sessionId,
  String path,
);
typedef AcpWriteTextFileHandler = Future<void> Function(
  String sessionId,
  String path,
  String content,
);

/// Thrown when the agent process exits while requests are still pending or
/// before initialization completes.
class AcpProcessExitedException implements Exception {
  const AcpProcessExitedException(this.message, {this.exitCode});

  final String message;
  final int? exitCode;

  @override
  String toString() =>
      'AcpProcessExitedException: $message${exitCode == null ? '' : ' (exit $exitCode)'}';
}

/// A JSON-RPC error response.
class AcpJsonRpcException implements Exception {
  const AcpJsonRpcException(this.code, this.message, [this.data]);

  final int code;
  final String message;
  final Object? data;

  @override
  String toString() => 'AcpJsonRpcException($code): $message';
}

/// A JSON-RPC request whose response is still outstanding.
class _PendingRequest {
  _PendingRequest(this.method, this.completer);

  final String method;
  final Completer<Map<String, Object?>> completer;
}

/// A `session/request_permission` request from the agent that has not yet
/// been answered.
class _PendingPermission {
  _PendingPermission(this.sessionId);

  final String sessionId;

  /// Set once a response has been sent (either the selected option or the
  /// cancelled outcome), so a late handler result cannot double-answer.
  bool responded = false;
}

/// Client for an ACP v1 agent subprocess.
///
/// Use [spawn] to launch an agent executable and drive it. All methods throw
/// [StateError] after the process has exited or the client has been disposed.
class AcpClient implements AgentClient {
  // ignore: prefer_initializing_formals — public param names are API
  AcpClient.spawn(
    List<String> command, {
    required String cwd,
    Map<String, String>? environment,
    this.initTimeout = const Duration(seconds: 30),
    AgentPermissionHandler? requestPermission,
    AcpReadTextFileHandler? readTextFile,
    AcpWriteTextFileHandler? writeTextFile,
  }) : _command = List<String>.of(command),
       _cwd = cwd, // ignore: prefer_initializing_formals — public API name
       // ignore: prefer_initializing_formals — public API name
       _environment = environment,
       _permissionHandler = requestPermission,
       _readTextFileHandler = readTextFile,
       _writeTextFileHandler = writeTextFile {
    _processFuture = _start();
  }

  final List<String> _command;
  final String _cwd;
  final Map<String, String>? _environment;
  final Duration initTimeout;
  final AgentPermissionHandler? _permissionHandler;
  final AcpReadTextFileHandler? _readTextFileHandler;
  final AcpWriteTextFileHandler? _writeTextFileHandler;

  late final Future<Process> _processFuture;

  final Map<int, _PendingRequest> _pendingRequests = <int, _PendingRequest>{};
  final Map<Object, _PendingPermission> _pendingPermissions =
      <Object, _PendingPermission>{};
  final Map<String, StreamController<AcpSessionUpdate>> _sessionStreams =
      <String, StreamController<AcpSessionUpdate>>{};
  final StreamController<String> _stderrController =
      StreamController<String>.broadcast();

  Future<InitializeResult>? _initializedFuture;
  int _nextId = 1;
  bool _exited = false;
  bool _disposed = false;
  Completer<void> _writeQueue = Completer<void>()..complete();

  /// Completes once `initialize` has been answered; re-uses the first result.
  @override
  Future<InitializeResult> get initialized =>
      _initializedFuture ??= _initialize();

  /// Lines written to the agent's stderr.
  @override
  Stream<String> get stderrLines => _stderrController.stream;

  /// Serializes writes to the process stdin so messages never interleave.
  Future<T> _serialized<T>(Future<T> Function() action) {
    final previous = _writeQueue.future;
    final done = Completer<void>();
    _writeQueue = done;
    return previous.then((_) => action()).whenComplete(done.complete);
  }

  Future<Process> _start() async {
    final process = await Process.start(
      _command.first,
      _command.skip(1).toList(),
      workingDirectory: _cwd,
      environment: _environment,
      mode: ProcessStartMode.normal,
    );
    unawaited(_readResponses(process));
    // Close the stderr controller (if still open) when stderr ends; the
    // broadcast sink keeps delivering to listeners added until then.
    unawaited(
      utf8.decoder
          .bind(process.stderr)
          .transform(const LineSplitter())
          .listen(
            (line) {
              if (!_stderrController.isClosed) _stderrController.add(line);
            },
            onError: (Object _) {},
            onDone: () => _stderrController.close(),
            cancelOnError: true,
          )
          .asFuture<void>(),
    );
    unawaited(process.exitCode.then(_onExit));
    return process;
  }

  void _onExit(int exitCode) {
    _exited = true;
    final error = AcpProcessExitedException(
      'Agent process exited.',
      exitCode: exitCode,
    );
    for (final pending in _pendingRequests.values.toList()) {
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(error);
      }
    }
    _pendingRequests.clear();
    _pendingPermissions.clear();
    for (final controller in _sessionStreams.values) {
      if (!controller.isClosed) controller.close();
    }
    _sessionStreams.clear();
  }

  Future<void> _readResponses(Process process) async {
    final lines = utf8.decoder
        .bind(process.stdout)
        .transform(const LineSplitter());
    await for (final line in lines) {
      if (line.trim().isEmpty) continue;
      Object? decoded;
      try {
        decoded = jsonDecode(line);
      } on FormatException {
        continue; // Defensive: never crash the read loop on a bad line.
      }
      if (decoded is! Map<String, Object?>) continue;
      if (decoded.containsKey('id') &&
          (decoded.containsKey('result') || decoded.containsKey('error'))) {
        _handleResponse(decoded);
      } else if (decoded['method'] is String) {
        // Process agent messages strictly in arrival order. Fire-and-forget
        // dispatch let a `session/request_permission` (whose engine callback
        // emits synchronously onto the sessionChanges/events streams) overtake
        // `session/update`s that were still queued for async stream delivery,
        // reordering the engine's event stream. Awaiting each message keeps
        // updates and request-driven emissions in wire order.
        await _handleAgentMessage(decoded);
      }
      // Anything else is ignored defensively.
    }
  }

  void _handleResponse(Map<String, Object?> message) {
    final rawId = message['id'];
    final id = rawId is num ? rawId.toInt() : null;
    if (id == null) return;
    final pending = _pendingRequests.remove(id);
    if (pending == null) return; // Stray or duplicate response.
    if (message.containsKey('error')) {
      final error = message['error'];
      if (error is Map) {
        final code = (error['code'] as num?)?.toInt() ?? -32000;
        final text = error['message'] as String? ?? 'JSON-RPC error';
        pending.completer.completeError(
          AcpJsonRpcException(code, text, error['data']),
        );
      } else {
        pending.completer.completeError(
          const AcpJsonRpcException(-32000, 'Malformed error response'),
        );
      }
      return;
    }
    final result = message['result'];
    pending.completer.complete(
      result is Map
          ? Map<String, Object?>.from(result)
          : const <String, Object?>{},
    );
  }

  Future<void> _handleAgentMessage(Map<String, Object?> message) async {
    final method = message['method'] as String? ?? '';
    final rawParams = message['params'];
    final params = rawParams is Map
        ? Map<String, Object?>.from(rawParams)
        : const <String, Object?>{};
    final rawId = message['id'];
    final id = rawId is num ? rawId.toInt() : null;
    switch (method) {
      case 'session/update':
        _handleSessionUpdate(params);
        return;
      case 'session/request_permission':
        await _handlePermissionRequest(id, params);
        return;
      case 'fs/read_text_file':
        await _handleReadTextFile(id, params);
        return;
      case 'fs/write_text_file':
        await _handleWriteTextFile(id, params);
        return;
      default:
        if (id != null) {
          await _sendResponseError(id, -32601, 'Method not found: $method');
        }
    }
  }

  void _handleSessionUpdate(Map<String, Object?> params) {
    final sessionId = params['sessionId'] as String?;
    if (sessionId == null) return;
    final rawUpdate = params['update'];
    if (rawUpdate is! Map) return;
    final AcpSessionUpdate? update;
    try {
      update = AcpSessionUpdate.parse(Map<String, Object?>.from(rawUpdate));
    } on Object {
      return; // Unknown or malformed variant: drop, never crash.
    }
    if (update == null) return; // Unknown variant: drop.
    final controller = _sessionStreams[sessionId];
    if (controller != null && !controller.isClosed) {
      controller.add(update);
    }
  }

  Future<void> _handlePermissionRequest(
    Object? id,
    Map<String, Object?> params,
  ) async {
    if (id == null) {
      return; // A permission request without an id cannot be answered.
    }
    final sessionId = params['sessionId'] as String? ?? '';
    final pending = _PendingPermission(sessionId);
    _pendingPermissions[id] = pending;
    final rawToolCall = params['toolCall'];
    String? toolCallId;
    var title = '';
    if (rawToolCall is Map) {
      final toolCall = Map<String, Object?>.from(rawToolCall);
      toolCallId = toolCall['toolCallId'] as String?;
      title = toolCall['title'] as String? ?? '';
    }
    final options = <PermissionOptionData>[];
    final rawOptions = params['options'];
    if (rawOptions is List) {
      for (final entry in rawOptions) {
        if (entry is Map) {
          options.add(
            PermissionOptionData.fromJson(Map<String, Object?>.from(entry)),
          );
        }
      }
    }
    final handler = _permissionHandler;
    if (handler == null) {
      _pendingPermissions.remove(id);
      await _sendResponseError(
        id,
        -32601,
        'Method not found: session/request_permission',
      );
      return;
    }
    String? optionId;
    try {
      optionId = await handler(sessionId, toolCallId, title, options);
    } on Object {
      // Timeout or handler failure is reported back as an internal error so
      // the agent does not wait forever. When the agent's process has already
      // exited (e.g. the engine expired the parked request on agent death),
      // the report cannot be delivered; swallow the send failure so the read
      // loop does not surface an unhandled async error.
      if (!pending.responded) {
        pending.responded = true;
        _pendingPermissions.remove(id);
        try {
          await _sendResponseError(
            id,
            -32603,
            'Permission request handler failed',
          );
        } on Object {
          // Agent process is gone; nothing left to report to.
        }
      }
      return;
    }
    if (!pending.responded) {
      pending.responded = true;
      _pendingPermissions.remove(id);
      await _sendResponse(id, <String, Object?>{
        'outcome': <String, Object?>{
          'outcome': 'selected',
          'optionId': optionId,
        },
      });
    }
  }

  Future<void> _handleReadTextFile(
    Object? id,
    Map<String, Object?> params,
  ) async {
    if (id == null) return;
    final sessionId = params['sessionId'] as String? ?? '';
    final path = params['path'] as String? ?? '';
    final handler = _readTextFileHandler;
    if (handler == null) {
      await _sendResponseError(
        id,
        -32601,
        'Method not found: fs/read_text_file',
      );
      return;
    }
    try {
      final content = await handler(sessionId, path);
      await _sendResponse(id, <String, Object?>{'content': content});
    } on Object {
      await _sendResponseError(id, -32603, 'Read text file handler failed');
    }
  }

  Future<void> _handleWriteTextFile(
    Object? id,
    Map<String, Object?> params,
  ) async {
    if (id == null) return;
    final sessionId = params['sessionId'] as String? ?? '';
    final path = params['path'] as String? ?? '';
    final content = params['content'] as String? ?? '';
    final handler = _writeTextFileHandler;
    if (handler == null) {
      await _sendResponseError(
        id,
        -32601,
        'Method not found: fs/write_text_file',
      );
      return;
    }
    try {
      await handler(sessionId, path, content);
      await _sendResponse(id, const <String, Object?>{});
    } on Object {
      await _sendResponseError(id, -32603, 'Write text file handler failed');
    }
  }

  Future<InitializeResult> _initialize() async {
    final result = await _request('initialize', <String, Object?>{
      'protocolVersion': 1,
      'clientCapabilities': <String, Object?>{
        'fs': <String, Object?>{'readTextFile': true, 'writeTextFile': true},
        'terminal': false,
      },
      'clientInfo': <String, Object?>{
        'name': 'speeddial',
        'title': 'SpeedDial',
        'version': '0.1.0',
      },
    }).timeout(initTimeout);
    return InitializeResult.fromJson(result);
  }

  /// Authenticates with the given advertised method id.
  @override
  Future<void> authenticate(String methodId) async {
    await _request('authenticate', <String, Object?>{'methodId': methodId});
  }

  /// Creates a new session with the supplied MCP server connections,
  /// returning its id plus the session config options the agent advertised.
  @override
  Future<({String sessionId, List<AcpConfigOption> configOptions})> newSession({
    required String cwd,
    List<Map<String, Object?>> mcpServers = const <Map<String, Object?>>[],
    String? model,
    SessionSandboxMode? sandboxMode,
    bool yolo = false,
  }) async {
    final result = await _request('session/new', <String, Object?>{
      'cwd': cwd,
      'mcpServers': mcpServers,
    });
    final sessionId = result['sessionId'];
    if (sessionId is! String || sessionId.isEmpty) {
      throw const FormatException('session/new response missing sessionId');
    }
    return (
      sessionId: sessionId,
      configOptions: AcpConfigOption.listFrom(result['configOptions']),
    );
  }

  /// Resumes a previously created session (ACP `session/load`) so a session
  /// survives an agent/daemon restart. Only agents advertising the
  /// `loadSession` capability in [InitializeResult.agentCapabilities]
  /// support it; others answer with a JSON-RPC error.
  ///
  /// Returns the session config options the agent advertised (empty when
  /// the agent reports none). [mcpServers] reconnects the same tools that
  /// were present when the session was created.
  @override
  Future<List<AcpConfigOption>> loadSession({
    required String sessionId,
    required String cwd,
    SessionSandboxMode? sandboxMode,
    List<Map<String, Object?>> mcpServers = const <Map<String, Object?>>[],
  }) async {
    final result = await _request('session/load', <String, Object?>{
      'sessionId': sessionId,
      'cwd': cwd,
      'mcpServers': mcpServers,
    });
    return AcpConfigOption.listFrom(result['configOptions']);
  }

  /// Sets the value of a session config option (ACP
  /// `session/set_config_option`), returning the agent's full updated
  /// config options list (empty when the agent reports none).
  @override
  Future<List<AcpConfigOption>> setConfigOption(
    String sessionId,
    String configId,
    String value,
  ) async {
    final result = await _request(
      'session/set_config_option',
      <String, Object?>{
        'sessionId': sessionId,
        'configId': configId,
        'value': value,
      },
    );
    return AcpConfigOption.listFrom(result['configOptions']);
  }

  /// Stream of updates emitted by the agent for the given session.
  ///
  /// A broadcast stream is created on first access; updates emitted before
  /// the first listener is attached are dropped.
  @override
  Stream<AcpSessionUpdate> sessionUpdates(String sessionId) {
    final controller = _sessionStreams.putIfAbsent(
      sessionId,
      StreamController<AcpSessionUpdate>.broadcast,
    );
    return controller.stream;
  }

  /// Sends a prompt and awaits the agent's stop reason.
  ///
  /// [promptBlocks] are the ACP prompt content blocks (text, image, resource)
  /// sent verbatim as the request's `prompt` parameter; empty for a turn
  /// without any content.
  @override
  Future<PromptResult> prompt(
    String sessionId,
    List<Map<String, Object?>> promptBlocks,
  ) async {
    final result = await _request('session/prompt', <String, Object?>{
      'sessionId': sessionId,
      'prompt': promptBlocks,
    });
    return PromptResult.fromJson(result);
  }

  /// Cancels the ongoing prompt turn for the session.
  ///
  /// Sends the `session/cancel` notification and answers any pending
  /// permission requests with the cancelled outcome, per the ACP spec.
  @override
  Future<void> cancel(String sessionId) async {
    // Answer pending permission requests first so the agent cannot hang.
    final pending = _pendingPermissions.entries.toList();
    for (final entry in pending) {
      final permission = entry.value;
      if (permission.sessionId == sessionId && !permission.responded) {
        permission.responded = true;
        _pendingPermissions.remove(entry.key);
        await _sendResponse(entry.key, <String, Object?>{
          'outcome': <String, Object?>{'outcome': 'cancelled'},
        });
      }
    }
    await _sendNotification('session/cancel', <String, Object?>{
      'sessionId': sessionId,
    });
  }

  /// Switches the session to the given mode id.
  @override
  Future<void> setMode(String sessionId, String modeId) async {
    await _request('session/set_mode', <String, Object?>{
      'sessionId': sessionId,
      'modeId': modeId,
    });
  }

  /// Sends a request and awaits its response.
  Future<Map<String, Object?>> _request(
    String method,
    Map<String, Object?> params,
  ) async {
    if (_disposed) {
      throw StateError('AcpClient has been disposed.');
    }
    final id = _nextId++;
    final completer = Completer<Map<String, Object?>>();
    _pendingRequests[id] = _PendingRequest(method, completer);
    try {
      await _sendRaw(<String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      });
    } on Object {
      // The completer has no listener (the rethrow below carries the error to
      // the caller), so it must not be errored here: completing it would raise
      // an unhandled async error. The pending entry is dropped so a late
      // response cannot complete it either.
      _pendingRequests.remove(id);
      rethrow;
    }
    return completer.future;
  }

  Future<void> _sendNotification(String method, Map<String, Object?> params) {
    return _sendRaw(<String, Object?>{
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
    });
  }

  Future<void> _sendResponse(Object id, Map<String, Object?> result) {
    return _sendRaw(<String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'result': result,
    });
  }

  Future<void> _sendResponseError(Object id, int code, String message) {
    return _sendRaw(<String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'error': <String, Object?>{'code': code, 'message': message},
    });
  }

  Future<void> _sendRaw(Map<String, Object?> message) async {
    final json = jsonEncode(message);
    await _serialized(() async {
      if (_disposed || _exited) {
        throw StateError('Agent process is not running.');
      }
      final process = await _processFuture;
      process.stdin.writeln(json);
    });
  }

  /// Terminates the agent process and fails any pending work.
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    Process? process;
    try {
      process = await _processFuture;
    } on Object {
      // The process never started; nothing to kill.
    }
    if (process != null) {
      final p = process;
      try {
        p.stdin.close();
      } on Object {
        // stdin may already be closed.
      }
      try {
        await p.exitCode.timeout(
          const Duration(seconds: 3),
          onTimeout: () {
            try {
              p.kill(ProcessSignal.sigkill);
            } on Object {
              // Already gone.
            }
            return -1;
          },
        );
      } on Object {
        // Process handle error is not fatal for disposal.
      }
    }
    final error = StateError('AcpClient has been disposed.');
    for (final pending in _pendingRequests.values.toList()) {
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(error);
      }
    }
    _pendingRequests.clear();
    _pendingPermissions.clear();
    for (final controller in _sessionStreams.values) {
      if (!controller.isClosed) controller.close();
    }
    _sessionStreams.clear();
    if (!_stderrController.isClosed) _stderrController.close();
  }
}
