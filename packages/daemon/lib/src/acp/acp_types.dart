/// Typed mirrors of Agent Client Protocol (ACP) v1 wire messages.
///
/// These classes decode the JSON-RPC 2.0 payloads exchanged with an agent
/// process over newline-delimited stdio. Parsing is deliberately defensive:
/// unknown discriminators or malformed fields degrade to nulls, empty
/// collections, or default values instead of throwing (with the exception of
/// `parse` methods explicitly documented to throw).
library;

/// Result of the `initialize` request.
class InitializeResult {
  const InitializeResult({
    required this.protocolVersion,
    required this.agentCapabilities,
    required this.authMethods,
  });

  factory InitializeResult.fromJson(Map<String, Object?> json) {
    return InitializeResult(
      protocolVersion: (json['protocolVersion'] as num?)?.toInt() ?? 0,
      agentCapabilities: _asMap(json['agentCapabilities']),
      authMethods: _authMethodIds(json['authMethods']),
    );
  }

  /// The negotiated protocol version.
  final int protocolVersion;

  /// Capabilities supported by the agent.
  final Map<String, Object?> agentCapabilities;

  /// IDs of the authentication methods advertised by the agent.
  final List<String> authMethods;

  static Map<String, Object?> _asMap(Object? value) {
    if (value is Map) return Map<String, Object?>.from(value);
    return const <String, Object?>{};
  }

  static List<String> _authMethodIds(Object? value) {
    if (value is! List) return const <String>[];
    final ids = <String>[];
    for (final entry in value) {
      if (entry is String) {
        ids.add(entry);
      } else if (entry is Map) {
        final id = entry['id'];
        if (id is String) ids.add(id);
      }
    }
    return ids;
  }
}

/// A user-selected option offered by the agent in a permission request.
class PermissionOptionData {
  const PermissionOptionData({
    required this.optionId,
    required this.name,
    required this.kind,
  });

  factory PermissionOptionData.fromJson(Map<String, Object?> json) {
    return PermissionOptionData(
      optionId: json['optionId'] as String? ?? '',
      name: json['name'] as String? ?? '',
      kind: json['kind'] as String? ?? '',
    );
  }

  /// Unique identifier for this permission option.
  final String optionId;

  /// Human-readable label to display to the user.
  final String name;

  /// Hint about the nature of the option
  /// (one of `allow_once`, `allow_always`, `reject_once`, `reject_always`).
  final String kind;
}

/// Result of a `session/prompt` request.
class PromptResult {
  const PromptResult({required this.stopReason});

  factory PromptResult.fromJson(Map<String, Object?> json) {
    return PromptResult(stopReason: json['stopReason'] as String? ?? '');
  }

  /// Why the agent stopped processing the turn
  /// (e.g. `end_turn`, `cancelled`, `max_tokens`, `refusal`).
  final String stopReason;
}

/// A single file location being accessed or modified by a tool.
class AcpToolCallLocation {
  const AcpToolCallLocation({required this.path, this.line});

  factory AcpToolCallLocation.fromJson(Map<String, Object?> json) {
    return AcpToolCallLocation(
      path: json['path'] as String? ?? '',
      line: (json['line'] as num?)?.toInt(),
    );
  }

  final String path;
  final int? line;
}

/// Content produced by a tool call.
sealed class AcpToolCallContent {
  const AcpToolCallContent();

  /// Parses a tool call content entry, or returns `null` for unknown kinds.
  static AcpToolCallContent? parse(Map<String, Object?> json) {
    switch (json['type']) {
      case 'content':
        return AcpContentBlockContent.fromJson(json);
      case 'diff':
        return AcpDiffContent.fromJson(json);
      case 'terminal':
        return AcpTerminalContent.fromJson(json);
      default:
        return null;
    }
  }

  static List<AcpToolCallContent> listFrom(Object? value) {
    if (value is! List) return const <AcpToolCallContent>[];
    final out = <AcpToolCallContent>[];
    for (final entry in value) {
      if (entry is Map) {
        final parsed = parse(Map<String, Object?>.from(entry));
        if (parsed != null) out.add(parsed);
      }
    }
    return out;
  }
}

/// A standard content block produced by a tool call.
final class AcpContentBlockContent extends AcpToolCallContent {
  const AcpContentBlockContent({required this.content});

  factory AcpContentBlockContent.fromJson(Map<String, Object?> json) {
    final raw = json['content'];
    return AcpContentBlockContent(
      content: raw is Map ? Map<String, Object?>.from(raw) : const <String, Object?>{},
    );
  }

  final Map<String, Object?> content;
}

/// A file modification shown as a diff.
final class AcpDiffContent extends AcpToolCallContent {
  const AcpDiffContent({
    required this.path,
    this.oldText,
    required this.newText,
  });

  factory AcpDiffContent.fromJson(Map<String, Object?> json) {
    return AcpDiffContent(
      path: json['path'] as String? ?? '',
      oldText: json['oldText'] as String?,
      newText: json['newText'] as String? ?? '',
    );
  }

  final String path;
  final String? oldText;
  final String newText;
}

