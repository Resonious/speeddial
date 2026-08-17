/// `projects` command group: list/add/remove projects on the daemon.
library;

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import 'cli_runner.dart';
import 'output.dart';

class ProjectsCommand extends Command<int> {
  ProjectsCommand() {
    addSubcommand(ProjectsListCommand());
    addSubcommand(ProjectsAddCommand());
    addSubcommand(ProjectsRemoveCommand());
  }

  @override
  final String name = 'projects';

  @override
  final String description = 'Manage local projects.';

  @override
  Future<int> run() =>
      throw UsageException('Missing subcommand for "projects".', usage);
}

/// `speeddial projects list` — all projects, oldest added first.
class ProjectsListCommand extends Command<int> {
  @override
  final String name = 'list';

  @override
  final String description = 'List projects.';

  @override
  bool get takesArguments => false;

  @override
  Future<int> run() async {
    final conn = resolveConnection(globalResults!);
    final output = Output(json: conn.json);
    return withDaemon(conn, (client) async {
      final projects = await client.listProjects();
      if (conn.json) {
        output.raw(<String, Object?>{
          'projects': [for (final project in projects) project.toJson()],
        });
      } else {
        output.table(
          const ['ID', 'NAME', 'PATH'],
          [
            for (final project in projects)
              [project.id, project.name, project.path],
          ],
        );
      }
      return Exit.ok;
    });
  }
}

/// `speeddial projects add <path>` — registers a local directory.
class ProjectsAddCommand extends Command<int> {
  @override
  final String name = 'add';

  @override
  final String description = 'Add a project directory.';

  @override
  Future<int> run() async {
    if (argResults!.rest.isEmpty) {
      throw UsageException('Missing <path> argument.', usage);
    }
    final path = p.normalize(p.absolute(argResults!.rest.first));
    final conn = resolveConnection(globalResults!);
    final output = Output(json: conn.json);
    return withDaemon(conn, (client) async {
      final project = await client.addProject(path);
      if (conn.json) {
        output.raw(<String, Object?>{'project': project.toJson()});
      } else {
        output.record(<String, Object?>{
          'id': project.id,
          'name': project.name,
          'path': project.path,
        });
      }
      return Exit.ok;
    });
  }
}

/// `speeddial projects remove <id>` — detaches the project (archives its
/// sessions; never touches the filesystem).
class ProjectsRemoveCommand extends Command<int> {
  @override
  final String name = 'remove';

  @override
  final String description = 'Remove a project (archives its sessions).';

  @override
  Future<int> run() async {
    if (argResults!.rest.isEmpty) {
      throw UsageException('Missing <id> argument.', usage);
    }
    final id = argResults!.rest.first;
    final conn = resolveConnection(globalResults!);
    final output = Output(json: conn.json);
    return withDaemon(conn, (client) async {
      await client.removeProject(id);
      if (conn.json) {
        output.raw(const <String, Object?>{});
      } else {
        output.line('Removed project $id');
      }
      return Exit.ok;
    });
  }
}
