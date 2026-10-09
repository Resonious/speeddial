import 'package:speeddial_protocol/speeddial_protocol.dart';

/// What a tool call's row shows: a readable [title] and, beneath it in
/// monospace, the command or target behind it ([detail]).
class ToolCallSummary {
  const ToolCallSummary(this.title, {this.detail, this.titleIsCommand = false});

  final String title;
  final String? detail;

  /// The title is the (cleaned) command itself: nothing better described
  /// the call, so it reads as code.
  final bool titleIsCommand;
}

/// Summarizes [toolCall] for its timeline row.
///
/// The title prefers the agent's own words: the `description` its shell
/// tool states (Claude, Ante), Codex's parsed `commandActions`, or a
/// readable form of an `mcp__server__tool` name; a call titled with just a
/// Claude Code tool's name says what its input did ("Read main.dart").
/// The command shown beneath it is cleaned by [cleanCommand]. Nothing is
/// hidden: the row's details keep the raw input.
ToolCallSummary summarizeToolCall(ToolCall toolCall, {String? cwd}) {
  final _Paths paths = _Paths(cwd);
  final Object? rawInput = toolCall.rawInput;
  final Map<Object?, Object?>? input = rawInput is Map<Object?, Object?>
      ? rawInput
      : null;
  final String description = _oneLine(_text(input?['description']));

  if (toolCall.kind == 'execute') {
    String command = _text(input?['command']);
    if (command.trim().isEmpty) command = _text(input?['cmd']);
    final String shown = cleanCommand(
      command.trim().isEmpty ? toolCall.title : command,
      cwd: cwd,
    );
    final String title = description.isNotEmpty
        ? description
        : _codexActions(input?['commandActions'], paths) ?? shown;
    return ToolCallSummary(
      title,
      detail: shown == title ? null : shown,
      titleIsCommand: shown == title,
    );
  }

  final String? mcp = _mcpTitle(toolCall.title);
  if (mcp != null) {
    return ToolCallSummary(
      description.isNotEmpty ? description : mcp,
      detail: _argumentsPreview(input),
    );
  }

  final ToolCallSummary? named = description.isEmpty
      ? _namedSummary(toolCall.title, input, paths)
      : null;
  if (named != null) return named;

  final String title = paths.shorten(_oneLine(toolCall.title));
  final String locations = toolCall.locations.map(paths.shorten).join(', ');
  return ToolCallSummary(
    description.isNotEmpty ? description : title,
    // Most titles already name their file ("Read lib/main.dart").
    detail: locations.isEmpty || title.contains(locations) ? null : locations,
  );
}

/// [command] as a person would type it: unwrapped from a login-shell launcher
/// (`/usr/bin/bash -lc '…'`), without a leading `cd <dir> &&`, environment
/// assignments, or absolute program paths, with paths under [cwd] made
/// relative and the home directory shown as `~`, on one line.
String cleanCommand(String command, {String? cwd}) {
  String text = _unwrapShell(command.trim());
  text = text.replaceFirst(_leadingCd, '');
  text = text.replaceAllMapped(_envAssignments, (Match m) => m.group(1)!);
  text = text.replaceFirstMapped(_programPath, (Match m) => m.group(1)!);
  return _oneLine(_Paths(cwd).shorten(text));
}

final RegExp _shellLauncher = RegExp(
  r'^(?:\S*/)?(?:ba|z|da|k)?sh\s+(?:-l\s+)?-l?c\s+([\s\S]+)$',
);
final RegExp _leadingCd = RegExp(
  r'''^cd\s+(?:'[^']*'|"[^"]*"|[^\s;&|]+)\s*(?:&&|;)\s*''',
);
// Assignments opening the command or any command after `&&`, `;` or `|`.
final RegExp _envAssignments = RegExp(
  r'''(^|&&\s*|;\s*|\|\s*)(?:env\s+)?(?:[A-Za-z_][A-Za-z0-9_]*=(?:'[^']*'|"(?:[^"\\]|\\.)*"|[^\s'"]*)\s+)+''',
);
final RegExp _programPath = RegExp(r'^/(?:[\w.-]+/)*([\w.+-]+)(?=\s|$)');
final RegExp _whitespace = RegExp(r'\s+');

