/// Provider registry: built-in agent CLIs plus user-configured additions.
///
/// Built-in providers:
///   * `omp`    → `omp acp` (ACP)
///   * `claude` → `npx -y @zed-industries/claude-code-acp` (ACP)
///   * `codex`  → `codex app-server --stdio` (Codex app-server)
///   * `ante`   → `ante serve --stdio` (Ante)
///
/// `~/.speeddial/config.json` may add or override providers under the
/// `providers` key:
///
/// ```json
/// {"providers": {"<id>": {"name": "...", "command": ["...", ...],
///   "protocol": "acp"|"codex"|"ante", "models": ["model-id", ...],
///   "modelsCommand": ["...", ...], "catalogCommand": ["...", ...]}}}
/// ```
///
/// Selectable models surface on `ProviderInfo.models`:
///   * `models` — static ids; when non-empty they are used as-is and no
///     probe runs. Omitted on an override inherits the previous entry's list.
///   * `modelsCommand` — argv whose stdout is the `omp models --json` shape
///     (`{"models": [{"selector"|"id": ...}]}`); probed lazily on the first
///     `list()` and cached for the daemon's lifetime. Omitted on an override
///     inherits the previous entry's command; an explicit `[]` disables
///     probing. The built-in `omp` provider probes `omp models --json`.
///
/// A provider is `available` when its executable is an absolute path that
/// exists, or resolves via `PATH`. Unavailable providers are never probed.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../paths.dart';

/// Runs a provider's model-listing command and returns the parsed ids.
///
/// Implementations receive the full `modelsCommand` argv. The default runs
/// the process with a timeout and parses the `omp models --json` output;
/// tests inject stubs. A throwing probe degrades to an empty list.
typedef ModelsProbe = Future<List<String>> Function(List<String> command);

/// Runs an Ante-style `catalog` command and returns `provider/model` ids
/// qualified by their upstream provider. Tests inject stubs; a throwing
/// probe degrades to an empty list.
typedef CatalogProbe = Future<List<String>> Function(List<String> command);
typedef ProviderEnvironmentProvider = Map<String, String> Function();

/// Wire protocol spoken by a provider process.
enum ProviderProtocol { acp, codex, ante }

/// Auth material discovered in the Ante home for catalog filtering, plus
/// the per-provider default models chosen in Ante settings (used to order
/// each provider's models: clients present the provider choice and take
/// its first entry).
typedef _AnteAuthState = ({
  Set<String> settingsProviders,
  Set<String> storedKeys,
  Set<String> oauthPresets,
  Map<String, String> providerModels,
});

/// How to spawn one provider's agent, and how to list its models.
class ProviderSpec {
  const ProviderSpec({
    required this.id,
    required this.name,
    required this.command,
    this.protocol = ProviderProtocol.acp,
    this.models = const <String>[],
    this.modelsCommand,
    this.catalogCommand,
  });

  /// Provider id ("omp", "claude", "codex", or a custom id).
  final String id;

  /// Display name.
  final String name;

  /// Executable plus arguments for the provider subprocess.
  final List<String> command;

  /// Session protocol spoken over the provider process's stdio.
  final ProviderProtocol protocol;

  /// Static selectable model ids. When non-empty, no probe runs.
  final List<String> models;

  /// Argv of a command printing `{"models": [{"selector"|"id": ...}]}` on
  /// stdout, or null when the provider has no machine-readable model list.
  final List<String>? modelsCommand;

  /// Ante's provider catalog command. Null for non-Ante providers.
  final List<String>? catalogCommand;
}

