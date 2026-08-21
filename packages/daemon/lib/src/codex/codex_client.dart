import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../acp/acp_types.dart';

import '../agents/agent_client.dart';

String _codexSandboxMode(SessionSandboxMode? mode) =>
    switch (mode ?? SessionSandboxMode.workspaceWrite) {
      SessionSandboxMode.workspaceWrite => 'workspace-write',
      SessionSandboxMode.unrestricted => 'danger-full-access',
    };

/// A failed Codex turn, reported by `turn/completed`.
class CodexTurnException implements Exception {
  const CodexTurnException(this.message);

  final String message;

  @override
  String toString() => 'CodexTurnException: $message';
}

/// A JSON-RPC error returned by `codex app-server`.
class CodexJsonRpcException implements Exception {
  const CodexJsonRpcException(this.code, this.message, [this.data]);

  final int code;
  final String message;
  final Object? data;

  @override
  String toString() => 'Codex JSON-RPC error $code: $message';
}

/// Direct JSONL client for Codex's native `app-server` protocol.
///
/// Codex items are translated into the engine's provider-neutral update
/// vocabulary without passing through ACP. Structured command, patch, MCP,
/// collaboration, web-search, image, plan, reasoning, usage, and lifecycle
/// fields remain available through tool-call content and raw payloads.
class CodexClient implements AgentClient {
  CodexClient.spawn(
    List<String> command, {
    required String cwd,
    Map<String, String>? environment,
    AgentPermissionHandler? requestPermission,
    this.initTimeout = const Duration(seconds: 30),
  }) : _command = List<String>.of(command),
       // ignore: prefer_initializing_formals — public API name
       _cwd = cwd,
       // ignore: prefer_initializing_formals — public API name
       _environment = environment,
       _permissionHandler = requestPermission {
    if (_command.isEmpty) {
      throw ArgumentError.value(command, 'command', 'must not be empty');
    }
  }

  final List<String> _command;
  final String _cwd;
  final Map<String, String>? _environment;
  final AgentPermissionHandler? _permissionHandler;
  final Duration initTimeout;

  Process? _process;
  Future<void>? _startFuture;
  Future<InitializeResult>? _initializedFuture;
  Completer<void> _writeQueue = Completer<void>()..complete();
  final StreamController<String> _stderrController =
      StreamController<String>.broadcast();
  final Map<Object, Completer<Map<String, Object?>>> _pending =
      <Object, Completer<Map<String, Object?>>>{};
  final Map<String, _CodexSessionState> _sessions =
      <String, _CodexSessionState>{};
  final Map<String, _SessionChannel> _sessionChannels =
      <String, _SessionChannel>{};
  final Map<String, String> _turnThreads = <String, String>{};
  final Map<String, _CodexToolState> _tools = <String, _CodexToolState>{};
  final Map<String, StringBuffer> _messageDeltas = <String, StringBuffer>{};
  final Map<String, StringBuffer> _reasoningDeltas = <String, StringBuffer>{};
  final Set<String> _completedMessages = <String>{};
  final Map<String, String> _turnErrors = <String, String>{};
  List<_CodexModel> _models = const <_CodexModel>[];
  int _nextRequestId = 1;
  int _activitySerial = 0;
  bool _exited = false;
  bool _disposed = false;
  bool _controllersClosed = false;

  @override
  Future<InitializeResult> get initialized =>
      _initializedFuture ??= _initialize().timeout(initTimeout);

  @override
  Stream<String> get stderrLines => _stderrController.stream;

  Future<InitializeResult> _initialize() async {
    await _ensureStarted();
    await _request('initialize', <String, Object?>{
      'clientInfo': <String, Object?>{
        'name': 'speeddial',
        'title': 'SpeedDial',
        'version': '0.1.0',
      },
      'capabilities': <String, Object?>{'experimentalApi': true},
    });
    await _notify('initialized', const <String, Object?>{});
    _models = await _loadModels();
    return const InitializeResult(
      protocolVersion: 2,
      agentCapabilities: <String, Object?>{
        'loadSession': true,
        'mcpServers': true,
        'mcpCapabilities': <String, Object?>{'http': false},
      },
      authMethods: <String>[],
    );
  }

  @override
  Future<void> authenticate(String methodId) async {
    throw UnsupportedError('Codex authentication is managed by the Codex CLI.');
  }

  @override
  Future<({String sessionId, List<AcpConfigOption> configOptions})> newSession({
    required String cwd,
    List<Map<String, Object?>> mcpServers = const <Map<String, Object?>>[],
    String? model,
    SessionSandboxMode? sandboxMode,
    bool yolo = false,
  }) async {
    await initialized;
    final Map<String, Object?> params = <String, Object?>{
      'cwd': cwd,
      'sandbox': _codexSandboxMode(sandboxMode),
    };
    if (model != null && model.isNotEmpty) params['model'] = model;
    if (yolo) params['approvalPolicy'] = 'never';
    final Map<String, Object?> config = _configForMcpServers(mcpServers);
    if (config.isNotEmpty) params['config'] = config;

    final Map<String, Object?> result = await _request(
      'thread/start',
      params,
    ).timeout(initTimeout);
    final _CodexSessionState state = _stateFromThreadResponse(
      result,
      cwd: cwd,
      requestedModel: model,
      yolo: yolo,
    );
    _sessions[state.threadId] = state;
    _channelFor(state.threadId);
    return (sessionId: state.threadId, configOptions: _configOptions(state));
  }

  @override
  Future<List<AcpConfigOption>> loadSession({
    required String sessionId,
    required String cwd,
    SessionSandboxMode? sandboxMode,
    List<Map<String, Object?>> mcpServers = const <Map<String, Object?>>[],
  }) async {
    await initialized;
    final Map<String, Object?> params = <String, Object?>{
      'threadId': sessionId,
      'cwd': cwd,
      'sandbox': _codexSandboxMode(sandboxMode),
    };
    final Map<String, Object?> config = _configForMcpServers(mcpServers);
    if (config.isNotEmpty) params['config'] = config;
    final Map<String, Object?> result = await _request(
      'thread/resume',
      params,
    ).timeout(initTimeout);
    final _CodexSessionState state = _stateFromThreadResponse(
      result,
      cwd: cwd,
      requestedModel: null,
      yolo: false,
    );
    if (state.threadId != sessionId) {
      throw FormatException(
        'thread/resume returned ${state.threadId}, expected $sessionId',
      );
    }
    _sessions[sessionId] = state;
    _channelFor(sessionId);
    return _configOptions(state);
  }

  @override
  Future<List<AcpConfigOption>> setConfigOption(
    String sessionId,
    String configId,
    String value,
  ) async {
    final _CodexSessionState state = _requireSession(sessionId);
    switch (configId) {
      case 'model':
        if (!_models.any((_CodexModel model) => model.id == value)) {
          throw ArgumentError.value(value, 'value', 'unknown Codex model');
        }
        state.model = value;
        final _CodexModel selected = _modelFor(value)!;
        if (!selected.efforts.contains(state.effort)) {
          state.effort = selected.defaultEffort;
        }
      case 'thinking':
        final _CodexModel? selected = _modelFor(state.model);
        if (selected == null || !selected.efforts.contains(value)) {
          throw ArgumentError.value(
            value,
            'value',
            'unknown reasoning effort for ${state.model}',
          );
        }
        state.effort = value;
      default:
        throw ArgumentError.value(configId, 'configId', 'unsupported option');
    }
    return _configOptions(state);
  }

  @override
  Stream<AcpSessionUpdate> sessionUpdates(String sessionId) {
    _requireSession(sessionId);
    return _channelFor(sessionId).controller.stream;
  }