/// Peels login-shell launchers, including nested ones
/// (`bash -lc "bash -lc '…'"`).
String _unwrapShell(String command) {
  String text = command;
  for (int depth = 0; depth < 3; depth++) {
    final String inner = _unwrapShellOnce(text).trim();
    if (inner == text) break;
    text = inner;
  }
  return text;
}

String _unwrapShellOnce(String command) {
  final RegExpMatch? match = _shellLauncher.firstMatch(command);
  if (match == null) return command;
  final String script = match.group(1)!.trim();
  if (script.length >= 2 && script.startsWith("'") && script.endsWith("'")) {
    return script
        .substring(1, script.length - 1)
        .replaceAll("'\\''", "'")
        .replaceAll("'\"'\"'", "'");
  }
  if (script.length >= 2 && script.startsWith('"') && script.endsWith('"')) {
    return script
        .substring(1, script.length - 1)
        .replaceAllMapped(RegExp(r'\\([\\"$`])'), (Match m) => m.group(1)!);
  }
  return command;
}

String _text(Object? value) => switch (value) {
  final String text => text,
  final List<Object?> parts => parts.whereType<String>().join(' '),
  _ => '',
};

String _oneLine(String text) => text.trim().replaceAll(_whitespace, ' ');

/// Readable form of `mcp__<server>__<tool>`; SpeedDial's proxy nests managed
/// servers as `mcp__speeddial__<server>__<tool>`.
String? _mcpTitle(String title) {
  if (!title.startsWith('mcp__')) return null;
  final List<String> parts = title
      .substring(5)
      .split('__')
      .where((String part) => part.isNotEmpty)
      .toList();
  if (parts.length < 2) return null;
  final String server = parts.length > 2 && parts.first == 'speeddial'
      ? parts[1]
      : parts.first;
  final String name = server == 'speeddial'
      ? 'SpeedDial'
      : server.replaceAll('_', ' ');
  return '$name · ${parts.last.replaceAll('_', ' ')}';
}

/// What a call to one of Claude Code's tools did, from its input ("Search
/// “retry” in src"), for calls titled with nothing but the tool's name (as
/// Ante's are, and its subagents' actions). A file leads by its own name;
/// where it lives goes beneath.
ToolCallSummary? _namedSummary(
  String name,
  Map<Object?, Object?>? input,
  _Paths paths,
) {
  if (input == null) return null;
  String text(String key) => _oneLine(_text(input[key]));
  // Under the working directory itself, "in ." says nothing.
  String within(String key) {
    final String where = paths.shorten(text(key));
    return where.isEmpty || where == '.' ? '' : ' in $where';
  }

  ToolCallSummary? file(String key, String Function(String name) title) {
    final String path = paths.shorten(text(key));
    final String name = path.substring(path.lastIndexOf('/') + 1);
    if (name.isEmpty) return null;
    return ToolCallSummary(title(name), detail: path == name ? null : path);
  }

  return switch (name) {
    'Read' => file(
      'file_path',
      (String name) => _reading(name, input['offset'], input['limit']),
    ),
    'NotebookRead' => file('notebook_path', (String name) => 'Read $name'),
    'Edit' || 'MultiEdit' => file('file_path', (String name) => 'Edit $name'),
    'NotebookEdit' => file('notebook_path', (String name) => 'Edit $name'),
    'Write' => file('file_path', (String name) => 'Write $name'),
    'Grep' when text('pattern').isNotEmpty => ToolCallSummary(
      'Search “${_clip(text('pattern'), 40)}”${within('path')}',
    ),
    'Glob' when text('pattern').isNotEmpty => ToolCallSummary(
      'Find ${_clip(text('pattern'), 40)}${within('path')}',
    ),
    'LS' when text('path').isNotEmpty => ToolCallSummary(
      'List ${paths.shorten(text('path'))}',
    ),
    'WebFetch' when text('url').isNotEmpty => ToolCallSummary(
      'Fetch ${text('url').replaceFirst(RegExp(r'^https?://'), '')}',
    ),
    'WebSearch' when text('query').isNotEmpty => ToolCallSummary(
      'Search the web for “${_clip(text('query'), 60)}”',
    ),
    _ => null,
  };
}

