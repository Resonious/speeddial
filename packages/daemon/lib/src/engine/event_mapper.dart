/// Mapping between ACP wire types and protocol `SessionEvent`s.
///
/// ACP statuses that have no protocol spelling are folded onto the closest
/// protocol value: `in_progress` → `running`, `cancelled` → `failed`
/// (tool calls) / `completed` (plan entries). Parsing is defensive: unknown
/// values degrade to safe defaults instead of throwing, matching the ACP
/// client's philosophy.
library;

import 'package:path/path.dart' as p;
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../acp/acp_types.dart';

/// Maps an ACP tool call status string to the protocol enum.
ToolCallStatus toolCallStatusFromAcp(String? status) => switch (status) {
      'pending' => ToolCallStatus.pending,
      'in_progress' => ToolCallStatus.running,
      'completed' => ToolCallStatus.completed,
      'cancelled' => ToolCallStatus.failed,
      _ => ToolCallStatus.pending,
    };

/// Maps ACP tool call content to protocol content blocks. Content kinds the
/// protocol cannot represent (input/output/... blocks) are dropped; their
/// structured payload travels in `rawInput`/`rawOutput`.
List<ToolCallContent> toolCallContentFromAcp(
  List<AcpToolCallContent> contents,
) {
  final out = <ToolCallContent>[];
  for (final content in contents) {
    switch (content) {
      case AcpContentBlockContent(content: final block):
        if (block['type'] == 'text') {
          final text = block['text'];
          if (text is String) out.add(ToolCallText(text: text));
        }
      case AcpDiffContent(:final path, :final oldText, :final newText):
        out.add(ToolCallDiff(path: path, oldText: oldText, newText: newText));
      case AcpTerminalContent(:final terminalId, :final output):
        out.add(ToolCallTerminal(terminalId: terminalId, output: output ?? ''));
    }
  }
  return out;
}

/// Converts ACP locations (path + optional line) to protocol file paths,
/// relativized against [cwd] when possible (protocol paths are relative to
/// the session cwd).
List<String> locationsFromAcpLocationList(
  List<AcpToolCallLocation> locations, {
  String? cwd,
}) {
  final out = <String>[];
  for (final location in locations) {
    if (location.path.isNotEmpty) out.add(_relativize(location.path, cwd: cwd));
  }
  return out;
}

/// Builds a protocol [ToolCall] from a `tool_call` update.
ToolCall toolCallFromAcp(AcpToolCallData data, {String? cwd}) => ToolCall(
      id: data.id,
      title: data.title,
      kind: data.kind,
      status: toolCallStatusFromAcp(data.status),
      content: toolCallContentFromAcp(data.content),
      locations: locationsFromAcpLocationList(data.locations, cwd: cwd),
      rawInput: data.rawInput,
      rawOutput: data.rawOutput,
    );

/// Merges a `tool_call_update` onto the prior tool call state for the same
/// `toolCallId`; fields absent from the update keep their previous values.
ToolCall mergeToolCallUpdate(
  ToolCall prior,
  AcpToolCallUpdate update, {
  String? cwd,
}) {
  final fields = update.fields;
  final rawTitle = _field<String>(fields, 'title');
  final rawKind = _field<String>(fields, 'kind');
  final rawStatus = _field<String>(fields, 'status');
  return ToolCall(
    id: update.toolCallId,
    title: rawTitle ?? prior.title,
    kind: rawKind ?? prior.kind,
    status: rawStatus != null
        ? toolCallStatusFromAcp(rawStatus)
        : prior.status,
    content: fields['content'] is List
        ? toolCallContentFromAcp(AcpToolCallContent.listFrom(fields['content']))
        : prior.content,
    locations: fields['locations'] is List
        ? _locationPaths(fields['locations'], cwd: cwd)
        : prior.locations,
    rawInput: fields.containsKey('rawInput') ? fields['rawInput'] : prior.rawInput,
    rawOutput: fields.containsKey('rawOutput') ? fields['rawOutput'] : prior.rawOutput,
  );
}

/// Copy of a merged tool-call update for persisting/broadcasting, with
/// `rawInput`/`rawOutput` dropped unless the call reached a terminal
/// status (completed/failed).
///
/// Agents stream progress by re-sending their whole accumulated raw
/// output with every `tool_call_update`. Persisting each snapshot
/// full-size made update events dominate the database (and every history
/// page and live broadcast re-copies them), while clients fold updates by
/// `toolCall.id` and only ever render the final state. The terminal event
/// always carries the full merged state, so folding is unaffected; a call
/// that never settles loses only its intermediate raw snapshots.
/// `content` is untouched — it is the live progress display.
ToolCall trimToolCallUpdateForEmit(ToolCall merged) {
  final bool terminal = merged.status == ToolCallStatus.completed ||
      merged.status == ToolCallStatus.failed;
  if (terminal) return merged;
  if (merged.rawInput == null && merged.rawOutput == null) return merged;
  return ToolCall(
    id: merged.id,
    title: merged.title,
    kind: merged.kind,
    status: merged.status,
    content: merged.content,
    locations: merged.locations,
  );
}

