/// `git` command group: status/diff/branches/commit/push/pr/merge-base
/// against a project's repository on the daemon host. Every subcommand
/// requires `--project <id>`.
library;

import 'package:args/command_runner.dart';

import 'cli_runner.dart';
import 'output.dart';

class GitCommand extends Command<int> {
  GitCommand() {
    addSubcommand(GitStatusCommand());
    addSubcommand(GitDiffCommand());
    addSubcommand(GitBranchesCommand());
    addSubcommand(GitCommitCommand());
    addSubcommand(GitPushCommand());
    addSubcommand(GitPrCommand());
    addSubcommand(GitMergeBaseCommand());
  }

  @override
  final String name = 'git';

  @override
  final String description = 'Git operations for a project.';

  @override
  Future<int> run() =>
      throw UsageException('Missing subcommand for "git".', usage);
}

/// `speeddial git status --project <id>`
class GitStatusCommand extends Command<int> {
  GitStatusCommand() {
    argParser.addOption('project', help: 'Project id (required).');
  }

  @override
  final String name = 'status';

  @override
  final String description = 'Show the repository status.';

  @override
  bool get takesArguments => false;

  @override
  Future<int> run() async {
    final project = _requireProject(this);
    final conn = resolveConnection(globalResults!);
    final output = Output(json: conn.json);
    return withDaemon(conn, (client) async {
      final status = await client.gitStatus(project);
      if (conn.json) {
        output.raw(<String, Object?>{'status': status.toJson()});
      } else {
        output.line('On branch ${status.branch} — ahead ${status.ahead}, '
            'behind ${status.behind}');
        if (status.files.isEmpty) {
          output.line('nothing to commit, working tree clean');
        } else {
          output.table(
            const ['PATH', 'INDEX', 'WORKTREE'],
            [
              for (final file in status.files)
                [file.path, file.indexStatus, file.worktreeStatus],
            ],
          );
        }
      }
      return Exit.ok;
    });
  }
}

/// `speeddial git diff [--staged] [--path p] --project <id>`
class GitDiffCommand extends Command<int> {
  GitDiffCommand() {
    argParser
      ..addOption('project', help: 'Project id (required).')
      ..addFlag('staged', negatable: false, help: 'Show the staged (index) diff.')
      ..addOption('path', help: 'Restrict to this repository-relative path.');
  }

  @override
  final String name = 'diff';

  @override
  final String description = 'Show unified diffs of changed files.';

  @override
  bool get takesArguments => false;

  @override
  Future<int> run() async {
    final project = _requireProject(this);
    final conn = resolveConnection(globalResults!);
    final output = Output(json: conn.json);
    return withDaemon(conn, (client) async {
      final diffs = await client.gitDiff(
        project,
        path: argResults!['path'] as String?,
        staged: argResults!.flag('staged'),
      );
      if (conn.json) {
        output.raw(<String, Object?>{
          'diffs': [for (final diff in diffs) diff.toJson()],
        });
      } else if (diffs.isEmpty) {
        output.line('No changes.');
      } else {
        for (final diff in diffs) {
          if (diff.isBinary) {
            output.line('Binary file ${diff.path}');
            continue;
          }
          output.write(diff.patch);
          if (!diff.patch.endsWith('\n')) output.write('\n');
        }
        output.flush();
      }
      return Exit.ok;
    });
  }
}

/// `speeddial git branches --project <id>`
class GitBranchesCommand extends Command<int> {
  GitBranchesCommand() {
    argParser.addOption('project', help: 'Project id (required).');
  }

  @override
  final String name = 'branches';

  @override
  final String description = 'List local branches.';

  @override
  bool get takesArguments => false;

  @override
  Future<int> run() async {
    final project = _requireProject(this);
    final conn = resolveConnection(globalResults!);
    final output = Output(json: conn.json);
    return withDaemon(conn, (client) async {
      final branches = await client.gitBranches(project);
      if (conn.json) {
        output.raw(<String, Object?>{
          'branches': [for (final branch in branches) branch.toJson()],
        });
      } else {
        output.table(
          const ['BRANCH', 'UPSTREAM'],
          [
            for (final branch in branches)
              [
                branch.isCurrent ? '* ${branch.name}' : branch.name,
                branch.upstream ?? '',
              ],
          ],
        );
      }
      return Exit.ok;
    });
  }
}

/// `speeddial git commit -m <msg> [--all] --project <id>`
class GitCommitCommand extends Command<int> {
  GitCommitCommand() {
    argParser
      ..addOption('project', help: 'Project id (required).')
      ..addOption('message',
          abbr: 'm', help: 'Commit message (required).')
      ..addFlag('all', negatable: false, help: 'Stage all changes first.');
  }

