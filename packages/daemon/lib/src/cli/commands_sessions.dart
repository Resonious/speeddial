/// `sessions` command group: session lifecycle, history, and attach.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;
import 'package:speeddial_daemon/src/client.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import 'cli_runner.dart';
import 'output.dart';

class SessionsCommand extends Command<int> {
  SessionsCommand() {
    addSubcommand(SessionsListCommand());
    addSubcommand(SessionsCreateCommand());
    addSubcommand(SessionsSendCommand());
    addSubcommand(SessionsCancelCommand());
    addSubcommand(SessionsArchiveCommand(archived: true));
    addSubcommand(SessionsArchiveCommand(archived: false));
    addSubcommand(SessionsDeleteCommand());
    addSubcommand(SessionsHistoryCommand());
    addSubcommand(SessionsAttachCommand());
  }

  @override
  final String name = 'sessions';

  @override
  final String description = 'List, create, and manage sessions.';

  @override
  Future<int> run() =>
      throw UsageException('Missing subcommand for "sessions".', usage);
}

/// `speeddial sessions list [--project <id>] [--all]`
class SessionsListCommand extends Command<int> {
  SessionsListCommand() {
    argParser
      ..addOption('project', help: 'Only sessions of this project.')
      ..addFlag('all', negatable: false, help: 'Include archived sessions.');
  }

  @override
  final String name = 'list';

  @override
  final String description = 'List sessions.';

  @override
  bool get takesArguments => false;

  @override
  Future<int> run() async {
    final conn = resolveConnection(globalResults!);
    final output = Output(json: conn.json);
    return withDaemon(conn, (client) async {
      final sessions = await client.listSessions(
        projectId: argResults!['project'] as String?,
        includeArchived: argResults!.flag('all'),
      );
      if (conn.json) {
        output.raw(<String, Object?>{
          'sessions': [for (final session in sessions) session.toJson()],
        });
      } else {
        output.table(
          const ['ID', 'TITLE', 'STATUS', 'MODE', 'PROVIDER', 'ARCHIVED'],
          [
            for (final session in sessions)
              [
                session.id,
                session.title,
                session.status.wire,
                session.mode.wire,
                session.providerId,
                session.archived ? 'yes' : 'no',
              ],
          ],
        );
      }
      return Exit.ok;
    });
  }
}

/// `speeddial sessions create --project <id> --provider <id>` plus optional
/// `[--model m] [--mode plan] [--title t] [--base b] [--yolo]`
class SessionsCreateCommand extends Command<int> {
  SessionsCreateCommand() {
    argParser
      ..addOption('project', help: 'Project id (required).')
      ..addOption('provider', help: 'Provider id (required).')
      ..addOption('model', help: 'Model id.')
      ..addOption(
        'mode',
        allowed: const ['build', 'plan'],
        help: 'Session mode (default: build).',
      )
      ..addOption('title', help: 'Session title.')
      ..addOption(
        'base',
        help:
            'Base branch for a new session worktree: fetches '
            'origin/<base> and runs the agent in a worktree branched off '
            'the remote tip.',
      )
      ..addFlag(
        'yolo',
        help: 'Auto-approve every permission request from the agent.',
      );
  }

  @override
  final String name = 'create';

  @override
  final String description = 'Create a session (spawns the agent).';

  @override
  bool get takesArguments => false;

  @override
  Future<int> run() async {
    final projectId = argResults!['project'] as String?;
    final providerId = argResults!['provider'] as String?;
    if (projectId == null || providerId == null) {
      throw UsageException('--project and --provider are required.', usage);
    }
    final modeRaw = argResults!['mode'] as String?;
    final conn = resolveConnection(globalResults!);
    final output = Output(json: conn.json);
    return withDaemon(conn, (client) async {
      final session = await client.createSession(
        projectId: projectId,
        providerId: providerId,
        model: argResults!['model'] as String?,
        mode: modeRaw == null ? null : SessionMode.parse(modeRaw),
        title: argResults!['title'] as String?,
        baseBranch: argResults!['base'] as String?,
        yolo: argResults!['yolo'] as bool,
      );
      if (conn.json) {
        output.raw(<String, Object?>{'session': session.toJson()});
      } else {
        output.record(_sessionRecord(session));
      }
      return Exit.ok;
    });
  }
}

/// `speeddial sessions send <id> <text...> [--attach <file> ...]` — starts a
/// turn, optionally attaching files.
class SessionsSendCommand extends Command<int> {
  SessionsSendCommand() {
    argParser.addMultiOption(
      'attach',
      abbr: 'a',
      help: 'File to attach to the message (repeatable).',
    );
  }

  @override
  final String name = 'send';

