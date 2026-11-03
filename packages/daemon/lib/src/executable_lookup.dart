import 'dart:io';

import 'package:path/path.dart' as p;

/// Checks PATH, including Windows executable extensions, without a shell.
/// Platform and filesystem overrides allow Windows coverage on any test host.
bool isExecutableResolvable(
  String executable,
  Map<String, String> environment, {
  bool? isWindows,
  bool Function(String)? fileExists,
}) {
  final bool windows = isWindows ?? Platform.isWindows;
  final p.Context paths = p.Context(
    style: windows ? p.Style.windows : p.Style.posix,
  );
  final bool Function(String) exists =
      fileExists ?? (String path) => File(path).existsSync();
  if (paths.isAbsolute(executable)) return exists(executable);
  final String? path = environment['PATH'];
  if (path == null || path.isEmpty) return false;
  final List<String> suffixes = windows
      ? <String>[
          '',
          ...(environment['PATHEXT'] ?? '.EXE;.CMD;.BAT;.COM')
              .split(';')
              .map((String value) => value.toLowerCase()),
        ]
      : const <String>[''];
  for (final String directory in path.split(windows ? ';' : ':')) {
    if (directory.isEmpty) continue;
    for (final String suffix in suffixes) {
      if (exists(paths.join(directory, '$executable$suffix'))) return true;
    }
  }
  return false;
}