/// A terminal embedded in the content stream.
final class AcpTerminalContent extends AcpToolCallContent {
  const AcpTerminalContent({required this.terminalId, this.output});

  factory AcpTerminalContent.fromJson(Map<String, Object?> json) {
    return AcpTerminalContent(
      terminalId: json['terminalId'] as String? ?? '',
      output: json['output'] as String?,
    );
  }

  final String terminalId;
  final String? output;
}

/// Data about a tool call as reported by `tool_call` session updates.
class AcpToolCallData {
  const AcpToolCallData({
    required this.id,
    required this.title,
    required this.kind,
    required this.status,
    required this.content,
    required this.locations,
    required this.rawInput,
    required this.rawOutput,
  });

  /// Parses a tool call from the fields carried by a `tool_call` update
  /// (where they live at the top level of the update object).
  factory AcpToolCallData.fromJson(Map<String, Object?> json) {
    return AcpToolCallData(
      id: json['toolCallId'] as String? ?? '',
      title: json['title'] as String? ?? '',
      kind: json['kind'] as String? ?? '',
      status: json['status'] as String? ?? '',
      content: AcpToolCallContent.listFrom(json['content']),
      locations: _locations(json['locations']),
      rawInput: _asMap(json['rawInput']),
      rawOutput: _asMap(json['rawOutput']),
    );
  }

  final String id;
  final String title;
  final String kind;
  final String status;
  final List<AcpToolCallContent> content;
  final List<AcpToolCallLocation> locations;
  final Map<String, Object?> rawInput;
  final Map<String, Object?> rawOutput;

  static Map<String, Object?> _asMap(Object? value) {
    if (value is Map) return Map<String, Object?>.from(value);
    return const <String, Object?>{};
  }

  static List<AcpToolCallLocation> _locations(Object? value) {
    if (value is! List) return const <AcpToolCallLocation>[];
    final out = <AcpToolCallLocation>[];
    for (final entry in value) {
      if (entry is Map) {
        out.add(AcpToolCallLocation.fromJson(Map<String, Object?>.from(entry)));
      }
    }
    return out;
  }
}

/// A single entry in the agent's execution plan.
class AcpPlanEntry {
  const AcpPlanEntry({
    required this.content,
    required this.priority,
    required this.status,
  });

  factory AcpPlanEntry.fromJson(Map<String, Object?> json) {
    return AcpPlanEntry(
      content: json['content'] as String? ?? '',
      priority: json['priority'] as String? ?? '',
      status: json['status'] as String? ?? '',
    );
  }

  final String content;

  /// One of `high`, `medium`, `low`.
  final String priority;

  /// One of `pending`, `in_progress`, `completed`, `cancelled`.
  final String status;

  static List<AcpPlanEntry> listFrom(Object? value) {
    if (value is! List) return const <AcpPlanEntry>[];
    return value
        .whereType<Map>()
        .map((e) => AcpPlanEntry.fromJson(Map<String, Object?>.from(e)))
        .toList();
  }
}

/// A command the agent can execute.
class AcpAvailableCommand {
  const AcpAvailableCommand({required this.name, this.description, this.input});

  factory AcpAvailableCommand.fromJson(Map<String, Object?> json) {
    final rawInput = json['input'];
    return AcpAvailableCommand(
      name: json['name'] as String? ?? '',
      description: json['description'] as String?,
      input: rawInput is Map ? Map<String, Object?>.from(rawInput) : null,
    );
  }

  final String name;
  final String? description;
  final Map<String, Object?>? input;
}

/// Session cost information.
class AcpCost {
  const AcpCost({required this.amount, required this.currency});

  factory AcpCost.fromJson(Map<String, Object?> json) {
    return AcpCost(
      amount: (json['amount'] as num?)?.toDouble() ?? 0,
      currency: json['currency'] as String? ?? '',
    );
  }

  final double amount;
  final String currency;
}

/// An update sent by the agent during session processing.
///
/// Each concrete subclass mirrors one variant of the ACP `SessionUpdate`
/// union. Unknown variants are dropped by [parse] (a notification is never a
/// reason to crash the read loop).
sealed class AcpSessionUpdate {
  const AcpSessionUpdate();

  /// Parses an update object, returning `null` for unknown variants.
  static AcpSessionUpdate? parse(Map<String, Object?> json) {
    switch (json['sessionUpdate']) {
      case 'user_message_chunk':
        return AcpUserMessageChunk.fromJson(json);
      case 'agent_message_chunk':
        return AcpAgentMessageChunk.fromJson(json);
      case 'agent_thought_chunk':
        return AcpAgentThoughtChunk.fromJson(json);
      case 'tool_call':
        return AcpToolCall.fromJson(json);
      case 'tool_call_update':
        return AcpToolCallUpdate.fromJson(json);
      case 'plan':
        return AcpPlan.fromJson(json);
      case 'available_commands_update':
        return AcpAvailableCommandsUpdate.fromJson(json);
      case 'current_mode_update':
        return AcpCurrentModeUpdate.fromJson(json);
      case 'usage_update':
        return AcpUsageUpdate.fromJson(json);
      default:
        return null;
    }
  }

