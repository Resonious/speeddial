/// Session event stream: a discriminated union on `type`, plus shared
/// optional `seq`/`timestamp` metadata added by the daemon when persisting.
///
/// Clients construct events without `seq`/`timestamp` (both null); the daemon
/// fills them in. `toJson` includes them only when non-null.
library;

import 'models.dart';

/// Amount of event detail requested from `sessions.history`.
enum SessionHistoryDetail {
  /// Returns persisted events without projection.
  full('full'),

  /// Keeps timeline semantics and sequence metadata while dropping large
  /// fields that compact clients do not render.
  summary('summary');

  const SessionHistoryDetail(this.wire);

  final String wire;

  static SessionHistoryDetail parse(String value) => switch (value) {
    'full' => full,
    'summary' => summary,
    _ => throw FormatException('Unknown session history detail: $value'),
  };
}

DateTime? _parseTimestamp(Object? value) {
  if (value == null) return null;
  return DateTime.parse(value as String).toUtc();
}

String _formatTimestamp(DateTime value) => value.toUtc().toIso8601String();

/// Base of every event on a session's event stream.
sealed class SessionEvent {
  const SessionEvent({this.seq, this.timestamp});

  /// Per-session monotonically increasing sequence number, assigned by the
  /// daemon; null on client-constructed events.
  final int? seq;

  /// When the daemon persisted/broadcast the event; null when client-made.
  final DateTime? timestamp;

  factory SessionEvent.fromJson(Map<String, Object?> json) =>
      switch (json['type']) {
        'userMessage' => UserMessageEvent.fromJson(json),
        'image' => ImageEvent.fromJson(json),
        'agentMessageChunk' => AgentMessageChunkEvent.fromJson(json),
        'agentThoughtChunk' => AgentThoughtChunkEvent.fromJson(json),
        'toolCall' => ToolCallEvent.fromJson(json),
        'plan' => PlanEvent.fromJson(json),
        'permissionRequest' => PermissionRequestEvent.fromJson(json),
        'permissionResolved' => PermissionResolvedEvent.fromJson(json),
        'usage' => UsageEvent.fromJson(json),
        'agentActivity' => AgentActivityEvent.fromJson(json),
        'turnComplete' => TurnCompleteEvent.fromJson(json),
        'sessionError' => SessionErrorEvent.fromJson(json),
        _ => throw FormatException(
          'Unknown SessionEvent type: ${json['type']}',
        ),
      };

  Map<String, Object?> toJson();
}

/// Projects a persisted event for a compact history client.
///
/// Event kinds, ordering, sequence numbers, timestamps, user/agent messages,
/// and permission data remain intact. Only verbose details that compact
/// timelines summarize are removed, so live sequence reconciliation remains
/// correct and the result still decodes as an ordinary [SessionEvent].
SessionEvent summarizeSessionEvent(SessionEvent event) => switch (event) {
  AgentThoughtChunkEvent e => AgentThoughtChunkEvent(
    text: '',
    messageId: e.messageId,
    seq: e.seq,
    timestamp: e.timestamp,
  ),
  ToolCallEvent e => ToolCallEvent(
    toolCall: ToolCall(
      id: e.toolCall.id,
      title: e.toolCall.title,
      kind: e.toolCall.kind,
      status: e.toolCall.status,
      content: const <ToolCallContent>[],
      locations: const <String>[],
    ),
    seq: e.seq,
    timestamp: e.timestamp,
  ),
  PlanEvent e => PlanEvent(
    entries: <PlanEntry>[
      for (final PlanEntry entry in e.entries)
        PlanEntry(content: '', priority: entry.priority, status: entry.status),
    ],
    seq: e.seq,
    timestamp: e.timestamp,
  ),
  AgentActivityEvent e => AgentActivityEvent(
    activity: AgentActivity(
      id: e.activity.id,
      kind: e.activity.kind,
      title: e.activity.title,
      status: e.activity.status,
    ),
    seq: e.seq,
    timestamp: e.timestamp,
  ),
  _ => event,
};

