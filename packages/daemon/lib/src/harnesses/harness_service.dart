/// Detection, version probing, and native updates for supported harness CLIs.
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_protocol/speeddial_protocol.dart';

typedef HarnessEnvironmentProvider = Map<String, String> Function();
typedef HarnessExecutableResolver = bool Function(
  String executable,
  Map<String, String> environment,
);
typedef HarnessProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments, {
  required Map<String, String> environment,
});

typedef _HarnessSpec = ({String id, String name, String executable});

const List<_HarnessSpec> _supportedHarnesses = <_HarnessSpec>[
  (id: 'omp', name: 'OMP', executable: 'omp'),
  (id: 'claude', name: 'Claude Code', executable: 'claude'),
  (id: 'codex', name: 'Codex', executable: 'codex'),
  (id: 'ante', name: 'Ante', executable: 'ante'),
];

/// Runs only fixed commands for SpeedDial's supported, installed harnesses.
class HarnessService {
  HarnessService({
    HarnessEnvironmentProvider? environmentProvider,
    HarnessExecutableResolver? executableResolver,
    HarnessProcessRunner? processRunner,
  }) : _environmentProvider = environmentProvider ?? _emptyEnvironmentProvider,
       _executableResolver = executableResolver ?? _isResolvable,
       _processRunner = processRunner ?? _runProcess;

  final HarnessEnvironmentProvider _environmentProvider;
  final HarnessExecutableResolver _executableResolver;
  final HarnessProcessRunner _processRunner;
  final Set<String> _updating = <String>{};

  /// Installed supported harnesses in stable product order.
  Future<List<HarnessInfo>> list() async {
    final Map<String, String> environment = _environment();
    final List<Future<HarnessInfo>> probes = <Future<HarnessInfo>>[];
    for (final _HarnessSpec spec in _supportedHarnesses) {
      if (_executableResolver(spec.executable, environment)) {
        probes.add(_probe(spec, environment));
      }
    }
    return Future.wait(probes);
  }

  /// Runs `<harness> update`, then returns the freshly probed version.
  Future<HarnessInfo> update(String id) async {
    final _HarnessSpec? spec = _specFor(id);
    if (spec == null) {
      throw DaemonError(kErrNotFound, 'Unknown harness: $id');
    }
    final Map<String, String> environment = _environment();
    if (!_executableResolver(spec.executable, environment)) {
      throw DaemonError(
        kErrProviderUnavailable,
        '${spec.name} is not installed',
      );
    }
    if (!_updating.add(id)) {
      throw DaemonError(kErrConflict, '${spec.name} is already updating');
    }
    try {
      final ProcessResult result;
      try {
        result = await _processRunner(spec.executable, const <String>[
          'update',
        ], environment: environment);
      } on ProcessException catch (error) {
        throw DaemonError(
          kErrAgentProcess,
          'Could not update ${spec.name}: ${error.message}',
        );
      }
      if (result.exitCode != 0) {
        final String detail =
            _firstLine(result.stderr) ??
            _firstLine(result.stdout) ??
            'exit code ${result.exitCode}';
        throw DaemonError(
          kErrAgentProcess,
          '${spec.name} update failed: $detail',
        );
      }
      return await _probe(spec, environment);
    } finally {
      _updating.remove(id);
    }
  }

  Future<HarnessInfo> _probe(
    _HarnessSpec spec,
    Map<String, String> environment,
  ) async {
    String version = 'Version unavailable';
    try {
      final ProcessResult result = await _processRunner(
        spec.executable,
        const <String>['--version'],
        environment: environment,
      ).timeout(const Duration(seconds: 10));
      if (result.exitCode == 0) {
        version =
            _firstLine(result.stdout) ?? _firstLine(result.stderr) ?? version;
      }
    } on Object {
      // A resolvable harness remains installed even when its version probe is
      // unsupported or temporarily fails.
    }
    return HarnessInfo(id: spec.id, name: spec.name, version: version);
  }

  Map<String, String> _environment() => <String, String>{
    ...Platform.environment,
    ..._environmentProvider(),
  };

  static _HarnessSpec? _specFor(String id) {
    for (final _HarnessSpec spec in _supportedHarnesses) {
      if (spec.id == id) return spec;
    }
    return null;
  }

  static String? _firstLine(Object? output) {
    final String text = output?.toString() ?? '';
    for (final String line in text.split(RegExp(r'[\r\n]+'))) {
      final String normalized = line
          .replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '')
          .trim();
      if (normalized.isNotEmpty) {
        return normalized.length <= 200
            ? normalized
            : normalized.substring(0, 200);
      }
    }
    return null;
  }

  static bool _isResolvable(
    String executable,
    Map<String, String> environment,
  ) {
    if (p.isAbsolute(executable)) return File(executable).existsSync();
    final String? path = environment['PATH'];
    if (path == null || path.isEmpty) return false;
    final List<String> suffixes = Platform.isWindows
        ? <String>[
            '',
            ...(environment['PATHEXT'] ?? '.EXE;.CMD;.BAT;.COM')
                .split(';')
                .map((String value) => value.toLowerCase()),
          ]
        : const <String>[''];
    final String separator = Platform.isWindows ? ';' : ':';
    for (final String directory in path.split(separator)) {
      if (directory.isEmpty) continue;
      for (final String suffix in suffixes) {
        if (File(p.join(directory, '$executable$suffix')).existsSync()) {
          return true;
        }
      }
    }
    return false;
  }

  static Future<ProcessResult> _runProcess(
    String executable,
    List<String> arguments, {
    required Map<String, String> environment,
  }) => Process.run(
    executable,
    arguments,
    environment: environment,
    includeParentEnvironment: false,
  );

  static Map<String, String> _emptyEnvironmentProvider() =>
      const <String, String>{};
}