  static String _textOf(Map<String, Object?> json) {
    final raw = json['content'];
    if (raw is! Map) return '';
    final content = Map<String, Object?>.from(raw);
    if (content['type'] != 'text') return '';
    return content['text'] as String? ?? '';
  }
}

/// A chunk of the user's message being streamed back.
final class AcpUserMessageChunk extends AcpSessionUpdate {
  const AcpUserMessageChunk({required this.text, this.messageId});

  factory AcpUserMessageChunk.fromJson(Map<String, Object?> json) {
    return AcpUserMessageChunk(
      text: AcpSessionUpdate._textOf(json),
      messageId: json['messageId'] as String?,
    );
  }

  final String text;
  final String? messageId;
}

/// A chunk of the agent's response being streamed.
final class AcpAgentMessageChunk extends AcpSessionUpdate {
  const AcpAgentMessageChunk({required this.text, this.messageId});

  factory AcpAgentMessageChunk.fromJson(Map<String, Object?> json) {
    return AcpAgentMessageChunk(
      text: AcpSessionUpdate._textOf(json),
      messageId: json['messageId'] as String?,
    );
  }

  final String text;
  final String? messageId;
}

/// A chunk of the agent's internal reasoning being streamed.
final class AcpAgentThoughtChunk extends AcpSessionUpdate {
  const AcpAgentThoughtChunk({required this.text, this.messageId});

  factory AcpAgentThoughtChunk.fromJson(Map<String, Object?> json) {
    return AcpAgentThoughtChunk(
      text: AcpSessionUpdate._textOf(json),
      messageId: json['messageId'] as String?,
    );
  }

  final String text;
  final String? messageId;
}

/// Notification that a new tool call has been initiated.
final class AcpToolCall extends AcpSessionUpdate {
  const AcpToolCall({required this.toolCall});

  factory AcpToolCall.fromJson(Map<String, Object?> json) {
    return AcpToolCall(toolCall: AcpToolCallData.fromJson(json));
  }

  final AcpToolCallData toolCall;
}

/// Update on the status or results of a tool call.
final class AcpToolCallUpdate extends AcpSessionUpdate {
  const AcpToolCallUpdate({required this.toolCallId, required this.fields});

  factory AcpToolCallUpdate.fromJson(Map<String, Object?> json) {
    return AcpToolCallUpdate(
      toolCallId: json['toolCallId'] as String? ?? '',
      fields: _fieldsOf(json),
    );
  }

  final String toolCallId;

  /// All other fields of the update (status, title, content, locations,
  /// rawInput, rawOutput, ...) without `sessionUpdate`/`toolCallId`/`_meta`.
  final Map<String, Object?> fields;

  static Map<String, Object?> _fieldsOf(Map<String, Object?> json) {
    final fields = Map<String, Object?>.from(json)
      ..remove('sessionUpdate')
      ..remove('toolCallId')
      ..remove('_meta');
    return fields;
  }
}

/// The agent's execution plan for complex tasks.
final class AcpPlan extends AcpSessionUpdate {
  const AcpPlan({required this.entries});

  factory AcpPlan.fromJson(Map<String, Object?> json) {
    return AcpPlan(entries: AcpPlanEntry.listFrom(json['entries']));
  }

  final List<AcpPlanEntry> entries;
}

/// Available commands are ready or have changed.
final class AcpAvailableCommandsUpdate extends AcpSessionUpdate {
  const AcpAvailableCommandsUpdate({required this.availableCommands});

  factory AcpAvailableCommandsUpdate.fromJson(Map<String, Object?> json) {
    final raw = json['availableCommands'];
    final commands = <AcpAvailableCommand>[];
    if (raw is List) {
      for (final entry in raw) {
        if (entry is Map) {
          commands.add(
            AcpAvailableCommand.fromJson(Map<String, Object?>.from(entry)),
          );
        }
      }
    }
    return AcpAvailableCommandsUpdate(availableCommands: commands);
  }

  final List<AcpAvailableCommand> availableCommands;
}

/// The current mode of the session has changed.
final class AcpCurrentModeUpdate extends AcpSessionUpdate {
  const AcpCurrentModeUpdate({required this.modeId});

  factory AcpCurrentModeUpdate.fromJson(Map<String, Object?> json) {
    return AcpCurrentModeUpdate(modeId: json['currentModeId'] as String? ?? '');
  }

  final String modeId;
}

/// Context window and cost update for the session.
final class AcpUsageUpdate extends AcpSessionUpdate {
  const AcpUsageUpdate({required this.size, required this.used, this.cost});

  factory AcpUsageUpdate.fromJson(Map<String, Object?> json) {
    final rawCost = json['cost'];
    return AcpUsageUpdate(
      size: (json['size'] as num?)?.toInt() ?? 0,
      used: (json['used'] as num?)?.toInt() ?? 0,
      cost: rawCost is Map ? AcpCost.fromJson(Map<String, Object?>.from(rawCost)) : null,
    );
  }

  /// Total context window size in tokens.
  final int size;

  /// Tokens currently in context.
  final int used;

  /// Cumulative session cost (optional).
  final AcpCost? cost;
}
