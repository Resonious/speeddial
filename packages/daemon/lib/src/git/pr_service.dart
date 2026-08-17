import 'dart:io';

import 'package:speeddial_protocol/speeddial_protocol.dart';

/// Shells out to the GitHub CLI (`gh`) for pull request operations.
class PrService {
  PrService({this.ghPath = 'gh'});

  final String ghPath;

  /// Whether `gh` is present and authenticated (`gh auth status` exit 0).
  Future<bool> isAvailable() async {
    try {
      final result =
          await Process.run(ghPath, ['auth', 'status'], runInShell: false);
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    } on FileSystemException {
      return false;
    }
  }

  /// Creates a pull request for the current branch and returns its URL.
  ///
  /// Uses `gh pr create --fill` (deriving title/body from the latest commit)
  /// only when every field is absent — a provided [base] or [draft] must
  /// reach `gh` explicitly, since `--fill` alone would drop them. Otherwise
  /// each provided flag is passed individually.
  Future<String> createPullRequest(String repoPath,
      {String? title,
      String? body,
      String? base,
      bool draft = false}) async {
    final args = <String>['pr', 'create'];
    final useFill = title == null && body == null && base == null && !draft;
    if (useFill) {
      args.add('--fill');
    } else {
      if (title != null) {
        args
          ..add('--title')
          ..add(title);
      }
      if (body != null) {
        args
          ..add('--body')
          ..add(body);
      }
      if (base != null) {
        args
          ..add('--base')
          ..add(base);
      }
      if (draft) {
        args.add('--draft');
      }
    }

    ProcessResult result;
    try {
      result =
          await Process.run(ghPath, args, workingDirectory: repoPath);
    } on ProcessException catch (e) {
      throw DaemonError(
        kErrGit,
        e.message,
        {'exitCode': e.errorCode, 'args': args},
      );
    }
    if (result.exitCode != 0) {
      throw DaemonError(
        kErrGit,
        (result.stderr as String).trim(),
        {'exitCode': result.exitCode, 'args': args},
      );
    }

    final out = result.stdout as String;
    final lines = out
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    return lines.isEmpty ? '' : lines.last;
  }
}