/// Registry of providers known to the daemon.
///
/// The registry is immutable after construction: [configOverrides] (or the
/// on-disk config file when null) is merged over the built-ins once, and the
/// built-ins can be overridden by a user entry with the same id. Model probe
/// results are cached until the managed environment changes; failed probes
/// are retried on the next [list] call.
class ProviderRegistry {
  ProviderRegistry({
    Map<String, Object?>? configOverrides,
    ModelsProbe? modelsProbe,
    CatalogProbe? catalogProbe,
    Map<String, String>? environment,
    ProviderEnvironmentProvider? environmentProvider,
  }) : _modelsProbe =
           modelsProbe ??
           ((List<String> command) => _runModelsCommand(
             command,
             _effectiveEnvironment(environment, environmentProvider),
           )),
       // `environment` overrides the process environment for catalog auth
       // filtering (tests); null means the daemon's own environment.
       _catalogProbe =
           catalogProbe ??
           ((List<String> command) => _runCatalogCommand(
             command,
             _effectiveEnvironment(environment, environmentProvider),
           )) {
    _providers = <String, ProviderSpec>{
      'omp': const ProviderSpec(
        id: 'omp',
        name: 'OMP',
        command: <String>['omp', 'acp'],
        modelsCommand: <String>['omp', 'models', '--json'],
      ),
      'claude': const ProviderSpec(
        id: 'claude',
        name: 'Claude Code',
        command: <String>['npx', '-y', '@zed-industries/claude-code-acp'],
      ),
      'codex': const ProviderSpec(
        id: 'codex',
        name: 'Codex',
        command: <String>['codex', 'app-server', '--stdio'],
        protocol: ProviderProtocol.codex,
      ),
      'ante': const ProviderSpec(
        id: 'ante',
        name: 'Ante',
        command: <String>['ante', 'serve', '--stdio'],
        protocol: ProviderProtocol.ante,
        catalogCommand: <String>['ante', 'catalog'],
      ),
    };
    _applyConfig(configOverrides ?? _readConfigFile());
  }

  late final Map<String, ProviderSpec> _providers;
  final ModelsProbe _modelsProbe;
  final CatalogProbe _catalogProbe;

  /// Successful probe results by provider id.
  final Map<String, List<String>> _probedModels = <String, List<String>>{};

  /// In-flight probes by provider id, so concurrent [list] calls share one.
  final Map<String, Future<List<String>>> _probesInFlight =
      <String, Future<List<String>>>{};
  int _environmentRevision = 0;

  /// Clears environment-sensitive model/catalog results after a settings edit.
  void environmentChanged() {
    _environmentRevision++;
    _probedModels.clear();
    _probesInFlight.clear();
  }

  /// Path of the user config file (`~/.speeddial/config.json`).
  static String configFilePath() {
    final home = homeDir();
    if (home == null) return '.speeddial/config.json';
    return p.join(home, '.speeddial', 'config.json');
  }

  /// All providers (built-ins plus user additions), with live availability
  /// and selectable models (static or probed).
  Future<List<ProviderInfo>> list() async {
    final out = <ProviderInfo>[];
    for (final spec in _providers.values) {
      out.add(
        ProviderInfo(
          id: spec.id,
          name: spec.name,
          available: isAvailable(spec.id),
          command: spec.command.join(' '),
          models: await _modelsFor(spec),
          protocol: spec.protocol.name,
          sandboxModes: spec.protocol == ProviderProtocol.codex
              ? const <SessionSandboxMode>[
                  SessionSandboxMode.workspaceWrite,
                  SessionSandboxMode.unrestricted,
                ]
              : const <SessionSandboxMode>[],
        ),
      );
    }
    return out;
  }

  /// The provider spec, or null for an unknown id.
  ProviderSpec? byId(String id) => _providers[id];

  /// Whether the provider's executable can be launched on this host:
  /// an absolute command that exists, or an executable found on `PATH`.
  bool isAvailable(String id) {
    final spec = _providers[id];
    return spec != null && _isResolvable(spec.command.first);
  }

  static bool _isResolvable(String executable) {
    if (p.isAbsolute(executable)) {
      return File(executable).existsSync();
    }
    final pathEnv = Platform.environment['PATH'];
    if (pathEnv == null || pathEnv.isEmpty) return false;
    final separator = Platform.isWindows ? ';' : ':';
    for (final dir in pathEnv.split(separator)) {
      if (dir.isEmpty) continue;
      if (File(p.join(dir, executable)).existsSync()) return true;
    }
    return false;
  }

