/// Mapping between ACP wire types and protocol `SessionEvent`s.
///
/// ACP statuses that have no protocol spelling are folded onto the closest
/// protocol value: `in_progress` → `running`, `cancelled` → `failed`
/// (tool calls) / `completed` (plan entries). Parsing is defensive: unknown
/// values degrade to safe defaults instead of throwing, matching the ACP
/// client's philosophy.
library;

import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../acp/acp_types.dart';

/// Converts an inline ACP image block into attachment-backed protocol content.
typedef AcpToolImageMapper = ToolCallImage? Function(
  Map<String, Object?> imageBlock,
);

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
  List<AcpToolCallContent> contents, {
  AcpToolImageMapper? mapImage,
}) {
  final out = <ToolCallContent>[];
  for (final content in contents) {
    switch (content) {
      case AcpContentBlockContent(content: final block):
        if (block['type'] == 'text') {
          final text = block['text'];
          if (text is String) out.add(ToolCallText(text: text));
        } else if (block['type'] == 'image') {
          final ToolCallImage? image = mapImage?.call(block);
          if (image != null) out.add(image);
        }
      case AcpDiffContent(:final path, :final oldText, :final newText):
        out.add(ToolCallDiff(path: path, oldText: oldText, newText: newText));
      case AcpPatchContent(:final path, :final diff):
        out.add(ToolCallPatch(path: path, diff: diff));
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
ToolCall toolCallFromAcp(
  AcpToolCallData data, {
  String? cwd,
  AcpToolImageMapper? mapImage,
}) => ToolCall(
  id: data.id,
  title: data.title,
  kind: data.kind,
  status: toolCallStatusFromAcp(data.status),
  content: toolCallContentFromAcp(data.content, mapImage: mapImage),
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
  AcpToolImageMapper? mapImage,
}) {
  final fields = update.fields;
  final rawTitle = _field<String>(fields, 'title');
  final rawKind = _field<String>(fields, 'kind');
  final rawStatus = _field<String>(fields, 'status');
  return ToolCall(
    id: update.toolCallId,
    title: rawTitle ?? prior.title,
    kind: rawKind ?? prior.kind,
    status: rawStatus != null ? toolCallStatusFromAcp(rawStatus) : prior.status,
    content: fields['content'] is List
        ? toolCallContentFromAcp(
            AcpToolCallContent.listFrom(fields['content']),
            mapImage: mapImage,
          )
        : prior.content,
    locations: fields['locations'] is List
        ? _locationPaths(fields['locations'], cwd: cwd)
        : prior.locations,
    rawInput: fields.containsKey('rawInput')
        ? fields['rawInput']
        : prior.rawInput,
    rawOutput: fields.containsKey('rawOutput')
        ? fields['rawOutput']
        : prior.rawOutput,
  );
}

/// Bounds an initial tool-call snapshot before it is persisted/broadcast.
///
/// Unlike later progress updates, an initial snapshot is emitted only once,
/// so its useful input/content can be retained. Text and structured payloads
/// are still bounded so one provider event cannot exceed history limits.
ToolCall boundInitialToolCallForEmit(ToolCall toolCall) =>
    _boundTerminalToolCall(toolCall);

/// Copy of a merged tool-call update safe for persistence/broadcast.
///
/// Agents may re-send their entire accumulated output with every progress
/// tick. Active updates therefore carry metadata only; the in-memory merged
/// state remains complete and supplies a bounded content preview on the
/// terminal update. This prevents quadratic event-log growth while retaining
/// tool lifecycle and final output.
ToolCall trimToolCallUpdateForEmit(ToolCall merged) {
  final bool terminal =
      merged.status == ToolCallStatus.completed ||
      merged.status == ToolCallStatus.failed;
  if (terminal) return _boundTerminalToolCall(merged);
  return ToolCall(
    id: merged.id,
    title: _boundedText(merged.title, _maxToolTitleCharacters),
    kind: _boundedText(merged.kind, _maxToolKindCharacters),
    status: merged.status,
    content: const <ToolCallContent>[],
    locations: _boundedLocations(merged.locations),
  );
}

const int _maxToolTitleCharacters = 1024;
const int _maxToolKindCharacters = 64;
const int _maxToolLocationCharacters = 512;
const int _maxToolLocations = 20;
const int _maxToolContentCharacters = 24000;
const int _maxToolContentFieldCharacters = 12000;
const int _maxRawJsonCharacters = 24000;

ToolCall _boundTerminalToolCall(ToolCall toolCall) => ToolCall(
  id: toolCall.id,
  title: _boundedText(toolCall.title, _maxToolTitleCharacters),
  kind: _boundedText(toolCall.kind, _maxToolKindCharacters),
  status: toolCall.status,
  content: _boundedToolContent(toolCall.content),
  locations: _boundedLocations(toolCall.locations),
  rawInput: _boundedRawValue(toolCall.rawInput),
  rawOutput: _boundedRawValue(toolCall.rawOutput),
);

List<String> _boundedLocations(List<String> locations) => <String>[
  for (final String location in locations.take(_maxToolLocations))
    _boundedText(location, _maxToolLocationCharacters),
];

List<ToolCallContent> _boundedToolContent(List<ToolCallContent> contents) {
  int remaining = _maxToolContentCharacters;
  int omittedBlocks = 0;
  final List<ToolCallContent> bounded = <ToolCallContent>[];

  String takeText(String value, {int? limit}) {
    final int fieldLimit = limit ?? _maxToolContentFieldCharacters;
    final int allowed = remaining < fieldLimit ? remaining : fieldLimit;
    if (allowed <= 0) return '';
    final String result = _boundedText(value, allowed);
    remaining -= result.length;
    return result;
  }

  for (final ToolCallContent content in contents) {
    if (content is! ToolCallImage && remaining <= 0) {
      omittedBlocks++;
      continue;
    }
    switch (content) {
      case ToolCallText(:final text):
        bounded.add(ToolCallText(text: takeText(text)));
      case ToolCallImage():
        bounded.add(content);
      case ToolCallDiff(:final path, :final oldText, :final newText):
        final int oldLimit = oldText == null
            ? 0
            : remaining ~/ 2 < _maxToolContentFieldCharacters
            ? remaining ~/ 2
            : _maxToolContentFieldCharacters;
        bounded.add(
          ToolCallDiff(
            path: _boundedText(path, _maxToolLocationCharacters),
            oldText: oldText == null
                ? null
                : takeText(oldText, limit: oldLimit),
            newText: takeText(newText),
          ),
        );
      case ToolCallPatch(:final path, :final diff):
        bounded.add(
          ToolCallPatch(
            path: _boundedText(path, _maxToolLocationCharacters),
            diff: takeText(diff),
          ),
        );
      case ToolCallTerminal(:final terminalId, :final output):
        bounded.add(
          ToolCallTerminal(
            terminalId: _boundedText(terminalId, _maxToolLocationCharacters),
            output: takeText(output),
          ),
        );
    }
  }
  if (omittedBlocks > 0) {
    bounded.add(
      ToolCallText(text: '… $omittedBlocks additional content blocks omitted'),
    );
  }
  return bounded;
}

Object? _boundedRawValue(Object? value) {
  if (value == null) return null;
  final String encoded = jsonEncode(value);
  if (encoded.length <= _maxRawJsonCharacters) return value;
  return '<structured payload omitted: ${encoded.length} JSON characters>';
}

String _boundedText(String value, int limit) {
  if (value.length <= limit) return value;
  if (limit < 32) return value.substring(0, limit);
  final int omitted = value.length - limit;
  final String marker = '\n… $omitted characters omitted …\n';
  final int retained = limit - marker.length;
  final int head = retained ~/ 2;
  final int tail = retained - head;
  return '${value.substring(0, head)}$marker'
      '${value.substring(value.length - tail)}';
}

/// Builds a protocol [ToolCall] from an update's fields when no prior state
/// exists (defensive: updates should follow a `tool_call`).
ToolCall toolCallFromAcpUpdate(
  String toolCallId,
  Map<String, Object?> fields, {
  String? cwd,
  AcpToolImageMapper? mapImage,
}) {
  return ToolCall(
    id: toolCallId,
    title: _field<String>(fields, 'title') ?? '',
    kind: _field<String>(fields, 'kind') ?? 'other',
    status: toolCallStatusFromAcp(_field<String>(fields, 'status')),
    content: fields['content'] is List
        ? toolCallContentFromAcp(
            AcpToolCallContent.listFrom(fields['content']),
            mapImage: mapImage,
          )
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
    final priority =
        _tryParse(raw.priority, PlanPriority.parse) ?? PlanPriority.medium;
    entries.add(
      PlanEntry(
        content: raw.content,
        priority: priority,
        status: _planEntryStatus(raw.status),
      ),
    );
  }
  return PlanEvent(entries: entries);
}

/// Maps a normalized provider usage update to the public event.
///
/// ACP reports only combined context occupancy; richer transports may also
/// report input/output and cache buckets.
UsageEvent usageEventFromAcp(AcpUsageUpdate update) {
  final AcpCost? cost = update.cost;
  final bool hasSplit =
      update.inputTokens != null || update.outputTokens != null;
  final int input = update.inputTokens ?? 0;
  final int output = update.outputTokens ?? (hasSplit ? 0 : update.used);
  return UsageEvent(
    usage: UsageInfo(
      inputTokens: input,
      outputTokens: output,
      totalTokens: input + output,
      cost: cost == null ? null : _costToString(cost.amount),
      cacheReadTokens: update.cacheReadTokens,
      cacheCreationTokens: update.cacheCreationTokens,
      contextUsedTokens: update.used == 0 ? null : update.used,
      contextLimitTokens: update.size == 0 ? null : update.size,
    ),
  );
}

/// Maps ACP permission options to protocol options.
List<PermissionOption> permissionOptionsFromAcp(
  List<PermissionOptionData> options,
) {
  return options
      .map(
        (o) => PermissionOption(
          optionId: o.optionId,
          name: o.name,
          kind:
              _tryParse(o.kind, PermissionKind.parse) ??
              PermissionKind.allowOnce,
        ),
      )
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
  final trimmed = fixed
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
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