/// A message the user sent to the session.
class UserMessageEvent extends SessionEvent {
  const UserMessageEvent({
    required this.text,
    this.attachments = const <Attachment>[],
    super.seq,
    super.timestamp,
  });

  final String text;

  /// Files attached to the message (metadata only; payloads are fetched via
  /// `attachments.read`). Empty when the message carries no files.
  final List<Attachment> attachments;

  factory UserMessageEvent.fromJson(Map<String, Object?> json) =>
      UserMessageEvent(
        text: json['text']! as String,
        attachments:
            (json['attachments'] as List<Object?>?)
                ?.map((e) => Attachment.fromJson(e! as Map<String, Object?>))
                .toList(growable: false) ??
            const <Attachment>[],
        seq: json['seq'] as int?,
        timestamp: _parseTimestamp(json['timestamp']),
      );

  @override
  Map<String, Object?> toJson() {
    final localSeq = seq;
    final localTimestamp = timestamp;
    return <String, Object?>{
      'type': 'userMessage',
      'text': text,
      if (attachments.isNotEmpty)
        'attachments': attachments
            .map((a) => a.toJson())
            .toList(growable: false),
      'seq': ?localSeq,
      if (localTimestamp != null) 'timestamp': _formatTimestamp(localTimestamp),
    };
  }
}

/// An image the agent asked SpeedDial to display directly in the timeline.
/// Its payload is fetched lazily through `attachments.read`.
class ImageEvent extends SessionEvent {
  const ImageEvent({required this.attachment, super.seq, super.timestamp});

  final Attachment attachment;

  factory ImageEvent.fromJson(Map<String, Object?> json) => ImageEvent(
    attachment: Attachment.fromJson(
      (json['attachment']! as Map).cast<String, Object?>(),
    ),
    seq: json['seq'] as int?,
    timestamp: _parseTimestamp(json['timestamp']),
  );

  @override
  Map<String, Object?> toJson() {
    final int? localSeq = seq;
    final DateTime? localTimestamp = timestamp;
    return <String, Object?>{
      'type': 'image',
      'attachment': attachment.toJson(),
      'seq': ?localSeq,
      if (localTimestamp != null) 'timestamp': _formatTimestamp(localTimestamp),
    };
  }
}

/// A streaming delta of the agent's message.
class AgentMessageChunkEvent extends SessionEvent {
  const AgentMessageChunkEvent({
    required this.text,
    this.messageId,
    super.seq,
    super.timestamp,
  });

  final String text;

  /// Stable identity of the logical message within its turn.
  ///
  /// Null only for events persisted by daemon versions that predate message
  /// identity. New daemon events always carry a non-empty value.
  final String? messageId;

  factory AgentMessageChunkEvent.fromJson(Map<String, Object?> json) =>
      AgentMessageChunkEvent(
        text: json['text']! as String,
        messageId: json['messageId'] as String?,
        seq: json['seq'] as int?,
        timestamp: _parseTimestamp(json['timestamp']),
      );

  @override
  Map<String, Object?> toJson() {
    final localSeq = seq;
    final localTimestamp = timestamp;
    return <String, Object?>{
      'type': 'agentMessageChunk',
      'text': text,
      if (messageId case final String value) 'messageId': value,
      'seq': ?localSeq,
      if (localTimestamp != null) 'timestamp': _formatTimestamp(localTimestamp),
    };
  }
}

/// A streaming delta of the agent's reasoning; collapsible in the UI.
class AgentThoughtChunkEvent extends SessionEvent {
  const AgentThoughtChunkEvent({
    required this.text,
    this.messageId,
    super.seq,
    super.timestamp,
  });

  final String text;

  /// Stable identity of the logical thought item within its turn.
  ///
  /// Null only for events persisted by daemon versions that predate message
  /// identity. New daemon events always carry a non-empty value.
  final String? messageId;