  @override
  Future<PromptResult> prompt(
    String sessionId,
    List<Map<String, Object?>> promptBlocks,
  ) async {
    final _CodexSessionState state = _requireSession(sessionId);
    if (state.turnCompleter != null) {
      throw StateError('A Codex turn is already running for $sessionId');
    }
    final Completer<PromptResult> completer = Completer<PromptResult>();
    final Completer<String?> turnStartCompleter = Completer<String?>();
    state.turnCompleter = completer;
    state.turnStartCompleter = turnStartCompleter;
    try {
      final Map<String, Object?> params = <String, Object?>{
        'threadId': sessionId,
        'input': _inputsFromPromptBlocks(promptBlocks),
        'cwd': state.cwd,
        if (state.model != null) 'model': state.model,
        if (state.effort != null) 'effort': state.effort,
        if (state.yolo) 'approvalPolicy': 'never',
      };
      final Map<String, Object?> result = await _request('turn/start', params);
      final Map<String, Object?> turn = _asMap(result['turn']);
      final String? turnId = turn['id'] as String?;
      if (turnId == null || turnId.isEmpty) {
        throw const FormatException('Codex response is missing turn.id');
      }
      if (!identical(state.turnCompleter, completer) &&
          !completer.isCompleted) {
        throw StateError('Codex turn ended before turn/start completed');
      }
      if (identical(state.turnCompleter, completer)) {
        state.activeTurnId = turnId;
        _turnThreads[turnId] = sessionId;
      }
      if (!turnStartCompleter.isCompleted) {
        turnStartCompleter.complete(turnId);
      }
      if (identical(state.turnStartCompleter, turnStartCompleter)) {
        state.turnStartCompleter = null;
      }
      return await completer.future;
    } on Object {
      if (!turnStartCompleter.isCompleted) {
        turnStartCompleter.complete(null);
      }
      if (identical(state.turnStartCompleter, turnStartCompleter)) {
        state.turnStartCompleter = null;
      }
      if (identical(state.turnCompleter, completer)) {
        state.turnCompleter = null;
      }
      rethrow;
    }
  }

  @override
  Future<void> cancel(String sessionId) async {
    final _CodexSessionState state = _requireSession(sessionId);
    String? turnId = state.activeTurnId;
    if (turnId == null && state.turnCompleter != null) {
      final Completer<String?>? pending = state.turnStartCompleter;
      if (pending == null) return;
      final String? startedTurnId = await pending.future;
      if (state.turnCompleter == null) return;
      turnId = state.activeTurnId ?? startedTurnId;
    }
    if (turnId == null) return;
    await _request('turn/interrupt', <String, Object?>{
      'threadId': sessionId,
      'turnId': turnId,
    });
  }

  @override
  Future<void> setMode(String sessionId, String modeId) async {
    _requireSession(sessionId).modeId = modeId;
    // app-server 0.148 does not expose collaboration-mode mutation on its
    // stable request surface. Retain SpeedDial's local mode without claiming
    // that Codex changed its thread settings.
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _failAll(StateError('Codex client disposed'), StackTrace.current);
    final Process? process = _process;
    if (process != null) {
      try {
        await process.stdin.close();
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        process.kill();
        await process.exitCode;
      } on Object {
        process.kill();
      }
    }
    await _closeControllers();
  }

  Future<void> _ensureStarted() => _startFuture ??= _start();