  /// The selectable models for [spec]: the static list when configured,
  /// otherwise a cached or fresh probe of [ProviderSpec.modelsCommand] (or,
  /// for Ante, [ProviderSpec.catalogCommand]). Unavailable providers and
  /// probe failures yield an empty list.
  Future<List<String>> _modelsFor(ProviderSpec spec) {
    if (spec.models.isNotEmpty) return Future<List<String>>.value(spec.models);
    final cached = _probedModels[spec.id];
    if (cached != null) return Future<List<String>>.value(cached);
    final bool hasModelsCommand =
        spec.modelsCommand != null && spec.modelsCommand!.isNotEmpty;
    final bool hasCatalogCommand =
        spec.catalogCommand != null && spec.catalogCommand!.isNotEmpty;
    if ((!hasModelsCommand && !hasCatalogCommand) || !isAvailable(spec.id)) {
      return Future<List<String>>.value(const <String>[]);
    }
    final List<String> command = hasModelsCommand
        ? spec.modelsCommand!
        : spec.catalogCommand!;
    final inFlight = _probesInFlight[spec.id];
    if (inFlight != null) return inFlight;
    final int environmentRevision = _environmentRevision;
    final future = () async {
      List<String> models;
      try {
        models = hasModelsCommand
            ? await _modelsProbe(command)
            : await _catalogProbe(command);
      } on Object {
        models = const <String>[];
      }
      // Only successes are cached: a transient failure (e.g. the tool was
      // briefly missing) recovers on the next list() call.
      if (models.isNotEmpty && environmentRevision == _environmentRevision) {
        _probedModels[spec.id] = models;
      }
      return models;
    }();
    _probesInFlight[spec.id] = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_probesInFlight[spec.id], future)) {
          _probesInFlight.remove(spec.id);
        }
      }),
    );
    return future;
  }

  /// Default [ModelsProbe]: runs the command and parses the
  /// `omp models --json` output shape. Never throws: any failure (spawn,
  /// timeout, non-zero exit, malformed JSON) yields an empty list.
  static Future<List<String>> _runModelsCommand(
    List<String> command,
    Map<String, String> environment,
  ) async {
    try {
      final result = await Process.run(
        command.first,
        command.sublist(1),
        environment: environment,
        includeParentEnvironment: false,
      ).timeout(const Duration(seconds: 5));
      if (result.exitCode != 0) return const <String>[];
      final decoded = jsonDecode(result.stdout as String);
      if (decoded is! Map) return const <String>[];
      final rawModels = decoded['models'];
      if (rawModels is! List) return const <String>[];
      final seen = <String>{};
      final models = <String>[];
      for (final entry in rawModels) {
        if (entry is! Map) continue;
        final id = entry['selector'] ?? entry['id'];
        if (id is String && id.isNotEmpty && seen.add(id)) models.add(id);
      }
      return models;
    } on Object {
      return const <String>[];
    }
  }

  /// Default [CatalogProbe]: runs the command, parses the `ante catalog`
  /// shape into provider-qualified model ids (ambiguous bare ids collide
  /// across upstream providers), and drops providers the user cannot
  /// actually run — see [_usableAnteProviderIds]. Never throws.
  static Future<List<String>> _runCatalogCommand(
    List<String> command,
    Map<String, String> environment,
  ) async {
    try {
      final result = await Process.run(
        command.first,
        command.sublist(1),
        environment: environment,
        includeParentEnvironment: false,
      ).timeout(const Duration(seconds: 5));
      if (result.exitCode != 0) return const <String>[];
      final decoded = jsonDecode(result.stdout as String);
      if (decoded is! Map) return const <String>[];
      final rawProviders = decoded['providers'];
      if (rawProviders is! List) return const <String>[];
      final Map<String, String> env = environment;
      final _AnteAuthState authState = _readAnteAuthState(env);
      final seen = <String>{};
      final models = <String>[];
      for (final rawProvider in rawProviders) {
        if (rawProvider is! Map) continue;
        final providerId = rawProvider['id'];
        if (providerId is! String || providerId.isEmpty) continue;
        if (!_anteProviderUsable(rawProvider, providerId, env, authState)) {
          continue;
        }
        final rawModels = rawProvider['preferred_models'];
        if (rawModels is! List) continue;
        // The settings-chosen model for this provider sorts first: clients
        // present the provider choice and take each provider's first entry
        // as its default.
        final String? defaultModel = authState.providerModels[providerId];
        final List<String> ids = <String>[
          for (final rawModel in rawModels)
            if (rawModel is Map &&
                rawModel['id'] is String &&
                (rawModel['id'] as String).isNotEmpty)
              rawModel['id'] as String,
        ];
        if (defaultModel != null && ids.remove(defaultModel)) {
          ids.insert(0, defaultModel);
        }
        for (final String modelId in ids) {
          if (seen.add('$providerId/$modelId')) {
            models.add('$providerId/$modelId');
          }
        }
      }
      return models;
    } on Object {
      return const <String>[];
    }
  }

  static Map<String, String> _effectiveEnvironment(
    Map<String, String>? override,
    ProviderEnvironmentProvider? provider,
  ) {
    if (override != null) return override;
    return <String, String>{...Platform.environment, ...?provider?.call()};
  }

  /// Auth material found in the Ante home (`ANTE_HOME` or `~/.ante`):
  /// providers named by settings (`provider` plus the `provider_model`
  /// keys — providers the user has actually chosen), API keys stored in
  /// `auth/api_keys.json`, and OAuth presets with a token file under
  /// `auth/`. Reading the home is best-effort: any failure just yields
  /// fewer usable providers, never a probe crash.
  static _AnteAuthState _readAnteAuthState(Map<String, String> env) {
    final Set<String> settingsProviders = <String>{};
    final Set<String> storedKeys = <String>{};
    final Set<String> oauthPresets = <String>{};
    final Map<String, String> providerModels = <String, String>{};
    final String? home = switch (env['ANTE_HOME']) {
      final String v when v.isNotEmpty => v,
      _ => switch (env['HOME'] ?? env['USERPROFILE']) {
        final String v when v.isNotEmpty => p.join(v, '.ante'),
        _ => null,
      },
    };
    if (home == null) {
      return (
        settingsProviders: settingsProviders,
        storedKeys: storedKeys,
        oauthPresets: oauthPresets,
        providerModels: providerModels,
      );
    }
    try {
      final File settingsFile = File(p.join(home, 'settings.json'));
      if (settingsFile.existsSync()) {
        final Object? decoded = jsonDecode(settingsFile.readAsStringSync());
        if (decoded is Map) {
          final Object? provider = decoded['provider'];
          if (provider is String && provider.isNotEmpty) {
            settingsProviders.add(provider);
          }
          final Object? providerModel = decoded['provider_model'];
          if (providerModel is Map) {
            for (final MapEntry<Object?, Object?> entry
                in providerModel.entries) {
              if (entry.key is String &&
                  (entry.key as String).isNotEmpty &&
                  entry.value is String &&
                  (entry.value as String).isNotEmpty) {
                settingsProviders.add(entry.key as String);
                providerModels[entry.key as String] = entry.value as String;
              }
            }
          }
          // The global settings default is that provider's default model.
          final Object? settingsModel = decoded['model'];
          if (provider is String &&
              provider.isNotEmpty &&
              settingsModel is String &&
              settingsModel.isNotEmpty) {
            providerModels.putIfAbsent(provider, () => settingsModel);
          }
        }
      }
    } on Object {
      // Malformed settings: filter by auth state alone.
    }
    try {
      final File keysFile = File(p.join(home, 'auth', 'api_keys.json'));
      if (keysFile.existsSync()) {
        final Object? decoded = jsonDecode(keysFile.readAsStringSync());
        if (decoded is Map) {
          storedKeys.addAll(decoded.keys.whereType<String>());
        }
      }
    } on Object {
      // Malformed api_keys.json: env vars still count.
    }
    try {
      final Directory authDir = Directory(p.join(home, 'auth'));
      if (authDir.existsSync()) {
        for (final FileSystemEntity entry in authDir.listSync()) {
          final String name = p.basename(entry.path);
          if (name.endsWith('.json') && name != 'api_keys.json') {
            oauthPresets.add(name.substring(0, name.length - 5));
          }
        }
      }
    } on Object {
      // Unreadable auth dir: OAuth presets are simply not usable.
    }
    return (
      settingsProviders: settingsProviders,
      storedKeys: storedKeys,
      oauthPresets: oauthPresets,
      providerModels: providerModels,
    );
  }

  /// Whether a catalog provider entry can actually run: providers with no
  /// auth descriptor are always usable; `env_key` auth needs the variable
  /// in the process environment or stored in `auth/api_keys.json`;
  /// `oauth_preset` auth needs a token file under `auth/`; settings-listed
  /// providers are always kept.
  static bool _anteProviderUsable(
    Map<Object?, Object?> rawProvider,
    String providerId,
    Map<String, String> env,
    _AnteAuthState authState,
  ) {
    if (authState.settingsProviders.contains(providerId)) return true;
    final Object? auth = rawProvider['auth'];
    if (auth is! Map) return true;
    for (final Object? shape in auth.values) {
      if (shape is! Map) continue;
      final Object? envKey = shape['env_key'];
      if (envKey is String &&
          envKey.isNotEmpty &&
          (env.containsKey(envKey) || authState.storedKeys.contains(envKey))) {
        return true;
      }
      final Object? preset = shape['oauth_preset'];
      if (preset is String &&
          preset.isNotEmpty &&
          authState.oauthPresets.contains(preset)) {
        return true;
      }
    }
    return false;
  }

  /// Loads `~/.speeddial/config.json`; a missing or malformed file yields
  /// null (user config must never crash the daemon).
  Map<String, Object?>? _readConfigFile() {
    final file = File(configFilePath());
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map) return Map<String, Object?>.from(decoded);
    } on Object {
      // Malformed config: ignore.
    }
    return null;
  }

  /// Merges the `providers` map of [config] over the built-ins.
  /// Entries with a missing name/command or non-string command items are
  /// skipped defensively; malformed `models`/`modelsCommand` fields are
  /// ignored without dropping the provider.
  void _applyConfig(Map<String, Object?>? config) {
    if (config == null) return;
    final rawProviders = config['providers'];
    if (rawProviders is! Map) return;
    for (final entry in rawProviders.entries) {
      final id = entry.key;
      if (id is! String || entry.value is! Map) continue;
      final specMap = Map<String, Object?>.from(entry.value as Map);
      final name = specMap['name'];
      final rawCommand = specMap['command'];
      if (name is! String ||
          rawCommand is! List ||
          rawCommand.isEmpty ||
          rawCommand.any((c) => c is! String)) {
        continue;
      }
      final previous = _providers[id];
      _providers[id] = ProviderSpec(
        id: id,
        name: name,
        command: rawCommand.cast<String>(),
        protocol: switch (specMap['protocol']) {
          'ante' => ProviderProtocol.ante,
          'codex' => ProviderProtocol.codex,
          'acp' => ProviderProtocol.acp,
          _ => ProviderProtocol.acp,
        },
        models:
            _stringList(specMap['models']) ??
            previous?.models ??
            const <String>[],
        modelsCommand: specMap.containsKey('modelsCommand')
            ? _stringList(specMap['modelsCommand'])
            : previous?.modelsCommand,
        catalogCommand: specMap.containsKey('catalogCommand')
            ? _stringList(specMap['catalogCommand'])
            : previous?.catalogCommand,
      );
    }
  }

  /// [value] as a list of strings, or null when absent or malformed. An
  /// empty list is preserved: for `modelsCommand` it disables probing.
  static List<String>? _stringList(Object? value) {
    if (value == null) return null;
    if (value is! List || value.any((e) => e is! String)) return null;
    return value.cast<String>();
  }
}