  factory AgentThoughtChunkEvent.fromJson(Map<String, Object?> json) =>
      AgentThoughtChunkEvent(
        text: json['text']! as String,
        messageId: json['messageId'] as String?,
        seq: json['seq'] as int?,
        timestamp: _parseTimestamp(json['timestamp']),
      );

  @override
  Map<String, Object?> toJson() {
    final localSeq = seq;
    final localTimestamp = timestamp;
    return <String, Object?>{
      'type': 'agentThoughtChunk',
      'text': text,
      if (messageId case final String value) 'messageId': value,
      'seq': ?localSeq,
      if (localTimestamp != null) 'timestamp': _formatTimestamp(localTimestamp),
    };
  }
}

/// A tool call was created or updated; match by [ToolCall.id].
class ToolCallEvent extends SessionEvent {
  const ToolCallEvent({required this.toolCall, super.seq, super.timestamp});

  final ToolCall toolCall;

  factory ToolCallEvent.fromJson(Map<String, Object?> json) => ToolCallEvent(
    toolCall: ToolCall.fromJson(json['toolCall']! as Map<String, Object?>),
    seq: json['seq'] as int?,
    timestamp: _parseTimestamp(json['timestamp']),
  );

  @override
  Map<String, Object?> toJson() {
    final localSeq = seq;
    final localTimestamp = timestamp;
    return <String, Object?>{
      'type': 'toolCall',
      'toolCall': toolCall.toJson(),
      'seq': ?localSeq,
      if (localTimestamp != null) 'timestamp': _formatTimestamp(localTimestamp),
    };
  }
}

/// Full replacement of the session's plan.
class PlanEvent extends SessionEvent {
  const PlanEvent({required this.entries, super.seq, super.timestamp});

  final List<PlanEntry> entries;

  factory PlanEvent.fromJson(Map<String, Object?> json) => PlanEvent(
    entries: (json['entries']! as List<Object?>)
        .map((e) => PlanEntry.fromJson(e! as Map<String, Object?>))
        .toList(growable: false),
    seq: json['seq'] as int?,
    timestamp: _parseTimestamp(json['timestamp']),
  );

  @override
  Map<String, Object?> toJson() {
    final localSeq = seq;
    final localTimestamp = timestamp;
    return <String, Object?>{
      'type': 'plan',
      'entries': entries.map((e) => e.toJson()).toList(growable: false),
      'seq': ?localSeq,
      if (localTimestamp != null) 'timestamp': _formatTimestamp(localTimestamp),
    };
  }
}

/// The agent is asking the user to allow/reject an action.
class PermissionRequestEvent extends SessionEvent {
  const PermissionRequestEvent({
    required this.request,
    super.seq,
    super.timestamp,
  });

  final PermissionRequest request;

  factory PermissionRequestEvent.fromJson(Map<String, Object?> json) =>
      PermissionRequestEvent(
        request: PermissionRequest.fromJson(
          json['request']! as Map<String, Object?>,
        ),
        seq: json['seq'] as int?,
        timestamp: _parseTimestamp(json['timestamp']),
      );

  @override
  Map<String, Object?> toJson() {
    final localSeq = seq;
    final localTimestamp = timestamp;
    return <String, Object?>{
      'type': 'permissionRequest',
      'request': request.toJson(),
      'seq': ?localSeq,
      if (localTimestamp != null) 'timestamp': _formatTimestamp(localTimestamp),
    };
  }
}

/// A permission request was resolved with the given option.
class PermissionResolvedEvent extends SessionEvent {
  const PermissionResolvedEvent({
    required this.requestId,
    required this.optionId,
    super.seq,
    super.timestamp,
  });

  final String requestId;
  final String optionId;

  factory PermissionResolvedEvent.fromJson(Map<String, Object?> json) =>
      PermissionResolvedEvent(
        requestId: json['requestId']! as String,
        optionId: json['optionId']! as String,
        seq: json['seq'] as int?,
        timestamp: _parseTimestamp(json['timestamp']),
      );