/// "Read main.dart", or the part of it that was read ("Read lines 40–79 of
/// main.dart"). Lines count from 1; a read from the top as long as the
/// tool's default (2000 lines) reads the whole file.
String _reading(String name, Object? offset, Object? limit) {
  final int start = offset is num && offset > 1 ? offset.toInt() : 1;
  if (limit is num && limit > 0 && (start > 1 || limit < 2000)) {
    return 'Read lines $start–${start + limit.toInt() - 1} of $name';
  }
  return start > 1 ? 'Read $name from line $start' : 'Read $name';
}

/// A few short scalar arguments ("operation: listUsers"), for tools whose
/// title alone says little.
String? _argumentsPreview(Map<Object?, Object?>? input) {
  if (input == null) return null;
  final List<String> parts = <String>[];
  for (final MapEntry<Object?, Object?> entry in input.entries) {
    final Object? value = entry.value;
    if (value is! String && value is! num && value is! bool) continue;
    final String text = _oneLine('$value');
    if (text.isEmpty) continue;
    parts.add('${entry.key}: ${_clip(text, 48)}');
    if (parts.length == 3) break;
  }
  return parts.isEmpty ? null : parts.join(' · ');
}

/// Codex's own parse of a command, e.g. "Read main.rs, lib.rs · Search
/// “retry” in src". Null when any part is unclassified: then the command
/// itself says more.
String? _codexActions(Object? actions, _Paths paths) {
  if (actions is! List<Object?> || actions.isEmpty) return null;
  final List<(String, String)> parts = <(String, String)>[];
  for (final Object? action in actions) {
    if (action is! Map<Object?, Object?>) return null;
    final String? path = _usefulPath(action['path']);
    final String type = _text(action['type']);
    switch (type) {
      case 'read':
        final String name = _text(action['name']);
        parts.add((
          'Read',
          name.isNotEmpty ? name : paths.shorten(path ?? 'file'),
        ));
      case 'search':
        final String query = _oneLine(_text(action['query']));
        final String where = path == null ? '' : ' in ${paths.shorten(path)}';
        parts.add((
          'Search',
          query.isEmpty ? where.trim() : '“${_clip(query, 40)}”$where',
        ));
      case 'listFiles':
        parts.add(('List files', path == null ? '' : paths.shorten(path)));
      default:
        return null;
    }
  }
  // Group runs of one verb: "Read a, b" rather than "Read a · Read b".
  final List<String> groups = <String>[];
  String? verb;
  final List<String> objects = <String>[];
  void flush() {
    final String? current = verb;
    if (current == null) return;
    final String joined = objects.where((String o) => o.isNotEmpty).join(', ');
    groups.add(joined.isEmpty ? current : '$current $joined');
    objects.clear();
  }

  for (final (String nextVerb, String object) in parts) {
    if (nextVerb != verb) {
      flush();
      verb = nextVerb;
    }
    objects.add(object);
  }
  flush();
  return groups.join(' · ');
}

String? _usefulPath(Object? path) {
  final String text = _text(path).trim();
  return text.isEmpty || text == 'None' || text == 'null' ? null : text;
}

String _clip(String text, int max) =>
    text.length <= max ? text : '${text.substring(0, max - 1)}…';

/// Shortens absolute paths: under the session's working directory they
/// become relative, under the home directory they start with `~`.
class _Paths {
  _Paths(String? cwd) : cwd = _withoutTrailingSlash(cwd), home = _homeOf(cwd);

  final String? cwd;
  final String? home;

  static String? _withoutTrailingSlash(String? path) {
    if (path == null || path.length < 2) return null;
    return path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  }

  static String? _homeOf(String? cwd) {
    if (cwd == null) return null;
    return RegExp(r'^(/home/[^/]+|/Users/[^/]+)(?=/|$)').firstMatch(cwd)?[1];
  }

  String shorten(String text) {
    String out = text;
    final String? cwd = this.cwd;
    if (cwd != null) {
      out = out.replaceAll('$cwd/', '');
      out = out.replaceAll(RegExp('${RegExp.escape(cwd)}(?![\\w./-])'), '.');
    }
    final String? home = this.home;
    if (home != null) {
      out = out.replaceAll('$home/', '~/');
      out = out.replaceAll(RegExp('${RegExp.escape(home)}(?![\\w./-])'), '~');
    }
    return out;
  }
}
