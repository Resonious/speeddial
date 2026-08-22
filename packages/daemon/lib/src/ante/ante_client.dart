import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../acp/acp_types.dart';
import '../agents/agent_client.dart';

/// A failure reported by Ante for one turn.
class AnteTurnException implements Exception {
  const AnteTurnException(this.message);

  final String message;

  @override
  String toString() => 'AnteTurnException: $message';
}

/// Ante's JSONL `ante serve` transport, translated into engine updates.
class AnteClient implements AgentClient {
  AnteClient.spawn(
    List<String> command, {
    required String cwd,
    List<String>? catalogCommand,
    Map<String, String>? environment,
    AgentPermissionHandler? requestPermission,
    this.initTimeout = const Duration(seconds: 30),
  }) : _command = List<String>.of(command),
       _catalogCommand = catalogCommand == null
           ? null
           : List<String>.of(catalogCommand),
       _cwd = cwd, // ignore: prefer_initializing_formals — public API name
       // ignore: prefer_initializing_formals — public API name
       _environment = environment,
       _permissionHandler = requestPermission {
    if (_command.isEmpty) {
      throw ArgumentError.value(command, 'command', 'must not be empty');
    }
    _catalogFuture = _loadCatalog();
  }

  final List<String> _command;
  final List<String>? _catalogCommand;
  final String _cwd;
  final Map<String, String>? _environment;
  final AgentPermissionHandler? _permissionHandler;
  final Duration initTimeout;
  final Random _random = Random.secure();

  Future<Process>? _processFuture;
  Future<void>? _startFuture;
  late final Future<List<_AnteCatalogProvider>> _catalogFuture;
  Future<InitializeResult>? _initializedFuture;
  Future<void>? _closeStreamsFuture;
  Future<void>? _mcpHomeRemovalFuture;
  Future<void>? _imageDirectoryRemovalFuture;
  Directory? _mcpHome;
  // Ante settings defaults (read while preparing the MCP home). `ante serve`
  // ignores these when StartSession omits a model, falling back to the
  // subscription, so newSession reseeds them explicitly.
  String? _settingsModel;
  String? _settingsProvider;
  Directory? _imageDirectory;
  int _imageFileIndex = 0;
  final StreamController<String> _stderrController =
      StreamController<String>.broadcast();
  final Map<String, _SessionChannel> _sessionChannels =
      <String, _SessionChannel>{};
  final Map<String, Completer<_AnteSessionState>> _sessionWaiters =
      <String, Completer<_AnteSessionState>>{};
  final Map<String, Completer<_AnteSessionState>> _updateWaiters =
      <String, Completer<_AnteSessionState>>{};
  final Map<String, Completer<PromptResult>> _turnWaiters =
      <String, Completer<PromptResult>>{};
  final Map<String, SplayTreeMap<int, String>> _toolProgress =
      <String, SplayTreeMap<int, String>>{};
  final Map<String, AcpAgentActivityUpdate> _activities =
      <String, AcpAgentActivityUpdate>{};

  Completer<void> _writeQueue = Completer<void>()..complete();
  _AnteSessionState? _session;
  String? _currentTurnOp;
  String? _compactionActivityId;
  bool _suppressReplay = false;
  bool _sawMessageDelta = false;
  bool _sawThinkingDelta = false;
  bool _exited = false;
  bool _disposed = false;
  bool _shutdownSent = false;

  @override
  Future<InitializeResult> get initialized =>
      _initializedFuture ??= _initialize();

  @override
  Stream<String> get stderrLines => _stderrController.stream;