  @override
  final String description = 'Send a message to a session (starts a turn).';

  @override
  Future<int> run() async {
    if (argResults!.rest.isEmpty) {
      throw UsageException('Missing <id> and <text>.', usage);
    }
    final id = argResults!.rest.first;
    final text = argResults!.rest.skip(1).join(' ');
    if (id.isEmpty || text.isEmpty) {
      throw UsageException('Usage: speeddial sessions send <id> <text>', usage);
    }
    final attachPaths =
        argResults!['attach'] as List<String>? ?? const <String>[];
    final attachments = <OutgoingAttachment>[];
    for (final path in attachPaths) {
      final bytes = await _readAttachment(path);
      if (bytes == null) return Exit.usage; // Error already printed.
      final name = p.basename(path);
      attachments.add(
        OutgoingAttachment(
          name: name,
          mimeType: mimeTypeForFileName(name),
          data: base64Encode(bytes),
        ),
      );
    }
    final conn = resolveConnection(globalResults!);
    final output = Output(json: conn.json);
    return withDaemon(conn, (client) async {
      await client.sendMessage(id, text, attachments: attachments);
      if (conn.json) {
        output.raw(const <String, Object?>{});
      } else {
        output.line('Message sent to session $id');
      }
      return Exit.ok;
    });
  }
}

/// `speeddial sessions cancel <id>`
class SessionsCancelCommand extends Command<int> {
  @override
  final String name = 'cancel';

  @override
  final String description = 'Cancel the running turn of a session.';

  @override
  Future<int> run() async {
    final id = _requireSessionId(this);
    final conn = resolveConnection(globalResults!);
    final output = Output(json: conn.json);
    return withDaemon(conn, (client) async {
      await client.cancel(id);
      if (conn.json) {
        output.raw(const <String, Object?>{});
      } else {
        output.line('Cancelled turn of session $id');
      }
      return Exit.ok;
    });
  }
}

/// `speeddial sessions archive <id>` / `unarchive <id>`
class SessionsArchiveCommand extends Command<int> {
  SessionsArchiveCommand({required this.archived});

  final bool archived;

  @override
  String get name => archived ? 'archive' : 'unarchive';

  @override
  String get description =>
      archived ? 'Archive a session.' : 'Unarchive a session.';

  @override
  Future<int> run() async {
    final id = _requireSessionId(this);
    final conn = resolveConnection(globalResults!);
    final output = Output(json: conn.json);
    return withDaemon(conn, (client) async {
      final session = await client.archiveSession(id, archived);
      if (conn.json) {
        output.raw(<String, Object?>{'session': session.toJson()});
      } else {
        output.line('Session $id ${archived ? 'archived' : 'unarchived'}');
      }
      return Exit.ok;
    });
  }
}

/// `speeddial sessions delete <id>`
class SessionsDeleteCommand extends Command<int> {
  @override
  final String name = 'delete';

  @override
  final String description = 'Delete a session (kills the agent).';

  @override
  Future<int> run() async {
    final id = _requireSessionId(this);
    final conn = resolveConnection(globalResults!);
    final output = Output(json: conn.json);
    return withDaemon(conn, (client) async {
      await client.deleteSession(id);
      if (conn.json) {
        output.raw(const <String, Object?>{});
      } else {
        output.line('Deleted session $id');
      }
      return Exit.ok;
    });
  }
}

/// `speeddial sessions history <id> [--limit n]`
class SessionsHistoryCommand extends Command<int> {
  SessionsHistoryCommand() {
    argParser.addOption(
      'limit',
      help: 'Maximum number of events (default: 200, max: 1000).',
    );
  }

  @override
  final String name = 'history';

  @override
  final String description = 'Print the persisted event stream of a session.';

  @override
  Future<int> run() async {
    final id = _requireSessionId(this);
    final limitRaw = argResults!['limit'] as String?;
    final int? limit;
    if (limitRaw != null) {
      limit = int.tryParse(limitRaw);
      if (limit == null || limit < 1) {
        throw UsageException('Invalid --limit value: "$limitRaw".', usage);
      }
    } else {
      limit = null;
    }
    final conn = resolveConnection(globalResults!);
    final output = Output(json: conn.json);
    return withDaemon(conn, (client) async {
      final page = await client.history(id, limit: limit);
      if (conn.json) {
        output.raw(<String, Object?>{
          'events': [for (final event in page.events) event.toJson()],
          'hasMore': page.hasMore,
        });
      } else if (page.events.isEmpty) {
        output.line('No events for session $id');
      } else {
        for (final event in page.events) {
          final seq = (event.seq ?? 0).toString().padLeft(4, ' ');
          output.line('#$seq  ${summarizeSessionEvent(event)}');
        }
        if (page.hasMore) {
          output.line('(older events available; use --limit / beforeSeq)');
        }
      }
      return Exit.ok;
    });
  }
}

