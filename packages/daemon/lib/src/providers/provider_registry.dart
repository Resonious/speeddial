/// Provider registry: built-in ACP agent CLIs plus user-configured additions.
///
/// Built-in providers:
///   * `omp`    → `omp acp`
///   * `claude` → `npx -y @zed-industries/claude-code-acp`
///   * `codex`  → `npx -y @zed-industries/codex-acp`
///
/// `~/.speeddial/config.json` may add or override providers under the
/// `providers` key:
///
/// ```json
/// {"providers": {"<id>": {"name": "...", "command": ["...", ...]}}}
/// ```
///
/// A provider is `available` when its executable is an absolute path that
/// exists, or resolves via `PATH`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_protocol/speeddial_protocol.dart';

/// How to spawn one provider's ACP agent.
class ProviderSpec {
  const ProviderSpec({
    required this.id,
    required this.name,
    required this.command,
  });

  /// Provider id ("omp", "claude", "codex", or a custom id).
  final String id;

  /// Display name.
  final String name;

  /// Executable plus arguments for the ACP agent subprocess.
  final List<String> command;
}

/// Registry of ACP providers known to the daemon.
///
/// The registry is immutable after construction: [configOverrides] (or the
/// on-disk config file when null) is merged over the built-ins once, and the
/// built-ins can be overridden by a user entry with the same id.
class ProviderRegistry {
  ProviderRegistry({Map<String, Object?>? configOverrides}) {
    _providers = <String, ProviderSpec>{
      'omp': const ProviderSpec(id: 'omp', name: 'OMP', command: <String>[
        'omp', 'acp',
      ]),
      'claude': const ProviderSpec(
        id: 'claude',
        name: 'Claude Code',
        command: <String>['npx', '-y', '@zed-industries/claude-code-acp'],
      ),
      'codex': const ProviderSpec(
        id: 'codex',
        name: 'Codex',
        command: <String>['npx', '-y', '@zed-industries/codex-acp'],
      ),
    };
    _applyConfig(configOverrides ?? _readConfigFile());
  }

  late final Map<String, ProviderSpec> _providers;

  /// Path of the user config file (`~/.speeddial/config.json`).
  static String configFilePath() {
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home == null || home.isEmpty) return '.speeddial/config.json';
    return p.join(home, '.speeddial', 'config.json');
  }

  /// All providers (built-ins plus user additions), with live availability.
  List<ProviderInfo> list() {
    final out = <ProviderInfo>[];
    for (final spec in _providers.values) {
      out.add(ProviderInfo(
        id: spec.id,
        name: spec.name,
        available: isAvailable(spec.id),
        command: spec.command.join(' '),
        models: const <String>[],
      ));
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
  /// Invalid entries (missing name/command or non-string command items) are
  /// skipped defensively.
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
      _providers[id] = ProviderSpec(
        id: id,
        name: name,
        command: rawCommand.cast<String>(),
      );
    }
  }
}