  @override
  final String name = 'commit';

  @override
  final String description = 'Commit staged (or all) changes.';

  @override
  bool get takesArguments => false;

  @override
  Future<int> run() async {
    final project = _requireProject(this);
    final message = argResults!['message'] as String?;
    if (message == null || message.trim().isEmpty) {
      throw UsageException('Commit message required: --message/-m.', usage);
    }
    final conn = resolveConnection(globalResults!);
    final output = Output(json: conn.json);
    return withDaemon(conn, (client) async {
      final hash =
          await client.gitCommit(project, message, stageAll: argResults!.flag('all'));
      if (conn.json) {
        output.raw(<String, Object?>{'commitHash': hash});
      } else {
        output.line('Committed ${hash.length > 8 ? hash.substring(0, 8) : hash}');
      }
      return Exit.ok;
    });
  }
}

/// `speeddial git push --project <id>`
class GitPushCommand extends Command<int> {
  GitPushCommand() {
    argParser.addOption('project', help: 'Project id (required).');
  }

  @override
  final String name = 'push';

  @override
  final String description = 'Push the current branch.';

  @override
  bool get takesArguments => false;

  @override
  Future<int> run() async {
    final project = _requireProject(this);
    final conn = resolveConnection(globalResults!);
    final output = Output(json: conn.json);
    return withDaemon(conn, (client) async {
      await client.gitPush(project);
      if (conn.json) {
        output.raw(const <String, Object?>{});
      } else {
        output.line('Pushed');
      }
      return Exit.ok;
    });
  }
}

/// `speeddial git pr [--title t] [--body b] [--base b] [--draft] --project <id>`
class GitPrCommand extends Command<int> {
  GitPrCommand() {
    argParser
      ..addOption('project', help: 'Project id (required).')
      ..addOption('title', help: 'PR title (defaults to the latest commit).')
      ..addOption('body', help: 'PR body.')
      ..addOption('base', help: 'Base branch (default: the repo default).')
      ..addFlag('draft', negatable: false, help: 'Create as a draft PR.');
  }

  @override
  final String name = 'pr';

  @override
  final String description = 'Create a pull request with gh.';

  @override
  bool get takesArguments => false;

  @override
  Future<int> run() async {
    final project = _requireProject(this);
    final conn = resolveConnection(globalResults!);
    final output = Output(json: conn.json);
    return withDaemon(conn, (client) async {
      final url = await client.gitCreatePr(
        project,
        title: argResults!['title'] as String?,
        body: argResults!['body'] as String?,
        base: argResults!['base'] as String?,
        draft: argResults!.flag('draft'),
      );
      if (conn.json) {
        output.raw(<String, Object?>{'url': url});
      } else {
        output.line(url);
      }
      return Exit.ok;
    });
  }
}

/// `speeddial git merge-base --project <id> --session <id>`
class GitMergeBaseCommand extends Command<int> {
  GitMergeBaseCommand() {
    argParser
      ..addOption('project', help: 'Project id (required).')
      ..addOption('session',
          help: 'Session id (required; must have a base branch).');
  }

  @override
  final String name = 'merge-base';

  @override
  final String description =
      'Merge a session branch back into its base branch.';

  @override
  bool get takesArguments => false;

  @override
  Future<int> run() async {
    final project = _requireProject(this);
    final session = argResults!['session'] as String?;
    if (session == null || session.isEmpty) {
      throw UsageException('Missing required option: --session.', usage);
    }
    final conn = resolveConnection(globalResults!);
    final output = Output(json: conn.json);
    return withDaemon(conn, (client) async {
      final merge = await client.gitMergeToBase(project, session);
      if (conn.json) {
        output.raw(<String, Object?>{'merge': merge.toJson()});
      } else if (merge.alreadyUpToDate) {
        output.line(
            '${merge.baseBranch} already contains ${merge.sessionBranch}.');
      } else {
        final how = merge.fastForward ? 'fast-forward' : 'merge commit';
        final short = merge.commit.length > 8
            ? merge.commit.substring(0, 8)
            : merge.commit;
        output.line(
            'Merged ${merge.sessionBranch} into ${merge.baseBranch} '
            '($how, $short)'
            '${merge.baseFastForwarded ? ' — ${merge.baseBranch} first '
                'fast-forwarded to origin/${merge.baseBranch}' : ''}');
      }
      return Exit.ok;
    });
  }
}

String _requireProject(Command<int> command) {
  final project = command.argResults!['project'] as String?;
  if (project == null || project.isEmpty) {
    throw UsageException('Missing required option: --project.', command.usage);
  }
  return project;
}