/// `speeddial sessions attach <id>` — streams `session.event` notifications as
/// compact one-line summaries until Ctrl-C.
class SessionsAttachCommand extends Command<int> {
  @override
  final String name = 'attach';

  @override
  final String description =
      'Stream session events as one-line summaries until Ctrl-C.';

  @override
  Future<int> run() async {
    final id = _requireSessionId(this);
    final conn = resolveConnection(globalResults!);
    final output = Output(json: conn.json, onFlush: () => stdout.flush());
    final done = Completer<int>();
    StreamSubscription<({String sessionId, int seq, SessionEvent event})>? sub;
    final client = await DaemonClient.connect(conn.url, token: conn.token);
    sub = client.sessionEvents.listen(
      (tuple) {
        if (tuple.sessionId != id) return;
        if (conn.json) {
          output.raw(<String, Object?>{
            'sessionId': tuple.sessionId,
            'seq': tuple.seq,
            'event': tuple.event.toJson(),
          });
        } else {
          final seq = tuple.seq.toString().padLeft(4, ' ');
          output.line('#$seq  ${summarizeSessionEvent(tuple.event)}');
        }
        output.flush();
      },
      // The daemon died under us: the socket closes and the notifications
      // stream ends (or errors). Complete the wait with the standard
      // daemon-unreachable exit path instead of hanging forever.
      onDone: () {
        if (done.isCompleted) return;
        stderr.writeln('speeddial: cannot reach daemon: connection closed');
        done.complete(Exit.unreachable);
      },
      onError: (Object error) {
        if (done.isCompleted) return;
        stderr.writeln('speeddial: cannot reach daemon: $error');
        done.complete(Exit.unreachable);
      },
    );
    ProcessSignal.sigint.watch().listen((_) async {
      await sub?.cancel();
      await client.close();
      if (!done.isCompleted) done.complete(Exit.ok);
    });
    return done.future;
  }
}

/// One-line human summary of a session event (attach/history rendering).
String summarizeSessionEvent(SessionEvent event) {
  final summary = switch (event) {
    UserMessageEvent(:final text) => 'user: ${_oneLine(text)}',
    ImageEvent(:final attachment) => '[image] ${attachment.name}',
    AgentMessageChunkEvent(:final text) => _oneLine(text),
    AgentThoughtChunkEvent(:final text) => '[thought] ${_oneLine(text)}',
    ToolCallEvent(:final toolCall) =>
      '[tool] ${toolCall.title} (${toolCall.status.wire})',
    PlanEvent(:final entries) =>
      '[plan] ${entries.length} '
          '${entries.length == 1 ? 'entry' : 'entries'}',
    PermissionRequestEvent(:final request) => '[permission] ${request.title}',
    PermissionResolvedEvent(:final requestId, :final optionId) =>
      '[resolved] $requestId -> $optionId',
    UsageEvent(:final usage) =>
      '[usage] in=${usage.inputTokens} '
          'out=${usage.outputTokens} total=${usage.totalTokens}'
          '${usage.cost == null ? '' : ' cost=\$${usage.cost}'}',
    TurnCompleteEvent(:final stopReason) => '[done] $stopReason',
    SessionErrorEvent(:final message) => '[error] ${_oneLine(message)}',
  };
  return summary;
}

Map<String, Object?> _sessionRecord(Session session) => <String, Object?>{
  'id': session.id,
  'projectId': session.projectId,
  'providerId': session.providerId,
  'title': session.title,
  'status': session.status.wire,
  'mode': session.mode.wire,
  'model': session.model ?? '',
  'cwd': session.cwd,
  'archived': session.archived ? 'yes' : 'no',
};

/// Reads an attached file's bytes, printing the error to stderr (matching
/// the CLI's error style) and returning null when the file is missing or
/// unreadable; the caller then exits non-zero.
Future<List<int>?> _readAttachment(String path) async {
  final file = File(path);
  try {
    return await file.readAsBytes();
  } on FileSystemException catch (e) {
    stderr.writeln('speeddial: cannot read attachment "$path": ${e.message}');
    return null;
  }
}

String _requireSessionId(Command<int> command) {
  if (command.argResults!.rest.isEmpty) {
    throw UsageException('Missing <id> argument.', command.usage);
  }
  return command.argResults!.rest.first;
}

const int _maxSummaryLength = 200;

String _oneLine(String text) {
  final collapsed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return collapsed.length <= _maxSummaryLength
      ? collapsed
      : '${collapsed.substring(0, _maxSummaryLength)}…';
}