  Future<InitializeResult> _initialize() async {
    return const InitializeResult(
      protocolVersion: 1,
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
    throw UnsupportedError('Ante authentication is managed by the Ante CLI.');
  }

  @override
  Future<({String sessionId, List<AcpConfigOption> configOptions})> newSession({
    required String cwd,
    List<Map<String, Object?>> mcpServers = const <Map<String, Object?>>[],
    String? model,
    String? provider,
    SessionSandboxMode? sandboxMode,
    bool yolo = false,
  }) async {
    await initialized;
    await _ensureStarted(mcpServers);
    final List<_AnteCatalogProvider> catalog = await _catalogFuture;
    final Map<String, Object?> config = <String, Object?>{
      'cwd': cwd,
      // Keep approvals visible to SpeedDial. Its engine performs yolo
      // auto-resolution while retaining request/resolution history.
      'permission_mode': 'strict',
    };
    // Seed the Ante settings default when the caller did not pick a model:
    // serve mode otherwise resolves the subscription instead of the
    // configured provider. An explicit provider (from a provider-qualified
    // model id) wins over every default.
    final String? settingsModel = _settingsModel;
    final String? settingsProvider = _settingsProvider;
    final bool hasCallerModel = model != null && model.isNotEmpty;
    final bool hasCallerProvider = provider != null && provider.isNotEmpty;
    final bool seedFromSettings =
        !hasCallerModel && settingsModel != null && settingsModel.isNotEmpty;
    final String? effectiveModel = seedFromSettings ? settingsModel : model;
    if (hasCallerProvider) config['provider'] = provider;
    if (effectiveModel != null && effectiveModel.isNotEmpty) {
      config['model'] = effectiveModel;
      if (!hasCallerProvider) {
        final String? resolved = seedFromSettings
            ? ((settingsProvider != null && settingsProvider.isNotEmpty)
                  ? settingsProvider
                  : _uniqueProviderForModel(catalog, effectiveModel))
            : _uniqueProviderForModel(catalog, effectiveModel);
        if (resolved != null) config['provider'] = resolved;
      }
    }
    final String opId = _nextOpId();
    final Completer<_AnteSessionState> completer =
        Completer<_AnteSessionState>();
    _sessionWaiters[opId] = completer;
    try {
      await _sendOp(<String, Object?>{'StartSession': config}, opId);
      final _AnteSessionState state = await completer.future.timeout(
        initTimeout,
      );
      return (
        sessionId: state.sessionId,
        configOptions: _configOptions(state, catalog),
      );
    } finally {
      _sessionWaiters.remove(opId);
    }
  }

  @override
  Future<List<AcpConfigOption>> loadSession({
    required String sessionId,
    required String cwd,
    SessionSandboxMode? sandboxMode,
    List<Map<String, Object?>> mcpServers = const <Map<String, Object?>>[],
  }) async {
    await initialized;
    await _ensureStarted(mcpServers);
    final String opId = _nextOpId();
    final Completer<_AnteSessionState> completer =
        Completer<_AnteSessionState>();
    _sessionWaiters[opId] = completer;
    _suppressReplay = true;
    try {
      await _sendOp(<String, Object?>{
        'ResumeSession': <String, Object?>{'session_id': sessionId},
      }, opId);
      final _AnteSessionState state = await completer.future.timeout(
        initTimeout,
      );
      if (state.sessionId != sessionId) {
        throw FormatException(
          'ResumeSession returned ${state.sessionId}, expected $sessionId',
        );
      }
      return _configOptions(state, await _catalogFuture);
    } on Object {
      _suppressReplay = false;
      rethrow;
    } finally {
      _sessionWaiters.remove(opId);
    }
  }

  @override
  Future<List<AcpConfigOption>> setConfigOption(
    String sessionId,
    String configId,
    String value,
  ) async {
    final _AnteSessionState state = _requireSession(sessionId);
    final Map<String, Object?> update;
    switch (configId) {
      case 'model':
        update = <String, Object?>{
          'model': <String, Object?>{'id': value},
        };
      case 'thinking':
        if (!_effortValues.contains(value)) {
          throw ArgumentError.value(value, 'value', 'unknown Ante effort');
        }
        update = <String, Object?>{
          'model': <String, Object?>{'id': state.modelId, 'effort': value},
        };
      default:
        throw ArgumentError.value(configId, 'configId', 'unsupported option');
    }

    final String opId = _nextOpId();
    final Completer<_AnteSessionState> completer =
        Completer<_AnteSessionState>();
    _updateWaiters[opId] = completer;
    try {
      await _sendOp(<String, Object?>{'UpdateSession': update}, opId);
      final _AnteSessionState updated = await completer.future.timeout(
        initTimeout,
      );
      return _configOptions(updated, await _catalogFuture);
    } finally {
      _updateWaiters.remove(opId);
    }
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
    _requireSession(sessionId);
    if (_currentTurnOp != null) {
      throw StateError('An Ante turn is already running.');
    }
    final String text = await _textFromPromptBlocks(promptBlocks);
    final String opId = _nextOpId();
    final Completer<PromptResult> completer = Completer<PromptResult>();
    _turnWaiters[opId] = completer;
    _currentTurnOp = opId;
    _sawMessageDelta = false;
    _sawThinkingDelta = false;
    _toolProgress.clear();
    try {
      await _sendOp(<String, Object?>{'UserInput': text}, opId);
    } on Object {
      _turnWaiters.remove(opId);
      _currentTurnOp = null;
      rethrow;
    }
    return completer.future;
  }

  @override
  Future<void> cancel(String sessionId) async {
    _requireSession(sessionId);
    if (_currentTurnOp == null) return;
    await _sendOp('Interrupt', _nextOpId());
  }

  @override
  Future<void> setMode(String sessionId, String modeId) async {
    _requireSession(sessionId);
    // Ante has no build/plan operation. SpeedDial retains the local mode label
    // without claiming a provider-side change.
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    final Future<Process>? processFuture = _processFuture;
    try {
      if (processFuture != null && !_exited && !_shutdownSent) {
        _shutdownSent = true;
        await _sendOp('Shutdown', _nextOpId());
      }
    } on Object {
      // Process teardown below is authoritative.
    }
    _disposed = true;

    Process? process;
    if (processFuture != null) {
      try {
        process = await processFuture;
        await process.stdin.close();
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        process?.kill();
        if (process != null) await process.exitCode;
      } on Object {
        process?.kill();
      }
    }
    try {
      await Future.wait(<Future<void>>[
        _removeMcpHome(),
        _removeImageDirectory(),
      ]);
    } finally {
      await _closeStreams();
    }
  }

  Future<void> _ensureStarted(List<Map<String, Object?>> mcpServers) =>
      _startFuture ??= _startConfigured(mcpServers);

  Future<void> _startConfigured(List<Map<String, Object?>> mcpServers) async {
    try {
      final Map<String, String> environment = await _prepareMcpHome(mcpServers);
      final Future<Process> processFuture = _start(environment);
      _processFuture = processFuture;
      await processFuture.timeout(initTimeout);
    } on Object {
      await _removeMcpHome();
      rethrow;
    }
  }

  Future<Map<String, String>> _prepareMcpHome(
    List<Map<String, Object?>> mcpServers,
  ) async {
    final Map<String, String> environment = <String, String>{
      ...Platform.environment,
      ...?_environment,
    };
    if (mcpServers.isEmpty) return environment;

    final String? configuredAnteHome = environment['ANTE_HOME'];
    final String? configuredHome =
        environment['HOME'] ?? environment['USERPROFILE'];
    if ((configuredAnteHome == null || configuredAnteHome.isEmpty) &&
        (configuredHome == null || configuredHome.isEmpty)) {
      throw StateError('Cannot locate the Ante home for MCP configuration.');
    }
    final String anteHome =
        configuredAnteHome != null && configuredAnteHome.isNotEmpty
        ? configuredAnteHome
        : p.join(configuredHome!, '.ante');
    final Directory sourceHome = Directory(anteHome);
    await sourceHome.create(recursive: true);

    final String? selectedProfile = environment['ANTE_PROFILE'];
    final File baseFile = File(
      p.join(
        sourceHome.path,
        selectedProfile == null || selectedProfile.isEmpty
            ? 'settings.json'
            : '$selectedProfile.settings.json',
      ),
    );
    final Map<String, Object?> settings = <String, Object?>{};
    if (await baseFile.exists()) {
      final Object? decoded = jsonDecode(await baseFile.readAsString());
      if (decoded is! Map) {
        throw const FormatException(
          'Ante settings profile must contain a JSON object.',
        );
      }
      settings.addAll(Map<String, Object?>.from(decoded));
    }
    _settingsModel = settings['model'] as String?;
    _settingsProvider = settings['provider'] as String?;

    final Map<String, Object?> mergedServers =
        switch (settings['mcp_servers']) {
          final Map<Object?, Object?> value => Map<String, Object?>.from(value),
          _ => <String, Object?>{},
        };
    for (final Map<String, Object?> server in mcpServers) {
      final String? name = server['name'] as String?;
      final String? command = server['command'] as String?;
      final Object? type = server['type'];
      if (name == null ||
          name.isEmpty ||
          command == null ||
          command.isEmpty ||
          (type != null && type != 'stdio')) {
        throw const FormatException('Invalid Ante MCP server descriptor.');
      }
      final Object? rawArgs = server['args'];
      if (rawArgs != null &&
          (rawArgs is! List ||
              rawArgs.any((Object? item) => item is! String))) {
        throw FormatException('Invalid arguments for Ante MCP server "$name".');
      }
      final Map<String, String> serverEnvironment = <String, String>{};
      final Object? rawEnvironment = server['env'];
      if (rawEnvironment != null && rawEnvironment is! List) {
        throw FormatException(
          'Invalid environment for Ante MCP server "$name".',
        );
      }
      if (rawEnvironment case final List<Object?> entries) {
        for (final Object? entry in entries) {
          if (entry is! Map ||
              entry['name'] is! String ||
              entry['value'] is! String) {
            throw FormatException(
              'Invalid environment for Ante MCP server "$name".',
            );
          }
          serverEnvironment[entry['name'] as String] = entry['value'] as String;
        }
      }
      mergedServers[name] = <String, Object?>{
        'command': command,
        if (rawArgs case final List<Object?> args) 'args': args.cast<String>(),
        if (serverEnvironment.isNotEmpty) 'env': serverEnvironment,
      };
    }
    settings['mcp_servers'] = mergedServers;

    // Use settings.json in an isolated home rather than a named profile:
    // Ante preview releases omit profile-defined MCP servers in serve mode.
    // Links preserve all non-settings state in the user's real Ante home.
    final Directory transientHome = await Directory.systemTemp.createTemp(
      'speeddial_ante_',
    );
    _mcpHome = transientHome;
    try {
      await _linkAnteHome(sourceHome, transientHome);
      final File settingsFile = File(
        p.join(transientHome.path, 'settings.json'),
      );
      await settingsFile.writeAsString(jsonEncode(settings), flush: true);
      if (!Platform.isWindows) {
        for (final (String mode, String path) in <(String, String)>[
          ('700', transientHome.path),
          ('600', settingsFile.path),
        ]) {
          final ProcessResult chmod = await Process.run('chmod', <String>[
            mode,
            path,
          ]);
          if (chmod.exitCode != 0) {
            throw FileSystemException(
              'Could not restrict transient Ante home permissions',
              path,
            );
          }
        }
      }
    } on Object {
      await _removeMcpHome();
      rethrow;
    }
    environment
      ..remove('ANTE_PROFILE')
      ..['ANTE_HOME'] = transientHome.path;
    return environment;
  }

  Future<void> _linkAnteHome(
    Directory sourceHome,
    Directory transientHome,
  ) async {
    for (final String name in const <String>[
      'auth',
      'sessions',
      'projects',
      'cache',
      'run',
      'tmp',
      'logs',
    ]) {
      await Directory(p.join(sourceHome.path, name)).create(recursive: true);
    }
    await for (final FileSystemEntity entry in sourceHome.list(
      followLinks: false,
    )) {
      final String name = p.basename(entry.path);
      if (name == 'settings.json' || name.endsWith('.settings.json')) continue;
      await Link(p.join(transientHome.path, name)).create(entry.absolute.path);
    }
  }

  Future<void> _removeMcpHome() =>
      _mcpHomeRemovalFuture ??= _removeMcpHomeOnce();

  Future<void> _removeMcpHomeOnce() async {
    final Directory? mcpHome = _mcpHome;
    if (mcpHome == null) return;
    if (await mcpHome.exists()) await mcpHome.delete(recursive: true);
    _mcpHome = null;
  }

  Future<Directory> _ensureImageDirectory() async {
    final Directory? existing = _imageDirectory;
    if (existing != null) return existing;
    final Directory directory = await Directory.systemTemp.createTemp(
      'speeddial_ante_images_',
    );
    try {
      if (!Platform.isWindows) {
        final ProcessResult chmod = await Process.run('chmod', <String>[
          '700',
          directory.path,
        ]);
        if (chmod.exitCode != 0) {
          throw FileSystemException(
            'Could not restrict Ante image directory permissions',
            directory.path,
          );
        }
      }
      if (_disposed || _exited) {
        throw StateError('AnteClient is not running.');
      }
      _imageDirectory = directory;
      return directory;
    } on Object {
      if (await directory.exists()) await directory.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> _removeImageDirectory() =>
      _imageDirectoryRemovalFuture ??= _removeImageDirectoryOnce();

  Future<void> _removeImageDirectoryOnce() async {
    final Directory? directory = _imageDirectory;
    if (directory == null) return;
    if (await directory.exists()) await directory.delete(recursive: true);
    _imageDirectory = null;
  }

  Future<Process> _start(Map<String, String> environment) async {
    final Process process = await Process.start(
      _command.first,
      _command.sublist(1),
      workingDirectory: _cwd,
      environment: environment,
      includeParentEnvironment: false,
      mode: ProcessStartMode.normal,
    );
    unawaited(
      utf8.decoder
          .bind(process.stdout)
          .transform(const LineSplitter())
          .forEach(_handleLine)
          .catchError((Object error, StackTrace stack) {
            _fail(AnteTurnException('Invalid Ante output: $error'));
          }),
    );
    unawaited(
      utf8.decoder.bind(process.stderr).transform(const LineSplitter()).forEach(
        (String line) {
          if (!_stderrController.isClosed) _stderrController.add(line);
        },
      ),
    );
    unawaited(process.exitCode.then(_onExit));
    return process;
  }

  Future<List<_AnteCatalogProvider>> _loadCatalog() async {
    final List<String>? command = _catalogCommand;
    if (command == null || command.isEmpty) {
      return const <_AnteCatalogProvider>[];
    }
    try {
      final ProcessResult result = await Process.run(
        command.first,
        command.sublist(1),
        workingDirectory: _cwd,
        environment: _environment,
        includeParentEnvironment: true,
      ).timeout(const Duration(seconds: 5));
      if (result.exitCode != 0 || result.stdout is! String) {
        return const <_AnteCatalogProvider>[];
      }
      final Object? decoded = jsonDecode(result.stdout as String);
      if (decoded is! Map || decoded['providers'] is! List) {
        return const <_AnteCatalogProvider>[];
      }
      return (decoded['providers'] as List<Object?>)
          .whereType<Map>()
          .map(
            (Map<Object?, Object?> value) =>
                _AnteCatalogProvider.fromJson(Map<String, Object?>.from(value)),
          )
          .where((_AnteCatalogProvider provider) => provider.id.isNotEmpty)
          .toList(growable: false);
    } on Object {
      return const <_AnteCatalogProvider>[];
    }
  }

  void _handleLine(String line) {
    if (line.trim().isEmpty) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException catch (error) {
      _publishFailureActivity('Malformed Ante event: $error');
      return;
    }
    if (decoded is! Map) {
      _publishFailureActivity('Ante emitted a non-object event.');
      return;
    }
    _handleEvent(Map<String, Object?>.from(decoded));
  }

  void _handleEvent(Map<String, Object?> message) {
    final String eventId = message['id'] as String? ?? _nextEventId();
    final String? parent = message['parent'] as String?;
    final Object? rawEvent = message['event'];
    if (rawEvent is String) {
      switch (rawEvent) {
        case 'CompactStart':
          _onCompactStart(eventId);
        case 'Goodbye':
          break;
      }
      return;
    }
    if (rawEvent is! Map || rawEvent.isEmpty) return;
    final Map<String, Object?> event = Map<String, Object?>.from(rawEvent);
    final MapEntry<String, Object?> variant = event.entries.first;
    final String type = variant.key;
    final Object? value = variant.value;

    switch (type) {
      case 'SessionStart':
        final _AnteSessionState state = _AnteSessionState.fromJson(_map(value));
        _adoptSession(state, emitActivity: true);
        final Completer<_AnteSessionState>? waiter = _sessionWaiters.remove(
          parent,
        );
        if (waiter != null && !waiter.isCompleted) waiter.complete(state);
      case 'SessionUpdated':
        final _AnteSessionState state = _AnteSessionState.fromJson(_map(value));
        _adoptSession(state, emitActivity: true);
        final Completer<_AnteSessionState>? waiter = _updateWaiters.remove(
          parent,
        );
        if (waiter != null && !waiter.isCompleted) waiter.complete(state);
      case 'SessionEnd':
        break;
      case 'TurnStart':
        if (parent != null && parent == _currentTurnOp) {
          _suppressReplay = false;
        }
      case 'TurnPause':
        if (!_suppressReplay) unawaited(_handleApproval(_map(value)));
      case 'TurnResume':
        break;
      case 'TurnEnd':
        _handleTurnEnd(parent, _map(value));
      case 'MessageDelta':
        if (_suppressReplay) return;
        final String text = value is String ? value : '';
        if (text.isNotEmpty) {
          _sawMessageDelta = true;
          _publish(AcpAgentMessageChunk(text: text));
        }
      case 'AgentMessage':
        if (_suppressReplay || _sawMessageDelta) return;
        final String text = value is String ? value : '';
        if (text.isNotEmpty) _publish(AcpAgentMessageChunk(text: text));
      case 'ThinkingDelta':
        if (_suppressReplay) return;
        final String text = value is String ? value : '';
        if (text.isNotEmpty) {
          _sawThinkingDelta = true;
          _publish(AcpAgentThoughtChunk(text: text));
        }
      case 'Thinking':
        if (_suppressReplay || _sawThinkingDelta) return;
        final String text = value is String ? value : '';
        if (text.isNotEmpty) _publish(AcpAgentThoughtChunk(text: text));
      case 'UserInput':
        // SpeedDial persists the user message before starting the provider.
        break;
      case 'ToolStart':
        if (!_suppressReplay) _handleToolStart(_map(value));
      case 'ToolUpdate':
        if (!_suppressReplay) _handleToolUpdate(_map(value));
      case 'ToolEnd':
        if (!_suppressReplay) _handleToolEnd(_map(value));
      case 'UsageUpdate':
        if (!_suppressReplay) _handleUsage(_map(value));
      case 'ExtensionRefreshed':
        _handleExtensions(_map(value));
      case 'Info':
        if (value is String && value.isNotEmpty) {
          _publishActivity(
            AcpAgentActivityUpdate(
              id: eventId,
              kind: 'info',
              title: value,
              status: 'completed',
            ),
          );
        }
      case 'InfoBlockStart':
        _handleInfoBlockStart(_map(value));
      case 'InfoBlockAppend':
        _handleInfoBlockAppend(_map(value));
      case 'CompactEnd':
        _onCompactEnd(_map(value));
      case 'ContextReport':
        _handleContextReport(eventId, _map(value));
      case 'ShellOutput':
        _handleShellOutput(eventId, _map(value));
      case 'Error':
        final String messageText = value is String ? value : '$value';
        _handleOperationError(parent, messageText);
      case 'Ambient':
        break;
    }
  }

  void _adoptSession(_AnteSessionState state, {required bool emitActivity}) {
    _session = state;
    _channelFor(state.sessionId);
    if (!emitActivity) return;
    final List<String> details = <String>[
      if (state.modelDescription != null) state.modelDescription!,
      if (state.effort != null) 'Effort: ${state.effort}',
      if (state.contextLimit != null)
        'Context window: ${state.contextLimit} tokens',
      'Permission mode: ${state.permissionMode}',
    ];
    _publishActivity(
      AcpAgentActivityUpdate(
        id: 'ante-session-${state.sessionId}',
        kind: 'session',
        title: '${state.modelId} via ${state.providerName}',
        status: 'completed',
        details: details,
      ),
      duringReplay: true,
    );
  }

  void _handleTurnEnd(String? parent, Map<String, Object?> value) {
    final String? opId = parent ?? _currentTurnOp;
    if (opId == null) return;
    final Completer<PromptResult>? completer = _turnWaiters.remove(opId);
    if (completer == null || completer.isCompleted) return;
    if (_currentTurnOp == opId) _currentTurnOp = null;

    final Object? status = value['status'];
    if (status == 'Completed') {
      completer.complete(const PromptResult(stopReason: 'end_turn'));
      return;
    }
    if (status is Map) {
      final Map<String, Object?> statusMap = Map<String, Object?>.from(status);
      if (statusMap.containsKey('Interrupted')) {
        completer.complete(const PromptResult(stopReason: 'cancelled'));
        return;
      }
      final Object? rawError = statusMap['Error'];
      if (rawError is Map) {
        final Map<String, Object?> error = Map<String, Object?>.from(rawError);
        final String headline =
            error['headline'] as String? ?? 'Ante turn failed';
        final List<String> details = _strings(error['details']);
        completer.completeError(
          AnteTurnException(
            details.isEmpty ? headline : '$headline: ${details.join('; ')}',
          ),
        );
        return;
      }
    }
    completer.complete(PromptResult(stopReason: '$status'));
  }

  Future<void> _handleApproval(Map<String, Object?> value) async {
    final String turnId = value['turn_id'] as String? ?? _currentTurnOp ?? '';
    final Map<String, Object?> reason = _map(value['reason']);
    final Map<String, Object?> approval = _map(reason['Approval']);
    if (approval.isEmpty) return;
    final List<Map<String, Object?>> tools =
        (approval['tools'] as List<Object?>?)
            ?.whereType<Map>()
            .map(
              (Map<Object?, Object?> tool) => Map<String, Object?>.from(tool),
            )
            .toList(growable: false) ??
        const <Map<String, Object?>>[];
    if (tools.isEmpty) return;

    const List<PermissionOptionData> options = <PermissionOptionData>[
      PermissionOptionData(
        optionId: 'Accept',
        name: 'Allow once',
        kind: 'allow_once',
      ),
      PermissionOptionData(
        optionId: 'AcceptForSession',
        name: 'Allow for session',
        kind: 'allow_always',
      ),
      PermissionOptionData(
        optionId: 'AcceptAlways',
        name: 'Always allow',
        kind: 'allow_always',
      ),
      PermissionOptionData(optionId: 'Skip', name: 'Skip', kind: 'reject_once'),
      PermissionOptionData(
        optionId: 'Abort',
        name: 'Abort turn',
        kind: 'reject_always',
      ),
    ];
    final String title =
        approval['message'] as String? ??
        (tools.length == 1
            ? 'Allow ${tools.first['name'] ?? 'tool'}?'
            : 'Allow ${tools.length} tool calls?');
    final AgentPermissionHandler? handler = _permissionHandler;
    String decision = 'Abort';
    if (handler != null) {
      try {
        decision = await handler(
          _session!.sessionId,
          tools.length == 1 ? tools.first['id'] as String? : null,
          title,
          options,
        );
      } on Object {
        if (_currentTurnOp == null || _disposed) return;
        rethrow;
      }
    }
    if (!options.any(
      (PermissionOptionData option) => option.optionId == decision,
    )) {
      decision = 'Skip';
    }
    await _sendOp(<String, Object?>{
      'ApprovalResponse': <String, Object?>{
        'turn_id': turnId,
        'responses': <Object?>[
          for (final Map<String, Object?> tool in tools)
            <Object?>[tool['id'], decision],
        ],
      },
    }, _nextOpId());
  }

  void _handleToolStart(Map<String, Object?> value) {
    final String id = value['id'] as String? ?? '';
    if (id.isEmpty) return;
    final String name = value['name'] as String? ?? 'Tool';
    final Map<String, Object?> args = _map(value['args']);
    final Map<String, Object?> input = args.isNotEmpty
        ? args
        : _map(value['input']);
    _toolProgress[id] = SplayTreeMap<int, String>();
    _publish(
      AcpToolCall(
        toolCall: AcpToolCallData(
          id: id,
          title: name,
          kind: _toolKind(name),
          status: 'in_progress',
          content: const <AcpToolCallContent>[],
          locations: _toolLocations(input),
          rawInput: input,
          rawOutput: const <String, Object?>{},
        ),
      ),
    );
  }

  void _handleToolUpdate(Map<String, Object?> value) {
    final String id = value['tool_use_id'] as String? ?? '';
    if (id.isEmpty) return;
    final int seq = (value['seq'] as num?)?.toInt() ?? 0;
    final String message = value['message'] as String? ?? '';
    final SplayTreeMap<int, String> progress = _toolProgress.putIfAbsent(
      id,
      SplayTreeMap<int, String>.new,
    );
    if (message.isNotEmpty) progress[seq] = message;
    _publish(
      AcpToolCallUpdate(
        toolCallId: id,
        fields: <String, Object?>{
          'status': 'in_progress',
          if (progress.isNotEmpty)
            'content': <Object?>[
              <String, Object?>{
                'type': 'content',
                'content': <String, Object?>{
                  'type': 'text',
                  'text': progress.values.join('\n'),
                },
              },
            ],
        },
      ),
    );
  }

  void _handleToolEnd(Map<String, Object?> value) {
    final String id = value['tool_use_id'] as String? ?? '';
    if (id.isEmpty) return;
    final String status = value['status'] as String? ?? 'Failed';
    final bool isError = value['is_error'] as bool? ?? false;
    final Object? rawResult = value['result_json'];
    final Map<String, Object?> output = rawResult is Map
        ? Map<String, Object?>.from(rawResult)
        : rawResult == null
        ? <String, Object?>{}
        : <String, Object?>{'value': rawResult};
    final List<Object?> content = _toolResultContent(rawResult);
    _publish(
      AcpToolCallUpdate(
        toolCallId: id,
        fields: <String, Object?>{
          'status': status == 'Completed' && !isError
              ? 'completed'
              : 'cancelled',
          'content': content,
          'rawOutput': output,
        },
      ),
    );
  }

  void _handleUsage(Map<String, Object?> value) {
    final Map<String, Object?> usage = _map(value['usage']);
    final Map<String, Object?> context = _map(value['context']);
    _publish(
      AcpUsageUpdate(
        size: _int(context['limit_tokens']) ?? 0,
        used: _int(context['used_tokens']) ?? 0,
        inputTokens: _int(usage['input_tokens']),
        outputTokens: _int(usage['output_tokens']),
        cacheReadTokens: _int(usage['cache_read_tokens']),
        cacheCreationTokens: _int(usage['cache_creation_tokens']),
      ),
    );
  }

  void _handleExtensions(Map<String, Object?> value) {
    final String sessionId =
        value['session_id'] as String? ?? _session?.sessionId ?? '';
    if (sessionId.isEmpty) return;
    final List<Map<String, Object?>> skills = _maps(value['skills']);
    final List<Map<String, Object?>> subagents = _maps(value['subagents']);
    final List<Map<String, Object?>> servers = _maps(value['mcp_servers']);
    var toolCount = 0;
    final List<String> details = <String>[
      if (skills.isNotEmpty)
        'Skills: ${skills.map((Map<String, Object?> item) => item['name']).whereType<String>().join(', ')}',
      if (subagents.isNotEmpty)
        'Subagents: ${subagents.map((Map<String, Object?> item) => item['name']).whereType<String>().join(', ')}',
    ];
    for (final Map<String, Object?> server in servers) {
      final List<Map<String, Object?>> tools = _maps(server['tools']);
      toolCount += tools.length;
      details.add('MCP ${server['name'] ?? 'server'}: ${tools.length} tools');
      for (final Map<String, Object?> tool in tools) {
        details.add(
          '  ${tool['qualified_name'] ?? tool['name'] ?? 'unnamed tool'}',
        );
      }
    }
    _publishActivity(
      AcpAgentActivityUpdate(
        id: 'ante-extensions-$sessionId',
        kind: 'extensions',
        title:
            '${skills.length} skills · ${subagents.length} subagents · ${servers.length} MCP servers · $toolCount tools',
        status: 'completed',
        details: details,
      ),
      duringReplay: true,
    );
  }

  void _handleInfoBlockStart(Map<String, Object?> value) {
    final String id = value['id'] as String? ?? '';
    if (id.isEmpty) return;
    final AcpAgentActivityUpdate activity = AcpAgentActivityUpdate(
      id: id,
      kind: 'info',
      title: value['header'] as String? ?? 'Ante activity',
      status: value['loading'] == true ? 'running' : 'completed',
    );
    _activities[id] = activity;
    _publishActivity(activity);
  }

  void _handleInfoBlockAppend(Map<String, Object?> value) {
    final String id = value['id'] as String? ?? '';
    final AcpAgentActivityUpdate? prior = _activities[id];
    if (prior == null) return;
    final String detail = value['detail'] as String? ?? '';
    final AcpAgentActivityUpdate activity = AcpAgentActivityUpdate(
      id: prior.id,
      kind: prior.kind,
      title: prior.title,
      status: 'completed',
      details: <String>[...prior.details, if (detail.isNotEmpty) detail],
    );
    _activities[id] = activity;
    _publishActivity(activity);
  }

  void _onCompactStart(String eventId) {
    final String id = 'ante-compact-${_session?.sessionId ?? eventId}';
    _compactionActivityId = id;
    final AcpAgentActivityUpdate activity = AcpAgentActivityUpdate(
      id: id,
      kind: 'compaction',
      title: 'Compacting conversation',
      status: 'running',
    );
    _activities[id] = activity;
    _publishActivity(activity);
  }

  void _onCompactEnd(Map<String, Object?> value) {
    final String id =
        _compactionActivityId ??
        'ante-compact-${_session?.sessionId ?? 'unknown'}';
    final String? summary = value['summary'] as String?;
    final AcpAgentActivityUpdate activity = AcpAgentActivityUpdate(
      id: id,
      kind: 'compaction',
      title: 'Conversation compacted',
      status: summary == null ? 'failed' : 'completed',
      details: <String>[if (summary != null && summary.isNotEmpty) summary],
    );
    _activities[id] = activity;
    _publishActivity(activity);
    _compactionActivityId = null;
  }

  void _handleContextReport(String eventId, Map<String, Object?> value) {
    final List<String> details = <String>[];
    for (final MapEntry<String, Object?> entry in value.entries) {
      final int? count = _int(entry.value);
      if (count != null) {
        details.add('${_humanize(entry.key)}: $count');
      }
    }
    _publishActivity(
      AcpAgentActivityUpdate(
        id: eventId,
        kind: 'context',
        title: 'Context report',
        status: 'completed',
        details: details,
      ),
    );
  }

  void _handleShellOutput(String eventId, Map<String, Object?> value) {
    final List<String> details = <String>[
      if ((value['stdout'] as String? ?? '').isNotEmpty)
        value['stdout']! as String,
      if ((value['stderr'] as String? ?? '').isNotEmpty)
        value['stderr']! as String,
      'Exit code: ${_int(value['exit_code']) ?? -1}',
    ];
    _publishActivity(
      AcpAgentActivityUpdate(
        id: eventId,
        kind: 'shell',
        title: '\$ ${value['command'] ?? ''}',
        status: _int(value['exit_code']) == 0 ? 'completed' : 'failed',
        details: details,
      ),
    );
  }

  void _handleOperationError(String? parent, String message) {
    final AnteTurnException error = AnteTurnException(message);
    final Completer<_AnteSessionState>? sessionWaiter = _sessionWaiters.remove(
      parent,
    );
    if (sessionWaiter != null && !sessionWaiter.isCompleted) {
      sessionWaiter.completeError(error);
      return;
    }
    final Completer<_AnteSessionState>? updateWaiter = _updateWaiters.remove(
      parent,
    );
    if (updateWaiter != null && !updateWaiter.isCompleted) {
      updateWaiter.completeError(error);
      return;
    }
    final Completer<PromptResult>? turnWaiter = _turnWaiters.remove(parent);
    if (turnWaiter != null && !turnWaiter.isCompleted) {
      _currentTurnOp = null;
      turnWaiter.completeError(error);
      return;
    }
    _publishFailureActivity(message);
  }

  void _publishFailureActivity(String message) {
    if (_session == null) return;
    _publishActivity(
      AcpAgentActivityUpdate(
        id: _nextEventId(),
        kind: 'error',
        title: message,
        status: 'failed',
      ),
    );
  }

  void _publishActivity(
    AcpAgentActivityUpdate activity, {
    bool duringReplay = false,
  }) {
    _activities[activity.id] = activity;
    _publish(activity, duringReplay: duringReplay);
  }

  void _publish(AcpSessionUpdate update, {bool duringReplay = false}) {
    final _AnteSessionState? state = _session;
    if (state == null || (_suppressReplay && !duringReplay)) return;
    _channelFor(state.sessionId).add(update);
  }

  _SessionChannel _channelFor(String sessionId) =>
      _sessionChannels.putIfAbsent(sessionId, _SessionChannel.new);

  _AnteSessionState _requireSession(String sessionId) {
    if (_disposed || _exited) {
      throw StateError('AnteClient is not running.');
    }
    final _AnteSessionState? state = _session;
    if (state == null || state.sessionId != sessionId) {
      throw StateError('Unknown Ante session: $sessionId');
    }
    return state;
  }

  Future<void> _sendOp(Object op, String id) {
    return _sendRaw(<String, Object?>{'op': op, 'id': id});
  }

  Future<void> _sendRaw(Map<String, Object?> message) async {
    await _serialized(() async {
      final Future<Process>? processFuture = _processFuture;
      if (_disposed || _exited || processFuture == null) {
        throw StateError('AnteClient is not running.');
      }
      final Process process = await processFuture;
      process.stdin.writeln(jsonEncode(message));
      await process.stdin.flush();
    });
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final Future<void> previous = _writeQueue.future;
    final Completer<void> done = Completer<void>();
    _writeQueue = done;
    return previous.then((_) => action()).whenComplete(done.complete);
  }

  void _onExit(int exitCode) {
    if (_exited) return;
    _exited = true;
    _fail(
      AnteTurnException('Ante process exited with status $exitCode.'),
      exitCode: exitCode,
    );
    unawaited(_cleanupAfterExit());
  }

  Future<void> _cleanupAfterExit() async {
    try {
      await _removeMcpHome();
    } on Object catch (error) {
      if (!_stderrController.isClosed) {
        _stderrController.add('Failed to remove transient Ante home: $error');
      }
    }
    try {
      await _removeImageDirectory();
    } on Object catch (error) {
      if (!_stderrController.isClosed) {
        _stderrController.add('Failed to remove transient Ante images: $error');
      }
    }
    await _closeStreams();
  }

  void _fail(Object error, {int? exitCode}) {
    for (final Completer<_AnteSessionState> waiter in _sessionWaiters.values) {
      if (!waiter.isCompleted) waiter.completeError(error);
    }
    _sessionWaiters.clear();
    for (final Completer<_AnteSessionState> waiter in _updateWaiters.values) {
      if (!waiter.isCompleted) waiter.completeError(error);
    }
    _updateWaiters.clear();
    for (final Completer<PromptResult> waiter in _turnWaiters.values) {
      if (!waiter.isCompleted) waiter.completeError(error);
    }
    _turnWaiters.clear();
    _currentTurnOp = null;
  }

  Future<void> _closeStreams() => _closeStreamsFuture ??= _closeStreamsOnce();

  Future<void> _closeStreamsOnce() async {
    final List<_SessionChannel> channels = _sessionChannels.values.toList(
      growable: false,
    );
    _sessionChannels.clear();
    for (final _SessionChannel channel in channels) {
      await channel.close();
    }
    if (!_stderrController.isClosed) await _stderrController.close();
  }

  String _nextOpId() => 'op_${_ulid()}';
  String _nextEventId() => 'evt_${_ulid()}';

  String _ulid() {
    final List<int> bytes = List<int>.filled(16, 0);
    var timestamp = DateTime.now().millisecondsSinceEpoch;
    for (var i = 5; i >= 0; i--) {
      bytes[i] = timestamp.remainder(256);
      timestamp ~/= 256;
    }
    for (var i = 6; i < bytes.length; i++) {
      bytes[i] = _random.nextInt(256);
    }

    const String alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
    final List<int> chars = List<int>.filled(26, 0);
    var buffer = 0;
    var bufferedBits = 2; // ULID pads its 128 bits with two leading zeroes.
    var charIndex = 0;
    for (final int byte in bytes) {
      buffer = (buffer << 8) | byte;
      bufferedBits += 8;
      while (bufferedBits >= 5) {
        bufferedBits -= 5;
        chars[charIndex++] = alphabet.codeUnitAt((buffer >> bufferedBits) & 31);
        buffer &= (1 << bufferedBits) - 1;
      }
    }
    assert(charIndex == chars.length);
    return String.fromCharCodes(chars);
  }

  static String? _uniqueProviderForModel(
    List<_AnteCatalogProvider> catalog,
    String model,
  ) {
    String? match;
    for (final _AnteCatalogProvider provider in catalog) {
      if (!provider.models.any((_AnteCatalogModel item) => item.id == model)) {
        continue;
      }
      if (match != null) return null;
      match = provider.id;
    }
    return match;
  }

  static List<AcpConfigOption> _configOptions(
    _AnteSessionState state,
    List<_AnteCatalogProvider> catalog,
  ) {
    _AnteCatalogProvider? provider;
    for (final _AnteCatalogProvider candidate in catalog) {
      if (candidate.id == state.providerId) {
        provider = candidate;
        break;
      }
    }
    final List<_AnteCatalogModel> models = <_AnteCatalogModel>[
      ...?provider?.models,
    ];
    if (!models.any((_AnteCatalogModel model) => model.id == state.modelId)) {
      models.insert(
        0,
        _AnteCatalogModel(
          id: state.modelId,
          description: state.modelDescription,
        ),
      );
    }
    return <AcpConfigOption>[
      AcpConfigOption(
        id: 'model',
        name: 'Model',
        category: 'model',
        type: 'select',
        currentValue: state.modelId,
        options: <AcpConfigOptionValue>[
          for (final _AnteCatalogModel model in models)
            AcpConfigOptionValue(
              value: model.id,
              name: model.id,
              description: model.description,
            ),
        ],
      ),
      AcpConfigOption(
        id: 'thinking',
        name: 'Effort',
        category: 'thought_level',
        type: 'select',
        currentValue: state.effort ?? '',
        options: <AcpConfigOptionValue>[
          for (final String effort in _effortValues)
            AcpConfigOptionValue(value: effort, name: _humanize(effort)),
        ],
      ),
    ];
  }

  Future<String> _textFromPromptBlocks(
    List<Map<String, Object?>> promptBlocks,
  ) async {
    final StringBuffer text = StringBuffer();
    for (final Map<String, Object?> block in promptBlocks) {
      switch (block['type']) {
        case 'text':
          final String? value = block['text'] as String?;
          if (value != null) {
            if (text.isNotEmpty) text.writeln('\n');
            text.write(value);
          }
        case 'resource':
          final Map<String, Object?> resource = _map(block['resource']);
          final String? value = resource['text'] as String?;
          if (value != null) {
            if (text.isNotEmpty) text.writeln('\n');
            text.writeln(
              '[Attached resource: ${resource['uri'] ?? 'unknown'}]',
            );
            text.write(value);
          } else {
            throw UnsupportedError(
              'Ante serve does not accept binary resource attachments.',
            );
          }
        case 'image':
          if (text.isNotEmpty) text.writeln('\n');
          final String path = await _materializeImage(block);
          text
            ..writeln('[Attached image]')
            ..write('@$path');
      }
    }
    return text.toString();
  }

  Future<String> _materializeImage(Map<String, Object?> block) async {
    final Object? rawData = block['data'];
    final Object? rawMimeType = block['mimeType'];
    if (rawData is! String ||
        rawMimeType is! String ||
        !rawMimeType.toLowerCase().startsWith('image/')) {
      throw const FormatException('Invalid Ante image attachment block.');
    }
    final List<int> bytes;
    try {
      bytes = base64Decode(rawData);
    } on FormatException {
      throw const FormatException(
        'Ante image attachment carries malformed base64 data.',
      );
    }
    final Directory directory = await _ensureImageDirectory();
    final String extension = _imageExtension(rawMimeType);
    final File file = File(
      p.join(directory.path, 'image-${++_imageFileIndex}.$extension'),
    );
    await file.writeAsBytes(bytes, flush: true);
    return file.absolute.path;
  }

  static String _imageExtension(String mimeType) =>
      switch (mimeType.toLowerCase().split(';').first.trim()) {
        'image/png' => 'png',
        'image/jpeg' || 'image/jpg' => 'jpg',
        'image/gif' => 'gif',
        'image/webp' => 'webp',
        'image/bmp' => 'bmp',
        'image/x-icon' => 'ico',
        'image/tiff' => 'tiff',
        'image/avif' => 'avif',
        'image/heic' => 'heic',
        'image/svg+xml' => 'svg',
        _ => 'img',
      };

  static List<Object?> _toolResultContent(Object? rawResult) {
    final String? text = _toolResultText(rawResult);
    if (text == null || text.isEmpty) return const <Object?>[];
    return <Object?>[
      <String, Object?>{
        'type': 'content',
        'content': <String, Object?>{'type': 'text', 'text': text},
      },
    ];
  }

  static String? _toolResultText(Object? value) {
    if (value is String) return value;
    if (value is! Map) return null;
    final Map<String, Object?> result = Map<String, Object?>.from(value);
    final Object? content = result['content'];
    if (content is String) return content;
    for (final String status in const <String>['Completed', 'Failed']) {
      final Map<String, Object?> command = _map(result[status]);
      if (command.isEmpty) continue;
      final String stdout = command['stdout'] as String? ?? '';
      final String stderr = command['stderr'] as String? ?? '';
      final List<String> output = <String>[
        if (stdout.isNotEmpty) stdout,
        if (stderr.isNotEmpty) stderr,
      ];
      final int? exitCode = _int(command['exit_code']);
      if (output.isEmpty && exitCode != null) {
        output.add('Exit code: $exitCode');
      }
      if (output.isNotEmpty) return output.join('\n');
    }
    return null;
  }

  static String _toolKind(String name) {
    final String lower = name.toLowerCase();
    if (lower.contains('read')) return 'read';
    if (lower.contains('write') ||
        lower.contains('edit') ||
        lower.contains('patch')) {
      return 'edit';
    }
    if (lower.contains('delete') || lower.contains('remove')) return 'delete';
    if (lower.contains('move') || lower.contains('rename')) return 'move';
    if (lower.contains('grep') ||
        lower.contains('glob') ||
        lower.contains('search')) {
      return 'search';
    }
    if (lower.contains('bash') ||
        lower.contains('shell') ||
        lower.contains('terminal') ||
        lower.contains('exec')) {
      return 'execute';
    }
    if (lower.contains('fetch') || lower.contains('web')) return 'fetch';
    if (lower.contains('think')) return 'think';
    return 'other';
  }

  static List<AcpToolCallLocation> _toolLocations(Map<String, Object?> input) {
    final LinkedHashSet<String> paths = LinkedHashSet<String>();
    for (final String key in const <String>[
      'path',
      'file_path',
      'filepath',
      'target_path',
    ]) {
      final Object? value = input[key];
      if (value is String && value.isNotEmpty) paths.add(value);
    }
    return <AcpToolCallLocation>[
      for (final String path in paths) AcpToolCallLocation(path: path),
    ];
  }

  static List<Map<String, Object?>> _maps(Object? value) {
    if (value is! List) return const <Map<String, Object?>>[];
    return value
        .whereType<Map>()
        .map((Map<Object?, Object?> item) => Map<String, Object?>.from(item))
        .toList(growable: false);
  }

  static List<String> _strings(Object? value) => value is List
      ? value.whereType<String>().toList(growable: false)
      : const <String>[];

  static Map<String, Object?> _map(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};

  static int? _int(Object? value) => value is num ? value.toInt() : null;

  static String _humanize(String value) {
    if (value.isEmpty) return value;
    final String spaced = value.replaceAll('_', ' ');
    return '${spaced[0].toUpperCase()}${spaced.substring(1)}';
  }
}

const List<String> _effortValues = <String>[
  'min',
  'low',
  'medium',
  'high',
  'xhigh',
  'max',
];

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
      return;
    }
    if (_pending.length == 512) _pending.removeFirst();
    _pending.addLast(update);
  }