  Future<void> _start() async {
    if (_disposed) throw StateError('Codex client is disposed');
    final Process process = await Process.start(
      _command.first,
      _command.skip(1).toList(growable: false),
      workingDirectory: _cwd,
      environment: _environment,
    );
    if (_disposed) {
      process.kill();
      await process.exitCode;
      throw StateError('Codex client is disposed');
    }
    _process = process;
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _handleLine,
          onError: (Object error, StackTrace stackTrace) {
            _failAll(StateError('Codex stdout failed: $error'), stackTrace);
          },
        );
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String line) {
          if (!_stderrController.isClosed) _stderrController.add(line);
        });
    unawaited(
      process.exitCode.then((int exitCode) async {
        _exited = true;
        if (!_disposed) {
          _failAll(
            StateError('Codex app-server exited with code $exitCode'),
            StackTrace.current,
          );
        }
        await _closeControllers();
      }),
    );
  }

  Future<List<_CodexModel>> _loadModels() async {
    final List<_CodexModel> models = <_CodexModel>[];
    String? cursor;
    do {
      final Map<String, Object?> result = await _request(
        'model/list',
        <String, Object?>{
          'limit': 100,
          'includeHidden': false,
          'cursor': ?cursor,
        },
      );
      final Object? rawData = result['data'];
      if (rawData is List) {
        for (final Object? entry in rawData) {
          if (entry is Map) {
            final _CodexModel? model = _CodexModel.parse(
              Map<String, Object?>.from(entry),
            );
            if (model != null) models.add(model);
          }
        }
      }
      cursor = result['nextCursor'] as String?;
    } while (cursor != null && cursor.isNotEmpty);
    return List<_CodexModel>.unmodifiable(models);
  }

  _CodexSessionState _stateFromThreadResponse(
    Map<String, Object?> result, {
    required String cwd,
    required String? requestedModel,
    required bool yolo,
  }) {
    final Map<String, Object?> thread = _asMap(result['thread']);
    final String? threadId = thread['id'] as String?;
    if (threadId == null || threadId.isEmpty) {
      throw const FormatException('Codex response is missing thread.id');
    }
    String? model = result['model'] as String? ?? requestedModel;
    model ??= _models
        .where((_CodexModel candidate) => candidate.isDefault)
        .firstOrNull
        ?.id;
    model ??= _models.firstOrNull?.id;
    final _CodexModel? selected = _modelFor(model);
    final String? responseEffort = result['reasoningEffort'] as String?;
    final String? effort = selected?.efforts.contains(responseEffort) == true
        ? responseEffort
        : selected?.defaultEffort;
    return _CodexSessionState(
      threadId: threadId,
      cwd: cwd,
      model: model,
      effort: effort,
      yolo: yolo,
    );
  }

  List<AcpConfigOption> _configOptions(_CodexSessionState state) {
    final List<AcpConfigOption> options = <AcpConfigOption>[];
    if (_models.isNotEmpty) {
      options.add(
        AcpConfigOption(
          id: 'model',
          name: 'Model',
          category: 'model',
          type: 'select',
          currentValue: state.model ?? '',
          options: <AcpConfigOptionValue>[
            for (final _CodexModel model in _models)
              AcpConfigOptionValue(
                value: model.id,
                name: model.displayName,
                description: model.description,
              ),
          ],
        ),
      );
    }
    final _CodexModel? selected = _modelFor(state.model);
    if (selected != null && selected.efforts.isNotEmpty) {
      options.add(
        AcpConfigOption(
          id: 'thinking',
          name: 'Reasoning effort',
          category: 'thought_level',
          type: 'select',
          currentValue: state.effort ?? '',
          options: <AcpConfigOptionValue>[
            for (final String effort in selected.efforts)
              AcpConfigOptionValue(value: effort, name: _titleCase(effort)),
          ],
        ),
      );
    }
    return options;
  }

  _CodexModel? _modelFor(String? id) {
    if (id == null) return null;
    for (final _CodexModel model in _models) {
      if (model.id == id) return model;
    }
    return null;
  }

  List<Map<String, Object?>> _inputsFromPromptBlocks(
    List<Map<String, Object?>> blocks,
  ) {
    final List<Map<String, Object?>> inputs = <Map<String, Object?>>[];
    for (final Map<String, Object?> block in blocks) {
      switch (block['type']) {
        case 'text':
          final String? text = block['text'] as String?;
          if (text != null && text.isNotEmpty) {
            inputs.add(<String, Object?>{'type': 'text', 'text': text});
          }
        case 'image':
          final String? data = block['data'] as String?;
          final String? mimeType = block['mimeType'] as String?;
          if (data == null ||
              mimeType == null ||
              !mimeType.startsWith('image/')) {
            throw const FormatException('Invalid Codex image prompt block');
          }
          inputs.add(<String, Object?>{
            'type': 'image',
            'url': 'data:$mimeType;base64,$data',
          });
        case 'resource':
          final Map<String, Object?> resource = _asMap(block['resource']);
          final String mimeType =
              resource['mimeType'] as String? ?? 'application/octet-stream';
          final String name = _resourceName(resource['uri'] as String?);
          final String? text = resource['text'] as String?;
          if (text != null) {
            inputs.add(<String, Object?>{
              'type': 'text',
              'text':
                  '<attached_file name="${_escapeLabel(name)}">\n'
                  '$text\n</attached_file>',
            });
            continue;
          }
          final String? blob = resource['blob'] as String?;
          if (blob == null) {
            throw FormatException('Attachment "$name" has no payload');
          }
          if (mimeType.startsWith('image/')) {
            inputs.add(<String, Object?>{
              'type': 'image',
              'url': 'data:$mimeType;base64,$blob',
            });
          } else if (mimeType.startsWith('audio/')) {
            inputs.add(<String, Object?>{
              'type': 'audio',
              'url': 'data:$mimeType;base64,$blob',
            });
          } else {
            throw UnsupportedError(
              'Codex app-server does not accept attachment "$name" '
              'with MIME type $mimeType',
            );
          }
        default:
          throw FormatException('Unknown Codex prompt block: ${block['type']}');
      }
    }
    if (inputs.isEmpty) {
      throw const FormatException('Codex turn input must not be empty');
    }
    return inputs;
  }

  Map<String, Object?> _configForMcpServers(
    List<Map<String, Object?>> servers,
  ) {
    if (servers.isEmpty) return const <String, Object?>{};
    final Map<String, Object?> configured = <String, Object?>{};
    for (final Map<String, Object?> server in servers) {
      final String? name = server['name'] as String?;
      final String? command = server['command'] as String?;
      if (name == null ||
          name.isEmpty ||
          command == null ||
          command.isEmpty ||
          (server['type'] != null && server['type'] != 'stdio')) {
        throw const FormatException('Invalid Codex MCP server descriptor');
      }
      final Object? rawArgs = server['args'];
      if (rawArgs != null &&
          (rawArgs is! List ||
              rawArgs.any((Object? value) => value is! String))) {
        throw FormatException('Invalid arguments for Codex MCP server "$name"');
      }
      final Map<String, String> environment = <String, String>{};
      final Object? rawEnvironment = server['env'];
      if (rawEnvironment != null && rawEnvironment is! List) {
        throw FormatException(
          'Invalid environment for Codex MCP server "$name"',
        );
      }
      if (rawEnvironment case final List<Object?> entries) {
        for (final Object? entry in entries) {
          if (entry is! Map ||
              entry['name'] is! String ||
              entry['value'] is! String) {
            throw FormatException(
              'Invalid environment for Codex MCP server "$name"',
            );
          }
          environment[entry['name'] as String] = entry['value'] as String;
        }
      }
      configured[name] = <String, Object?>{
        'command': command,
        if (rawArgs case final List<Object?> args) 'args': args.cast<String>(),
        if (environment.isNotEmpty) 'env': environment,
      };
    }
    return <String, Object?>{'mcp_servers': configured};
  }

  Future<Map<String, Object?>> _request(
    String method,
    Map<String, Object?> params,
  ) async {
    await _ensureStarted();
    if (_disposed || _exited) {
      throw StateError('Codex app-server is not running');
    }
    final int id = _nextRequestId++;
    final Completer<Map<String, Object?>> completer =
        Completer<Map<String, Object?>>();
    _pending[id] = completer;
    try {
      await _send(<String, Object?>{
        'id': id,
        'method': method,
        'params': params,
      });
      return await completer.future;
    } finally {
      _pending.remove(id);
    }
  }

  Future<void> _notify(String method, Map<String, Object?> params) =>
      _send(<String, Object?>{'method': method, 'params': params});

  Future<void> _send(Map<String, Object?> message) async {
    final Completer<void> previous = _writeQueue;
    final Completer<void> done = Completer<void>();
    _writeQueue = done;
    try {
      await previous.future;
      final Process? process = _process;
      if (process == null || _exited || _disposed) {
        throw StateError('Codex app-server is not running');
      }
      process.stdin.writeln(jsonEncode(message));
      await process.stdin.flush();
    } finally {
      done.complete();
    }
  }

  void _handleLine(String line) {
    if (line.trim().isEmpty) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException catch (error) {
      if (!_stderrController.isClosed) {
        _stderrController.add('Invalid Codex JSON: $error');
      }
      return;
    }
    if (decoded is! Map) return;
    final Map<String, Object?> message = Map<String, Object?>.from(decoded);
    final Object? id = message['id'];
    final String? method = message['method'] as String?;
    if (id != null && method == null) {
      _handleResponse(id, message);
    } else if (id != null && method != null) {
      unawaited(_handleServerRequest(id, method, _asMap(message['params'])));
    } else if (method != null) {
      _handleNotification(method, _asMap(message['params']));
    }
  }

  void _handleResponse(Object id, Map<String, Object?> message) {
    final Completer<Map<String, Object?>>? completer = _pending[id];
    if (completer == null || completer.isCompleted) return;
    final Object? rawError = message['error'];
    if (rawError is Map) {
      final Map<String, Object?> error = Map<String, Object?>.from(rawError);
      completer.completeError(
        CodexJsonRpcException(
          (error['code'] as num?)?.toInt() ?? -32603,
          error['message'] as String? ?? 'Unknown Codex error',
          error['data'],
        ),
      );
      return;
    }
    completer.complete(_asMap(message['result']));
  }

  Future<void> _handleServerRequest(
    Object id,
    String method,
    Map<String, Object?> params,
  ) async {
    try {
      if (method != 'item/commandExecution/requestApproval' &&
          method != 'item/fileChange/requestApproval') {
        await _send(<String, Object?>{
          'id': id,
          'error': <String, Object?>{
            'code': -32601,
            'message': 'Unsupported Codex request: $method',
          },
        });
        return;
      }
      final String? threadId = _threadIdFor(params);
      if (threadId == null) {
        throw const FormatException('Codex approval is missing threadId');
      }
      final String? itemId =
          params['itemId'] as String? ?? params['callId'] as String?;
      final List<_ApprovalChoice> choices = _approvalChoices(method, params);
      final List<PermissionOptionData> options = <PermissionOptionData>[
        for (final _ApprovalChoice choice in choices) choice.option,
      ];
      final AgentPermissionHandler? handler = _permissionHandler;
      final String selected = handler == null
          ? 'decline'
          : await handler(
              threadId,
              itemId,
              _approvalTitle(method, params),
              options,
            );
      final _ApprovalChoice choice = choices.firstWhere(
        (_ApprovalChoice candidate) => candidate.option.optionId == selected,
        orElse: () => choices.firstWhere(
          (_ApprovalChoice candidate) => candidate.option.optionId == 'decline',
        ),
      );
      await _send(<String, Object?>{
        'id': id,
        'result': <String, Object?>{'decision': choice.decision},
      });
    } on Object catch (error) {
      try {
        await _send(<String, Object?>{
          'id': id,
          'error': <String, Object?>{
            'code': -32603,
            'message': 'Failed to resolve Codex request: $error',
          },
        });
      } on Object {
        // Process teardown is authoritative.
      }
    }
  }

  List<_ApprovalChoice> _approvalChoices(
    String method,
    Map<String, Object?> params,
  ) {
    final List<_ApprovalChoice> choices = <_ApprovalChoice>[
      const _ApprovalChoice(
        option: PermissionOptionData(
          optionId: 'accept',
          name: 'Allow once',
          kind: 'allow_once',
        ),
        decision: 'accept',
      ),
      const _ApprovalChoice(
        option: PermissionOptionData(
          optionId: 'acceptForSession',
          name: 'Allow for session',
          kind: 'allow_always',
        ),
        decision: 'acceptForSession',
      ),
    ];
    final Object? amendment = params['proposedExecpolicyAmendment'];
    if (amendment is List && amendment.isNotEmpty) {
      choices.add(
        _ApprovalChoice(
          option: const PermissionOptionData(
            optionId: 'acceptWithExecpolicyAmendment',
            name: 'Allow and remember command',
            kind: 'allow_always',
          ),
          decision: <String, Object?>{
            'acceptWithExecpolicyAmendment': <String, Object?>{
              'execpolicy_amendment': amendment,
            },
          },
        ),
      );
    }
    final Object? network = params['proposedNetworkPolicyAmendments'];
    if (network is List) {
      for (var index = 0; index < network.length; index++) {
        final Object? value = network[index];
        if (value is! Map) continue;
        final Map<String, Object?> rule = Map<String, Object?>.from(value);
        final String host = rule['host'] as String? ?? 'network host';
        choices.add(
          _ApprovalChoice(
            option: PermissionOptionData(
              optionId: 'applyNetworkPolicyAmendment:$index',
              name: 'Allow $host for session',
              kind: 'allow_always',
            ),
            decision: <String, Object?>{
              'applyNetworkPolicyAmendment': <String, Object?>{
                'network_policy_amendment': rule,
              },
            },
          ),
        );
      }
    }
    choices.addAll(const <_ApprovalChoice>[
      _ApprovalChoice(
        option: PermissionOptionData(
          optionId: 'decline',
          name: 'Decline',
          kind: 'reject_once',
        ),
        decision: 'decline',
      ),
      _ApprovalChoice(
        option: PermissionOptionData(
          optionId: 'cancel',
          name: 'Cancel turn',
          kind: 'reject_always',
        ),
        decision: 'cancel',
      ),
    ]);
    return choices;
  }

  String _approvalTitle(String method, Map<String, Object?> params) {
    final String? reason = params['reason'] as String?;
    final String base;
    if (method == 'item/commandExecution/requestApproval') {
      final String command = _commandText(params['command']);
      base = command.isEmpty ? 'Run command' : 'Run ${_truncate(command, 100)}';
    } else {
      final String? itemId = params['itemId'] as String?;
      final _CodexToolState? state = itemId == null
          ? null
          : _tools[_toolKey(_threadIdFor(params) ?? '', itemId)];
      final List<String> paths = state == null
          ? const <String>[]
          : _locationsFor(state.item);
      base = paths.isEmpty ? 'Apply file changes' : 'Edit ${paths.join(', ')}';
    }
    return reason == null || reason.isEmpty ? base : '$base — $reason';
  }

  void _handleNotification(String method, Map<String, Object?> params) {
    try {
      switch (method) {
        case 'turn/started':
          final Map<String, Object?> turn = _asMap(params['turn']);
          final String? threadId = _threadIdFor(params);
          final String? turnId = turn['id'] as String?;
          if (threadId != null && turnId != null) {
            _turnThreads[turnId] = threadId;
            final _CodexSessionState? state = _sessions[threadId];
            if (state != null) state.activeTurnId = turnId;
          }
        case 'turn/completed':
          _handleTurnCompleted(params);
        case 'item/started':
          _handleItem(params, completed: false);
        case 'item/completed':
          _handleItem(params, completed: true);
        case 'item/agentMessage/delta':
          _handleMessageDelta(params);
        case 'item/reasoning/summaryTextDelta':
        case 'item/reasoning/textDelta':
          _handleReasoningDelta(params);
        case 'item/plan/delta':
          _handleReasoningDelta(params);
        case 'item/commandExecution/outputDelta':
          _handleCommandOutput(params);
        case 'item/fileChange/patchUpdated':
          _handlePatchUpdate(params);
        case 'turn/plan/updated':
          _handlePlan(params);
        case 'thread/tokenUsage/updated':
          _handleUsage(params);
        case 'mcpServer/startupStatus/updated':
          _handleMcpStatus(params);
        case 'model/rerouted':
          _handleModelRerouted(params);
        case 'model/safetyBuffering/updated':
          _handleSafetyBuffering(params);
        case 'model/verification':
          _handleModelVerification(params);
        case 'error':
          _handleTurnError(params);
        case 'warning':
        case 'configWarning':
          _handleWarning(params);
        default:
          // Forward compatibility: unknown app-server notifications must not
          // terminate the read loop or an otherwise healthy turn.
          return;
      }
    } on Object catch (error) {
      if (!_stderrController.isClosed) {
        _stderrController.add('Invalid Codex $method notification: $error');
      }
    }
  }

  void _handleMessageDelta(Map<String, Object?> params) {
    final String? threadId = _threadIdFor(params);
    final String? itemId = params['itemId'] as String?;
    final String? delta = params['delta'] as String?;
    if (threadId == null || itemId == null || delta == null || delta.isEmpty) {
      return;
    }
    _messageDeltas
        .putIfAbsent(_toolKey(threadId, itemId), StringBuffer.new)
        .write(delta);
    _emit(threadId, AcpAgentMessageChunk(text: delta, messageId: itemId));
  }

  void _handleReasoningDelta(Map<String, Object?> params) {
    final String? threadId = _threadIdFor(params);
    final String? itemId = params['itemId'] as String?;
    final String? delta = params['delta'] as String?;
    if (threadId == null || itemId == null || delta == null || delta.isEmpty) {
      return;
    }
    _reasoningDeltas
        .putIfAbsent(_toolKey(threadId, itemId), StringBuffer.new)
        .write(delta);
    _emit(threadId, AcpAgentThoughtChunk(text: delta, messageId: itemId));
  }

  void _handleCommandOutput(Map<String, Object?> params) {
    final String? threadId = _threadIdFor(params);
    final String? itemId = params['itemId'] as String?;
    final String? delta = params['delta'] as String?;
    if (threadId == null || itemId == null || delta == null) return;
    final _CodexToolState? state = _tools[_toolKey(threadId, itemId)];
    if (state == null) return;
    state.output.write(delta);
    _emit(
      threadId,
      AcpToolCallUpdate(
        toolCallId: itemId,
        fields: _toolFields(state, completed: false),
      ),
    );
  }

  void _handlePatchUpdate(Map<String, Object?> params) {
    final String? threadId = _threadIdFor(params);
    final String? itemId = params['itemId'] as String?;
    if (threadId == null || itemId == null) return;
    final _CodexToolState? state = _tools[_toolKey(threadId, itemId)];
    if (state == null) return;
    final Object? rawChanges = params['changes'] ?? params['patch'];
    if (rawChanges != null) state.item['changes'] = rawChanges;
    _emit(
      threadId,
      AcpToolCallUpdate(
        toolCallId: itemId,
        fields: _toolFields(state, completed: false),
      ),
    );
  }

  void _handleItem(Map<String, Object?> params, {required bool completed}) {
    final String? threadId = _threadIdFor(params);
    final Map<String, Object?> item = _asMap(params['item']);
    final String? itemId = item['id'] as String?;
    final String? type = item['type'] as String?;
    if (threadId == null || itemId == null || type == null) return;
    final String key = _toolKey(threadId, itemId);
    switch (type) {
      case 'agentMessage':
        if (completed) {
          _emitMessageRemainder(
            threadId,
            itemId,
            item['text'] as String? ?? '',
          );
          _completedMessages.add(key);
        }
      case 'reasoning':
        if (completed) {
          _emitReasoningRemainder(threadId, itemId, _reasoningText(item));
        }
      case 'plan':
        if (completed) {
          final String text = item['text'] as String? ?? '';
          _emitReasoningRemainder(threadId, itemId, text);
        }
      case 'contextCompaction':
      case 'compacted':
        _emit(
          threadId,
          AcpAgentActivityUpdate(
            id: 'codex-compaction-$itemId',
            kind: 'compaction',
            title: 'Compact conversation context',
            status: completed ? 'completed' : 'running',
          ),
        );
      case 'enteredReviewMode':
        _emit(
          threadId,
          AcpAgentActivityUpdate(
            id: 'codex-review-$itemId',
            kind: 'review',
            title: item['review'] as String? ?? 'Review changes',
            status: completed ? 'completed' : 'running',
          ),
        );
      case 'exitedReviewMode':
        if (completed) {
          final String review = item['review'] as String? ?? '';
          if (review.isNotEmpty) {
            _emit(
              threadId,
              AcpAgentMessageChunk(text: review, messageId: itemId),
            );
          }
        }
      case 'sleep':
        _emit(
          threadId,
          AcpAgentActivityUpdate(
            id: 'codex-sleep-$itemId',
            kind: 'wait',
            title: 'Waiting',
            status: completed ? 'completed' : 'running',
            details: <String>[
              if (item['durationMs'] case final num duration)
                '${duration.toInt()} ms',
            ],
          ),
        );
      case 'subAgentActivity':
        final String activityKind = item['kind'] as String? ?? 'started';
        _emit(
          threadId,
          AcpAgentActivityUpdate(
            id: 'codex-subagent-$itemId',
            kind: 'subagent',
            title: switch (activityKind) {
              'interacted' => 'Sub-agent interaction',
              'interrupted' => 'Sub-agent interrupted',
              _ => 'Sub-agent started',
            },
            status: activityKind == 'interrupted'
                ? 'failed'
                : completed
                ? 'completed'
                : 'running',
            details: <String>[
              if (item['agentPath'] case final String path when path.isNotEmpty)
                path,
              if (item['agentThreadId'] case final String agentThreadId
                  when agentThreadId.isNotEmpty)
                agentThreadId,
            ],
          ),
        );
      case 'commandExecution':
      case 'fileChange':
      case 'mcpToolCall':
      case 'dynamicToolCall':
      case 'collabAgentToolCall':
      case 'webSearch':
      case 'imageGeneration':
      case 'imageView':
        if (!completed) {
          final _CodexToolState state = _CodexToolState(item);
          _tools[key] = state;
          _emit(
            threadId,
            AcpToolCall(toolCall: _toolData(state, completed: false)),
          );
        } else {
          final _CodexToolState state = _tools.putIfAbsent(
            key,
            () => _CodexToolState(item),
          );
          state.item = item;
          final Object? aggregated = item['aggregatedOutput'];
          if (aggregated is String) state.finalOutput = aggregated;
          _emit(
            threadId,
            AcpToolCallUpdate(
              toolCallId: itemId,
              fields: _toolFields(state, completed: true),
            ),
          );
          _tools.remove(key);
        }
      default:
        return;
    }
  }

  void _emitMessageRemainder(String threadId, String itemId, String fullText) {
    if (fullText.isEmpty) return;
    final String key = _toolKey(threadId, itemId);
    final String streamed = _messageDeltas.remove(key)?.toString() ?? '';
    final String remainder = fullText.startsWith(streamed)
        ? fullText.substring(streamed.length)
        : streamed.isEmpty
        ? fullText
        : '';
    if (remainder.isNotEmpty) {
      _emit(threadId, AcpAgentMessageChunk(text: remainder, messageId: itemId));
    }
  }

  void _emitReasoningRemainder(
    String threadId,
    String itemId,
    String fullText,
  ) {
    if (fullText.isEmpty) return;
    final String key = _toolKey(threadId, itemId);
    final String streamed = _reasoningDeltas.remove(key)?.toString() ?? '';
    final String remainder = fullText.startsWith(streamed)
        ? fullText.substring(streamed.length)
        : streamed.isEmpty
        ? fullText
        : '';
    if (remainder.isNotEmpty) {
      _emit(threadId, AcpAgentThoughtChunk(text: remainder, messageId: itemId));
    }
  }

  void _handleTurnCompleted(Map<String, Object?> params) {
    final Map<String, Object?> turn = _asMap(params['turn']);
    final String? turnId = turn['id'] as String?;
    final String? threadId =
        _threadIdFor(params) ?? (turnId == null ? null : _turnThreads[turnId]);
    if (threadId == null) return;
    final Object? rawItems = turn['items'];
    if (rawItems is List) {
      for (final Object? rawItem in rawItems) {
        if (rawItem is! Map) continue;
        final Map<String, Object?> item = Map<String, Object?>.from(rawItem);
        final String? itemId = item['id'] as String?;
        if (item['type'] == 'agentMessage' &&
            itemId != null &&
            !_completedMessages.contains(_toolKey(threadId, itemId))) {
          _handleItem(<String, Object?>{
            'threadId': threadId,
            'item': item,
          }, completed: true);
        }
      }
    }
    final _CodexSessionState? state = _sessions[threadId];
    final Completer<PromptResult>? completer = state?.turnCompleter;
    final Completer<String?>? turnStartCompleter = state?.turnStartCompleter;
    if (state != null) {
      state.turnCompleter = null;
      state.turnStartCompleter = null;
      state.activeTurnId = null;
    }
    if (turnStartCompleter != null && !turnStartCompleter.isCompleted) {
      turnStartCompleter.complete(turnId);
    }
    if (turnId != null) _turnThreads.remove(turnId);
    if (completer == null || completer.isCompleted) return;
    final String status = turn['status'] as String? ?? 'failed';
    if (status == 'completed') {
      completer.complete(const PromptResult(stopReason: 'end_turn'));
    } else if (status == 'interrupted') {
      completer.complete(const PromptResult(stopReason: 'cancelled'));
    } else {
      final String message =
          _errorMessage(turn['error']) ??
          _turnErrors.remove(threadId) ??
          'Codex turn failed';
      completer.completeError(CodexTurnException(message));
    }
  }

  void _handlePlan(Map<String, Object?> params) {
    final String? threadId = _threadIdFor(params);
    if (threadId == null) return;
    final Object? rawPlan = params['plan'];
    if (rawPlan is! List) return;
    final List<AcpPlanEntry> entries = <AcpPlanEntry>[];
    for (final Object? rawEntry in rawPlan) {
      if (rawEntry is! Map) continue;
      final Map<String, Object?> entry = Map<String, Object?>.from(rawEntry);
      final String? step = entry['step'] as String?;
      if (step == null || step.isEmpty) continue;
      entries.add(
        AcpPlanEntry(
          content: step,
          priority: 'medium',
          status: switch (entry['status']) {
            'inProgress' => 'in_progress',
            'completed' => 'completed',
            _ => 'pending',
          },
        ),
      );
    }
    _emit(threadId, AcpPlan(entries: entries));
  }

  void _handleUsage(Map<String, Object?> params) {
    final String? threadId = _threadIdFor(params);
    if (threadId == null) return;
    final Map<String, Object?> usage = _asMap(params['tokenUsage']);
    final Map<String, Object?> total = _asMap(usage['total']);
    _emit(
      threadId,
      AcpUsageUpdate(
        size: (usage['modelContextWindow'] as num?)?.toInt() ?? 0,
        used: (total['totalTokens'] as num?)?.toInt() ?? 0,
        inputTokens: (total['inputTokens'] as num?)?.toInt(),
        outputTokens: (total['outputTokens'] as num?)?.toInt(),
        cacheReadTokens: (total['cachedInputTokens'] as num?)?.toInt(),
        cacheCreationTokens: (total['cacheWriteInputTokens'] as num?)?.toInt(),
      ),
    );
  }

  void _handleMcpStatus(Map<String, Object?> params) {
    final String? threadId = _threadIdFor(params);
    final String? name = params['name'] as String?;
    if (threadId == null || name == null) return;
    final String status = params['status'] as String? ?? 'starting';
    _emit(
      threadId,
      AcpAgentActivityUpdate(
        id: 'codex-mcp-$name',
        kind: 'mcp',
        title: 'MCP · $name',
        status: switch (status) {
          'ready' => 'completed',
          'failed' || 'cancelled' => 'failed',
          _ => 'running',
        },
        details: <String>[
          if (params['error'] case final String error when error.isNotEmpty)
            error,
          if (params['failureReason'] case final String reason
              when reason.isNotEmpty)
            reason,
        ],
      ),
    );
  }

  void _handleModelRerouted(Map<String, Object?> params) {
    final String? threadId = _threadIdFor(params);
    if (threadId == null) return;
    final String from = params['fromModel'] as String? ?? 'requested model';
    final String to = params['toModel'] as String? ?? 'fallback model';
    _emit(
      threadId,
      AcpAgentActivityUpdate(
        id: 'codex-model-${params['turnId'] ?? ++_activitySerial}',
        kind: 'model',
        title: 'Model rerouted · $from → $to',
        status: 'completed',
        details: <String>[
          if (params['reason'] case final String reason when reason.isNotEmpty)
            reason,
        ],
      ),
    );
  }

  void _handleSafetyBuffering(Map<String, Object?> params) {
    final String? threadId = _threadIdFor(params);
    if (threadId == null) return;
    _emit(
      threadId,
      AcpAgentActivityUpdate(
        id: 'codex-safety-${params['turnId'] ?? ++_activitySerial}',
        kind: 'safety',
        title: 'Safety review · ${params['model'] ?? 'model'}',
        status: params['showBufferingUi'] == false ? 'completed' : 'running',
        details: _stringList(params['reasons']),
      ),
    );
  }

  void _handleModelVerification(Map<String, Object?> params) {
    final String? threadId = _threadIdFor(params);
    if (threadId == null) return;
    _emit(
      threadId,
      AcpAgentActivityUpdate(
        id: 'codex-verification-${params['turnId'] ?? ++_activitySerial}',
        kind: 'verification',
        title: 'Account verification required',
        status: 'failed',
        details: _stringList(params['verifications']),
      ),
    );
  }

  void _handleTurnError(Map<String, Object?> params) {
    final String? threadId = _threadIdFor(params);
    if (threadId == null) return;
    final String message = _errorMessage(params['error']) ?? 'Codex turn error';
    _turnErrors[threadId] = message;
    _emit(
      threadId,
      AcpAgentActivityUpdate(
        id: 'codex-error-${params['turnId'] ?? ++_activitySerial}',
        kind: 'error',
        title: message,
        status: 'failed',
      ),
    );
  }

  void _handleWarning(Map<String, Object?> params) {
    final String? message =
        params['message'] as String? ?? params['summary'] as String?;
    if (message == null || message.isEmpty) return;
    final String? threadId = _threadIdFor(params);
    if (threadId == null) {
      if (!_stderrController.isClosed) _stderrController.add(message);
      return;
    }
    _emit(
      threadId,
      AcpAgentActivityUpdate(
        id: 'codex-warning-${++_activitySerial}',
        kind: 'warning',
        title: message,
        status: 'completed',
        details: <String>[
          if (params['details'] case final String details
              when details.isNotEmpty)
            details,
        ],
      ),
    );
  }

  AcpToolCallData _toolData(_CodexToolState state, {required bool completed}) {
    final Map<String, Object?> item = state.item;
    return AcpToolCallData(
      id: item['id'] as String? ?? '',
      title: _toolTitle(item),
      kind: _toolKind(item),
      status: _toolStatus(item, completed: completed),
      content: _toolContent(state),
      locations: <AcpToolCallLocation>[
        for (final String path in _locationsFor(item))
          AcpToolCallLocation(path: path),
      ],
      rawInput: _safeItem(item),
      rawOutput: completed ? _safeItem(item) : const <String, Object?>{},
    );
  }

  Map<String, Object?> _toolFields(
    _CodexToolState state, {
    required bool completed,
  }) {
    final AcpToolCallData data = _toolData(state, completed: completed);
    return <String, Object?>{
      'title': data.title,
      'kind': data.kind,
      'status': data.status,
      'content': <Map<String, Object?>>[
        for (final AcpToolCallContent content in data.content)
          switch (content) {
            AcpContentBlockContent(:final content) => <String, Object?>{
              'type': 'content',
              'content': content,
            },
            AcpDiffContent(:final path, :final oldText, :final newText) =>
              <String, Object?>{
                'type': 'diff',
                'path': path,
                'oldText': oldText,
                'newText': newText,
              },
            AcpPatchContent(:final path, :final diff) => <String, Object?>{
              'type': 'patch',
              'path': path,
              'diff': diff,
            },
            AcpTerminalContent(:final terminalId, :final output) =>
              <String, Object?>{
                'type': 'terminal',
                'terminalId': terminalId,
                'output': output,
              },
          },
      ],
      'locations': <Map<String, Object?>>[
        for (final AcpToolCallLocation location in data.locations)
          <String, Object?>{'path': location.path},
      ],
      if (completed) 'rawInput': data.rawInput,
      if (completed) 'rawOutput': data.rawOutput,
    };
  }

  List<AcpToolCallContent> _toolContent(_CodexToolState state) {
    final Map<String, Object?> item = state.item;
    switch (item['type']) {
      case 'commandExecution':
        final String output = state.finalOutput ?? state.output.toString();
        return output.isEmpty
            ? const <AcpToolCallContent>[]
            : <AcpToolCallContent>[
                AcpTerminalContent(
                  terminalId: item['id'] as String? ?? '',
                  output: output,
                ),
              ];
      case 'fileChange':
        final List<AcpToolCallContent> patches = <AcpToolCallContent>[];
        final Object? rawChanges = item['changes'];
        if (rawChanges is List) {
          for (final Object? rawChange in rawChanges) {
            if (rawChange is! Map) continue;
            final Map<String, Object?> change = Map<String, Object?>.from(
              rawChange,
            );
            final String? diff = change['diff'] as String?;
            if (diff == null || diff.isEmpty) continue;
            patches.add(
              AcpPatchContent(
                path: change['path'] as String? ?? '',
                diff: diff,
              ),
            );
          }
        }
        return patches;
      case 'mcpToolCall':
        final Object? result = item['result'];
        final Object? error = item['error'];
        final String text = error != null
            ? _jsonText(error)
            : result == null
            ? ''
            : _jsonText(result);
        return text.isEmpty
            ? const <AcpToolCallContent>[]
            : <AcpToolCallContent>[
                AcpContentBlockContent(
                  content: <String, Object?>{'type': 'text', 'text': text},
                ),
              ];
      case 'dynamicToolCall':
        final List<String> details = <String>[];
        if (item['contentItems'] case final List<Object?> contentItems) {
          for (final Object? rawContent in contentItems) {
            if (rawContent is! Map) continue;
            switch (rawContent['type']) {
              case 'inputText':
                if (rawContent['text'] case final String text
                    when text.isNotEmpty) {
                  details.add(text);
                }
              case 'inputImage':
                details.add('Image output');
              case 'inputAudio':
                details.add('Audio output');
            }
          }
        }
        return details.isEmpty
            ? const <AcpToolCallContent>[]
            : <AcpToolCallContent>[
                AcpContentBlockContent(
                  content: <String, Object?>{
                    'type': 'text',
                    'text': details.join('\n'),
                  },
                ),
              ];
      case 'webSearch':
        final Object? results = item['results'];
        return results == null
            ? const <AcpToolCallContent>[]
            : <AcpToolCallContent>[
                AcpContentBlockContent(
                  content: <String, Object?>{
                    'type': 'text',
                    'text': _jsonText(results),
                  },
                ),
              ];
      case 'collabAgentToolCall':
        final List<String> details = <String>[
          if (item['prompt'] case final String prompt when prompt.isNotEmpty)
            prompt,
          if (item['receiverThreadIds'] case final List<Object?> threadIds
              when threadIds.isNotEmpty)
            'Receivers: ${threadIds.join(', ')}',
          if (item['agentsStates'] != null) _jsonText(item['agentsStates']),
        ];
        return details.isEmpty
            ? const <AcpToolCallContent>[]
            : <AcpToolCallContent>[
                AcpContentBlockContent(
                  content: <String, Object?>{
                    'type': 'text',
                    'text': details.join('\n'),
                  },
                ),
              ];
      case 'imageGeneration':
        final List<String> details = <String>[
          if (item['revisedPrompt'] case final String prompt
              when prompt.isNotEmpty)
            prompt,
          if (item['savedPath'] case final String path when path.isNotEmpty)
            'Saved to $path',
        ];
        return details.isEmpty
            ? const <AcpToolCallContent>[]
            : <AcpToolCallContent>[
                AcpContentBlockContent(
                  content: <String, Object?>{
                    'type': 'text',
                    'text': details.join('\n'),
                  },
                ),
              ];
      case 'imageView':
        final String path = item['path'] as String? ?? '';
        return path.isEmpty
            ? const <AcpToolCallContent>[]
            : <AcpToolCallContent>[
                AcpContentBlockContent(
                  content: <String, Object?>{'type': 'text', 'text': path},
                ),
              ];
      default:
        return const <AcpToolCallContent>[];
    }
  }

  String _toolTitle(Map<String, Object?> item) => switch (item['type']) {
    'commandExecution' => switch (_commandText(item['command'])) {
      final String command when command.isNotEmpty => _truncate(command, 120),
      _ => 'Run command',
    },
    'fileChange' => switch (_locationsFor(item)) {
      [final String path] => 'Edit $path',
      final List<String> paths when paths.isNotEmpty =>
        'Edit ${paths.length} files',
      _ => 'Edit files',
    },
    'mcpToolCall' =>
      '${item['server'] ?? 'MCP'} · ${item['tool'] ?? 'tool call'}',
    'dynamicToolCall' =>
      '${item['namespace'] ?? 'Tool'} · ${item['tool'] ?? 'tool call'}',
    'collabAgentToolCall' => 'Agent · ${item['tool'] ?? 'collaboration'}',
    'webSearch' => 'Search web · ${item['query'] ?? ''}',
    'imageGeneration' => 'Generate image',
    'imageView' => 'View image · ${p.basename(item['path'] as String? ?? '')}',
    _ => item['type'] as String? ?? 'Codex activity',
  };

  String _toolKind(Map<String, Object?> item) {
    switch (item['type']) {
      case 'commandExecution':
        return 'execute';
      case 'fileChange':
        final Object? rawChanges = item['changes'];
        if (rawChanges is List && rawChanges.isNotEmpty) {
          final Set<String> kinds = <String>{};
          for (final Object? raw in rawChanges) {
            if (raw is! Map) continue;
            final Object? rawKind = raw['kind'];
            if (rawKind is String) {
              kinds.add(rawKind.toLowerCase());
            } else if (rawKind is Map) {
              final String? kind = rawKind['type'] as String?;
              if (kind == null) continue;
              final String? movePath = rawKind['move_path'] as String?;
              kinds.add(
                kind == 'update' && movePath != null && movePath.isNotEmpty
                    ? 'move'
                    : kind.toLowerCase(),
              );
            }
          }
          if (kinds.length == 1 && kinds.single == 'delete') return 'delete';
          if (kinds.length == 1 &&
              (kinds.single == 'move' || kinds.single == 'rename')) {
            return 'move';
          }
        }
        return 'edit';
      case 'webSearch':
        return 'search';
      case 'imageView':
        return 'read';
      case 'mcpToolCall':
      case 'dynamicToolCall':
        final String tool = (item['tool'] as String? ?? '').toLowerCase();
        if (tool.contains('read') || tool.contains('get')) return 'read';
        if (tool.contains('search') || tool.contains('find')) return 'search';
        if (tool.contains('write') ||
            tool.contains('edit') ||
            tool.contains('create')) {
          return 'edit';
        }
        return 'other';
      default:
        return 'other';
    }
  }

  String _toolStatus(Map<String, Object?> item, {required bool completed}) {
    if (!completed) return 'in_progress';
    return switch (item['status']) {
      'completed' => 'completed',
      'inProgress' => 'in_progress',
      _ => 'cancelled',
    };
  }

  List<String> _locationsFor(Map<String, Object?> item) {
    final LinkedHashSet<String> paths = LinkedHashSet<String>();
    final Object? rawChanges = item['changes'];
    if (rawChanges is List) {
      for (final Object? rawChange in rawChanges) {
        if (rawChange is! Map) continue;
        if (rawChange['path'] case final String path when path.isNotEmpty) {
          paths.add(path);
        }
        final Object? rawKind = rawChange['kind'];
        if (rawKind is Map) {
          final Object? rawMovePath = rawKind['move_path'];
          if (rawMovePath is String && rawMovePath.isNotEmpty) {
            paths.add(rawMovePath);
          }
        }
      }
    }
    final Object? rawActions = item['commandActions'];
    if (rawActions is List) {
      for (final Object? rawAction in rawActions) {
        if (rawAction is Map && rawAction['path'] is String) {
          paths.add(rawAction['path'] as String);
        }
      }
    }
    if (item['path'] case final String path when path.isNotEmpty) {
      paths.add(path);
    }
    if (item['savedPath'] case final String path when path.isNotEmpty) {
      paths.add(path);
    }
    return paths.toList(growable: false);
  }

  Map<String, Object?> _safeItem(Map<String, Object?> item) {
    final Map<String, Object?> safe = Map<String, Object?>.from(item);
    if (safe['type'] == 'imageGeneration' && safe['result'] is String) {
      final String result = safe['result'] as String;
      safe['result'] = '<image payload: ${result.length} characters>';
    }
    if (safe['type'] == 'dynamicToolCall') {
      final Object? rawContentItems = safe['contentItems'];
      if (rawContentItems is List) {
        final List<Object?> sanitized = <Object?>[];
        for (final Object? rawContent in rawContentItems) {
          if (rawContent is! Map) {
            sanitized.add(rawContent);
            continue;
          }
          final Map<String, Object?> content = Map<String, Object?>.from(
            rawContent,
          );
          if (content['type'] == 'inputImage') {
            final Object? rawImageUrl = content['imageUrl'];
            if (rawImageUrl is String) {
              content['imageUrl'] =
                  '<image payload: ${rawImageUrl.length} characters>';
            }
          } else if (content['type'] == 'inputAudio') {
            final Object? rawAudioUrl = content['audioUrl'];
            if (rawAudioUrl is String) {
              content['audioUrl'] =
                  '<audio payload: ${rawAudioUrl.length} characters>';
            }
          }
          sanitized.add(content);
        }
        safe['contentItems'] = sanitized;
      }
    }
    return safe;
  }

  String? _threadIdFor(Map<String, Object?> params) {
    final String? direct = params['threadId'] as String?;
    if (direct != null) return direct;
    final String? conversationId = params['conversationId'] as String?;
    if (conversationId != null) return conversationId;
    final String? turnId =
        params['turnId'] as String? ?? _asMap(params['turn'])['id'] as String?;
    return turnId == null ? null : _turnThreads[turnId];
  }

  _CodexSessionState _requireSession(String sessionId) {
    final _CodexSessionState? state = _sessions[sessionId];
    if (state == null) throw StateError('Unknown Codex thread: $sessionId');
    return state;
  }

  _SessionChannel _channelFor(String sessionId) =>
      _sessionChannels.putIfAbsent(sessionId, _SessionChannel.new);

  void _emit(String threadId, AcpSessionUpdate update) {
    _channelFor(threadId).add(update);
  }

  void _failAll(Object error, StackTrace stackTrace) {
    for (final Completer<Map<String, Object?>> completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    }
    _pending.clear();
    for (final _CodexSessionState state in _sessions.values) {
      final Completer<PromptResult>? completer = state.turnCompleter;
      final bool turnStartPending = state.turnStartCompleter != null;
      if (!turnStartPending && completer != null && !completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
      final Completer<String?>? turnStartCompleter = state.turnStartCompleter;
      if (turnStartCompleter != null && !turnStartCompleter.isCompleted) {
        turnStartCompleter.complete(null);
      }
      state.turnCompleter = null;
      state.turnStartCompleter = null;
      state.activeTurnId = null;
    }
  }

  Future<void> _closeControllers() async {
    if (_controllersClosed) return;
    _controllersClosed = true;
    await Future.wait(<Future<void>>[
      for (final _SessionChannel channel in _sessionChannels.values)
        channel.close(),
      if (!_stderrController.isClosed) _stderrController.close(),
    ]);
  }

  static Map<String, Object?> _asMap(Object? value) => value is Map
      ? Map<String, Object?>.from(value)
      : const <String, Object?>{};

  static String _commandText(Object? value) => switch (value) {
    final String command => command,
    final List<Object?> command => command.whereType<String>().join(' '),
    _ => '',
  };

  static String _reasoningText(Map<String, Object?> item) {
    final List<String> parts = <String>[];
    void append(Object? value) {
      if (value is String && value.isNotEmpty) {
        parts.add(value);
      } else if (value is List) {
        for (final Object? entry in value) {
          if (entry is String && entry.isNotEmpty) {
            parts.add(entry);
          } else if (entry is Map && entry['text'] is String) {
            parts.add(entry['text'] as String);
          }
        }
      }
    }

    append(item['summary']);
    append(item['content']);
    return parts.join('\n');
  }

  static String? _errorMessage(Object? value) {
    if (value is String && value.isNotEmpty) return value;
    if (value is Map) {
      final Object? message = value['message'];
      if (message is String && message.isNotEmpty) return message;
      return _jsonText(value);
    }
    return null;
  }

  static List<String> _stringList(Object? value) {
    if (value is! List) return const <String>[];
    return <String>[
      for (final Object? entry in value)
        if (entry is String) entry else if (entry != null) _jsonText(entry),
    ];
  }

  static String _jsonText(Object? value) {
    try {
      return const JsonEncoder.withIndent('  ').convert(value);
    } on Object {
      return value.toString();
    }
  }

  static String _resourceName(String? rawUri) {
    if (rawUri == null || rawUri.isEmpty) return 'attachment';
    try {
      final Uri uri = Uri.parse(rawUri);
      return uri.pathSegments.isEmpty
          ? 'attachment'
          : Uri.decodeComponent(uri.pathSegments.last);
    } on FormatException {
      return 'attachment';
    }
  }

  static String _escapeLabel(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('"', '&quot;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  static String _truncate(String value, int maxLength) =>
      value.length <= maxLength
      ? value
      : '${value.substring(0, maxLength - 1)}…';

  static String _titleCase(String value) =>
      value.isEmpty ? value : '${value[0].toUpperCase()}${value.substring(1)}';

  static String _toolKey(String threadId, String itemId) =>
      '$threadId\u0000$itemId';
}

class _CodexModel {
  const _CodexModel({
    required this.id,
    required this.displayName,
    required this.description,
    required this.defaultEffort,
    required this.efforts,
    required this.isDefault,
  });

  static _CodexModel? parse(Map<String, Object?> json) {
    final String id = json['id'] as String? ?? json['model'] as String? ?? '';
    if (id.isEmpty || json['hidden'] == true) return null;
    final List<String> efforts = <String>[];
    final Object? rawEfforts = json['supportedReasoningEfforts'];
    if (rawEfforts is List) {
      for (final Object? rawEffort in rawEfforts) {
        if (rawEffort is! Map) continue;
        final String? effort = rawEffort['reasoningEffort'] as String?;
        if (effort != null && effort.isNotEmpty) efforts.add(effort);
      }
    }
    final String? defaultEffort = json['defaultReasoningEffort'] as String?;
    if (defaultEffort != null &&
        defaultEffort.isNotEmpty &&
        !efforts.contains(defaultEffort)) {
      efforts.add(defaultEffort);
    }
    return _CodexModel(
      id: id,
      displayName: json['displayName'] as String? ?? id,
      description: json['description'] as String? ?? '',
      defaultEffort: defaultEffort,
      efforts: List<String>.unmodifiable(efforts),
      isDefault: json['isDefault'] == true,
    );
  }

  final String id;
  final String displayName;
  final String description;
  final String? defaultEffort;
  final List<String> efforts;
  final bool isDefault;
}

class _CodexSessionState {
  _CodexSessionState({
    required this.threadId,
    required this.cwd,
    required this.model,
    required this.effort,
    required this.yolo,
  });

  final String threadId;
  final String cwd;
  String? model;
  String? effort;
  final bool yolo;
  String modeId = 'build';
  String? activeTurnId;
  Completer<PromptResult>? turnCompleter;
  Completer<String?>? turnStartCompleter;
}

class _CodexToolState {
  _CodexToolState(this.item);

  Map<String, Object?> item;
  final StringBuffer output = StringBuffer();
  String? finalOutput;
}

class _ApprovalChoice {
  const _ApprovalChoice({required this.option, required this.decision});

  final PermissionOptionData option;
  final Object decision;
}

class _SessionChannel {
  _SessionChannel() {
    controller = StreamController<AcpSessionUpdate>.broadcast(
      sync: true,
      onListen: _flush,
    );
  }

  late final StreamController<AcpSessionUpdate> controller;
  final ListQueue<AcpSessionUpdate> _pending = ListQueue<AcpSessionUpdate>();

  void add(AcpSessionUpdate update) {
    if (controller.isClosed) return;
    if (controller.hasListener) {
      controller.add(update);
    } else {
      if (_pending.length == 512) _pending.removeFirst();
      _pending.addLast(update);
    }
  }

  void _flush() {
    while (_pending.isNotEmpty && !controller.isClosed) {
      controller.add(_pending.removeFirst());
    }
  }

  Future<void> close() =>
      controller.isClosed ? Future<void>.value() : controller.close();
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final Iterator<T> iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