/// Builds a protocol [ToolCall] from an update's fields when no prior state
/// exists (defensive: updates should follow a `tool_call`).
ToolCall toolCallFromAcpUpdate(
  String toolCallId,
  Map<String, Object?> fields, {
  String? cwd,
}) {
  return ToolCall(
    id: toolCallId,
    title: _field<String>(fields, 'title') ?? '',
    kind: _field<String>(fields, 'kind') ?? 'other',
    status: toolCallStatusFromAcp(_field<String>(fields, 'status')),
    content: fields['content'] is List
        ? toolCallContentFromAcp(AcpToolCallContent.listFrom(fields['content']))
        : const <ToolCallContent>[],
    locations: _locationPaths(fields['locations'], cwd: cwd),
    rawInput: fields['rawInput'],
    rawOutput: fields['rawOutput'],
  );
}

/// Maps an ACP `plan` update to a protocol [PlanEvent] (full replacement).
PlanEvent planEventFromAcp(AcpPlan plan) {
  final entries = <PlanEntry>[];
  for (final raw in plan.entries) {
    final priority = _tryParse(
          raw.priority,
          PlanPriority.parse,
        ) ??
        PlanPriority.medium;
    entries.add(PlanEntry(
      content: raw.content,
      priority: priority,
      status: _planEntryStatus(raw.status),
    ));
  }
  return PlanEvent(entries: entries);
}

/// Maps an ACP `usage_update` to a protocol [UsageEvent].
///
/// ACP reports combined context usage (`used` tokens in a `size` window), not
/// a prompt/completion split; the whole used count is bucketed under
/// `outputTokens` so `inputTokens + outputTokens == totalTokens`.
UsageEvent usageEventFromAcp(AcpUsageUpdate update) {
  final cost = update.cost;
  return UsageEvent(usage: UsageInfo(
    inputTokens: 0,
    outputTokens: update.used,
    totalTokens: update.used,
    cost: cost == null ? null : _costToString(cost.amount),
  ));
}

/// Maps ACP permission options to protocol options.
List<PermissionOption> permissionOptionsFromAcp(
  List<PermissionOptionData> options,
) {
  return options
      .map((o) => PermissionOption(
            optionId: o.optionId,
            name: o.name,
            kind: _tryParse(o.kind, PermissionKind.parse) ??
                PermissionKind.allowOnce,
          ))
      .toList(growable: false);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

T? _field<T>(Map<String, Object?> map, String key) =>
    map[key] is T ? map[key] as T : null;

/// Runs [parse], returning null instead of throwing on unknown values.
T? _tryParse<T>(String value, T Function(String) parse) {
  try {
    return parse(value);
  } on FormatException {
    return null;
  }
}

List<String> _locationPaths(Object? value, {String? cwd}) {
  if (value is! List) return const <String>[];
  final out = <String>[];
  for (final entry in value) {
    if (entry is Map) {
      final path = Map<String, Object?>.from(entry)['path'];
      if (path is String && path.isNotEmpty) {
        out.add(_relativize(path, cwd: cwd));
      }
    }
  }
  return out;
}

/// Converts an absolute (or cwd-relative) path into one relative to [cwd].
String _relativize(String path, {String? cwd}) {
  if (cwd == null) return path;
  final cwdNorm = p.normalize(p.absolute(cwd));
  final abs = p.isAbsolute(path)
      ? p.normalize(path)
      : p.normalize(p.join(cwdNorm, path));
  final prefix = cwdNorm.endsWith(p.separator)
      ? cwdNorm
      : '$cwdNorm${p.separator}';
  if (abs.startsWith(prefix)) return abs.substring(prefix.length);
  return path;
}

/// Renders a double as a trimmed decimal USD string ("0.012", "10").
String _costToString(double amount) {
  if (amount == 0) return '0';
  final fixed = amount.toStringAsFixed(6);
  final trimmed =
      fixed.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  return trimmed;
}

/// Plan entry status: protocol has no `cancelled`, so it folds onto
/// `completed` (terminal, will not run).
PlanEntryStatus _planEntryStatus(String status) => switch (status) {
      'in_progress' => PlanEntryStatus.inProgress,
      'completed' => PlanEntryStatus.completed,
      'cancelled' => PlanEntryStatus.completed,
      _ => PlanEntryStatus.pending,
    };