  void _flush() {
    while (_pending.isNotEmpty && !controller.isClosed) {
      controller.add(_pending.removeFirst());
    }
  }

  Future<void> close() =>
      controller.isClosed ? Future<void>.value() : controller.close();
}

class _AnteSessionState {
  const _AnteSessionState({
    required this.sessionId,
    required this.modelId,
    required this.modelDescription,
    required this.effort,
    required this.contextLimit,
    required this.providerId,
    required this.providerName,
    required this.cwd,
    required this.permissionMode,
  });

  factory _AnteSessionState.fromJson(Map<String, Object?> json) {
    final Map<String, Object?> model = AnteClient._map(json['model']);
    final Map<String, Object?> provider = AnteClient._map(json['provider']);
    final String sessionId = json['session_id'] as String? ?? '';
    final String modelId = model['id'] as String? ?? '';
    final String providerId =
        provider['id'] as String? ?? provider['name'] as String? ?? '';
    if (sessionId.isEmpty || modelId.isEmpty || providerId.isEmpty) {
      throw const FormatException('Ante session event is missing identifiers.');
    }
    return _AnteSessionState(
      sessionId: sessionId,
      modelId: modelId,
      modelDescription: model['description'] as String?,
      effort: model['effort'] as String?,
      contextLimit: AnteClient._int(model['context_limit']),
      providerId: providerId,
      providerName: provider['display_name'] as String? ?? providerId,
      cwd: json['cwd'] as String? ?? '',
      permissionMode: json['permission_mode'] as String? ?? 'strict',
    );
  }

  final String sessionId;
  final String modelId;
  final String? modelDescription;
  final String? effort;
  final int? contextLimit;
  final String providerId;
  final String providerName;
  final String cwd;
  final String permissionMode;
}

class _AnteCatalogProvider {
  const _AnteCatalogProvider({required this.id, required this.models});

  factory _AnteCatalogProvider.fromJson(Map<String, Object?> json) =>
      _AnteCatalogProvider(
        id: json['id'] as String? ?? '',
        models:
            (json['preferred_models'] as List<Object?>?)
                ?.whereType<Map>()
                .map(
                  (Map<Object?, Object?> value) => _AnteCatalogModel.fromJson(
                    Map<String, Object?>.from(value),
                  ),
                )
                .where((_AnteCatalogModel model) => model.id.isNotEmpty)
                .toList(growable: false) ??
            const <_AnteCatalogModel>[],
      );

  final String id;
  final List<_AnteCatalogModel> models;
}

class _AnteCatalogModel {
  const _AnteCatalogModel({required this.id, this.description});

  factory _AnteCatalogModel.fromJson(Map<String, Object?> json) =>
      _AnteCatalogModel(
        id: json['id'] as String? ?? '',
        description: json['description'] as String?,
      );

  final String id;
  final String? description;
}
