import 'package:speeddial_protocol/speeddial_protocol.dart';

/// The tool call behind one of a subagent's actions, so it reads like a tool
/// row: Ante reports each as `Name(key="value", …)`, which arrives as an
/// update titled with the tool's name and its arguments as the one detail.
/// Null for anything else, such as the subagent's own words.
ToolCall? subagentActionOf(AgentActivity update) {
  if (update.details.length != 1 || !_toolName.hasMatch(update.title)) {
    return null;
  }
  final Map<String, Object?>? input = parseToolArguments(update.details.single);
  if (input == null) return null;
  return ToolCall(
    id: update.id,
    title: update.title,
    kind: toolKindOf(update.title),
    status: update.status == AgentActivityStatus.failed
        ? ToolCallStatus.failed
        : ToolCallStatus.completed,
    content: const <ToolCallContent>[],
    locations: const <String>[],
    rawInput: input,
  );
}

final RegExp _toolName = RegExp(r'^[A-Za-z][A-Za-z0-9_]*$');

/// Reads `path="lib", -n=true, limit=20` (quoted strings escaped as in
/// JSON, long ones cut short with "…") back into the arguments it lists;
/// null when [text] does not read that way.
Map<String, Object?>? parseToolArguments(String text) {
  final Map<String, Object?> arguments = <String, Object?>{};
  int i = 0;
  while (i < text.length) {
    final Match? key = _argumentKey.matchAsPrefix(text, i);
    if (key == null) return null;
    i = key.end;
    if (i < text.length && text[i] == '"') {
      final StringBuffer value = StringBuffer();
      for (i++; i < text.length && text[i] != '"'; i++) {
        if (text[i] == r'\' && i + 1 < text.length) {
          i++;
          value.write(switch (text[i]) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            final String escaped => escaped,
          });
        } else {
          value.write(text[i]);
        }
      }
      // Unterminated: not an argument list after all.
      if (i >= text.length) return null;
      i++;
      arguments[key[1]!] = value.toString();
    } else {
      // A bare value, or a list or map kept as written, up to the next
      // argument.
      final int start = i;
      int depth = 0;
      bool quoted = false;
      for (; i < text.length; i++) {
        final String char = text[i];
        if (quoted) {
          if (char == r'\') {
            i++;
          } else if (char == '"') {
            quoted = false;
          }
        } else if (char == '"') {
          quoted = true;
        } else if (char == '[' || char == '{') {
          depth++;
        } else if (char == ']' || char == '}') {
          depth--;
        } else if (depth == 0 && text.startsWith(', ', i)) {
          break;
        }
      }
      final String raw = text.substring(start, i).trim();
      arguments[key[1]!] =
          num.tryParse(raw) ??
          switch (raw) {
            'true' => true,
            'false' => false,
            'null' => null,
            _ => raw,
          };
    }
    if (i < text.length) {
      if (!text.startsWith(', ', i)) return null;
      i += 2;
    }
  }
  return arguments.isEmpty ? null : arguments;
}

final RegExp _argumentKey = RegExp(r'(-{0,2}[A-Za-z_][A-Za-z0-9_-]*)=');

/// The [ToolCall.kind] for a tool [name], as the daemon gives Ante's own
/// tool calls.
String toolKindOf(String name) {
  final String lower = name.toLowerCase();
  if (lower.contains('read') ||
      (lower.contains('view') && lower.contains('image'))) {
    return 'read';
  }
  if (lower.contains('write') ||
      lower.contains('edit') ||
      lower.contains('patch')) {
    return 'edit';
  }
  if (lower.contains('delete') || lower.contains('remove')) return 'delete';
  if (lower.contains('move') || lower.contains('rename')) return 'move';
  if (lower.contains('grep') ||
      lower.contains('glob') ||
      lower.contains('search')) {
    return 'search';
  }
  if (lower.contains('bash') ||
      lower.contains('shell') ||
      lower.contains('terminal') ||
      lower.contains('exec')) {
    return 'execute';
  }
  if (lower.contains('fetch') || lower.contains('web')) return 'fetch';
  if (lower.contains('think')) return 'think';
  return 'other';
}

/// [text] without terminal styling, whether as escape sequences or as
/// quoted from a log (`^[[1m`).
String withoutTerminalCodes(String text) => text.replaceAll(_terminalCode, '');

final RegExp _terminalCode = RegExp(r'(?:\x1b|\^\[)\[[0-9;?]*[A-Za-z]');
