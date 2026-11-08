import 'dart:convert';

import 'package:speeddial_protocol/speeddial_protocol.dart';

/// Only a successful native tool receipt can move a session. Inputs and
/// arbitrary assistant text are deliberately not treated as receipts.
String? enteredWorktreePath(ToolCall call) {
  if (call.title != 'EnterWorktree' ||
      call.status != ToolCallStatus.completed) {
    return null;
  }
  String? parse(Object? value) {
    if (value is Map) {
      final Object? path = value['worktreePath'];
      if (path is String && path.isNotEmpty) return path;
      if (value['type'] == 'text') return parse(value['text']);
    }
    if (value is List) {
      for (final Object? block in value) {
        final String? path = parse(block);
        if (path != null) return path;
      }
    }
    if (value is String) {
      try {
        final Object? decoded = jsonDecode(value);
        if (decoded is Map || decoded is List) return parse(decoded);
      } on FormatException {
        // Older adapters expose the human-readable receipt instead of JSON.
      }
      return RegExp(r'^Created worktree at ["“]([^"”]+)["”] on branch ')
          .firstMatch(value.trim())
          ?.group(1);
    }
    return null;
  }

  return parse(call.rawOutput) ??
      parse(<String>[
        for (final ToolCallContent content in call.content)
          if (content is ToolCallText) content.text,
      ]);
}