  @override
  Map<String, Object?> toJson() {
    final localSeq = seq;
    final localTimestamp = timestamp;
    return <String, Object?>{
      'type': 'permissionResolved',
      'requestId': requestId,
      'optionId': optionId,
      'seq': ?localSeq,
      if (localTimestamp != null) 'timestamp': _formatTimestamp(localTimestamp),
    };
  }
}

/// Token usage accumulated for the current turn.
class UsageEvent extends SessionEvent {
  const UsageEvent({required this.usage, super.seq, super.timestamp});

  final UsageInfo usage;

  factory UsageEvent.fromJson(Map<String, Object?> json) => UsageEvent(
    usage: UsageInfo.fromJson(json['usage']! as Map<String, Object?>),
    seq: json['seq'] as int?,
    timestamp: _parseTimestamp(json['timestamp']),
  );

  @override
  Map<String, Object?> toJson() {
    final localSeq = seq;
    final localTimestamp = timestamp;
    return <String, Object?>{
      'type': 'usage',
      'usage': usage.toJson(),
      'seq': ?localSeq,
      if (localTimestamp != null) 'timestamp': _formatTimestamp(localTimestamp),
    };
  }
}

/// A provider-reported lifecycle or background activity.
class AgentActivityEvent extends SessionEvent {
  const AgentActivityEvent({
    required this.activity,
    super.seq,
    super.timestamp,
  });

  final AgentActivity activity;

  factory AgentActivityEvent.fromJson(Map<String, Object?> json) =>
      AgentActivityEvent(
        activity: AgentActivity.fromJson(
          json['activity']! as Map<String, Object?>,
        ),
        seq: json['seq'] as int?,
        timestamp: _parseTimestamp(json['timestamp']),
      );

  @override
  Map<String, Object?> toJson() {
    final localSeq = seq;
    final localTimestamp = timestamp;
    return <String, Object?>{
      'type': 'agentActivity',
      'activity': activity.toJson(),
      'seq': ?localSeq,
      if (localTimestamp != null) 'timestamp': _formatTimestamp(localTimestamp),
    };
  }
}

/// The agent finished its turn.
class TurnCompleteEvent extends SessionEvent {
  const TurnCompleteEvent({
    required this.stopReason,
    super.seq,
    super.timestamp,
  });

  /// "end_turn" | "cancelled" | "refusal" | "max_tokens" | ...
  final String stopReason;

  factory TurnCompleteEvent.fromJson(Map<String, Object?> json) =>
      TurnCompleteEvent(
        stopReason: json['stopReason']! as String,
        seq: json['seq'] as int?,
        timestamp: _parseTimestamp(json['timestamp']),
      );

  @override
  Map<String, Object?> toJson() {
    final localSeq = seq;
    final localTimestamp = timestamp;
    return <String, Object?>{
      'type': 'turnComplete',
      'stopReason': stopReason,
      'seq': ?localSeq,
      if (localTimestamp != null) 'timestamp': _formatTimestamp(localTimestamp),
    };
  }
}

/// The session hit an unrecoverable error.
class SessionErrorEvent extends SessionEvent {
  const SessionErrorEvent({required this.message, super.seq, super.timestamp});

  final String message;

  factory SessionErrorEvent.fromJson(Map<String, Object?> json) =>
      SessionErrorEvent(
        message: json['message']! as String,
        seq: json['seq'] as int?,
        timestamp: _parseTimestamp(json['timestamp']),
      );

  @override
  Map<String, Object?> toJson() {
    final localSeq = seq;
    final localTimestamp = timestamp;
    return <String, Object?>{
      'type': 'sessionError',
      'message': message,
      'seq': ?localSeq,
      if (localTimestamp != null) 'timestamp': _formatTimestamp(localTimestamp),
    };
  }
}
