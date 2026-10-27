import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:speeddial_protocol/speeddial_protocol.dart';

/// Shells out to the GitHub CLI (`gh`) for pull request operations.
class PrService {
  PrService({this.ghPath = 'gh'});

  final String ghPath;

  /// Resolve only SpeedDial-managed worktree identities. Forked sessions keep
  /// the original cwd, so their own session IDs must not be used here.
  Future<List<Session>> findSessions(String url, List<Session> sessions) async {
    final GithubPrLink? link = GithubPrLink.parse(url);
    if (link == null) return const <Session>[];
    try {
      final Process process = await Process.start(
        ghPath,
        <String>['pr', 'view', link.url, '--json', 'headRefName'],
        environment: <String, String>{'GH_PROMPT_DISABLED': '1'},
      );
      final Future<String> output = process.stdout
          .transform(utf8.decoder)
          .join();
      final Future<void> errors = process.stderr.drain<void>();
      final int code;
      try {
        code = await process.exitCode.timeout(const Duration(seconds: 15));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
        rethrow;
      } finally {
        await errors;
      }
      final String text = await output;
      if (code != 0) throw StateError('gh pr view exited $code');
      final Object? json = jsonDecode(text);
      final Object? branch = json is Map ? json['headRefName'] : null;
      if (branch is! String) {
        throw const FormatException('Missing PR headRefName');
      }
      final RegExpMatch? match = RegExp(r'^speeddial/.+-([0-9a-f]{8})$')
          .firstMatch(branch);
      if (match == null) return const <Session>[];
      final String id = match.group(1)!;
      return sessions
          .where(
            (Session session) =>
                p.basename(p.dirname(session.cwd)) == '.speeddial-worktrees' &&
                p.basename(session.cwd).endsWith('-$id'),
          )
          .toList();
    } on Object catch (error) {
      stderr.writeln(
        'Warning: could not resolve GitHub PR ${link.url}: $error',
      );
      return const <Session>[];
    }
  }

  /// Whether `gh` is present and authenticated (`gh auth status` exit 0).
  Future<bool> isAvailable() async {
    try {
      final result = await Process.run(ghPath, [
        'auth',
        'status',
      ], runInShell: false);
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    } on FileSystemException {
      return false;
    }
  }

  /// Creates a pull request for the current branch and returns its URL.
  ///
  /// Title/body derive from the latest commit via `--fill` when both are
  /// absent — passing `--base` or `--draft` must never drop the fill, since
  /// `gh` would otherwise prompt interactively and hang a non-tty daemon.
  Future<String> createPullRequest(
    String repoPath, {
    String? title,
    String? body,
    String? base,
    bool draft = false,
  }) async {
    final args = <String>['pr', 'create'];
    if (title == null && body == null) {
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
    }
    if (base != null) {
      args
        ..add('--base')
        ..add(base);
    }
    if (draft) {
      args.add('--draft');
    }

    ProcessResult result;
    try {
      result = await Process.run(ghPath, args, workingDirectory: repoPath);
    } on ProcessException catch (e) {
      throw DaemonError(kErrGit, e.message, {
        'exitCode': e.errorCode,
        'args': args,
      });
    }
    if (result.exitCode != 0) {
      throw DaemonError(kErrGit, (result.stderr as String).trim(), {
        'exitCode': result.exitCode,
        'args': args,
      });
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
