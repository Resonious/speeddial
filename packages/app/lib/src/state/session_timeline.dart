import 'package:speeddial_protocol/speeddial_protocol.dart';

/// A presentation-neutral logical row in a session timeline.
///
/// Both the full client and Wear build their platform-specific widgets from
/// these entries. Provider delta chunking and replace-in-place snapshots are
/// resolved once here instead of being reinterpreted by every surface.
sealed class FoldedSessionEntry {
  const FoldedSessionEntry();
}

/// An event that already represents one complete timeline record.
final class FoldedSessionEvent extends FoldedSessionEntry {
  const FoldedSessionEvent(this.event);

  final SessionEvent event;
}

/// One logical assistant message assembled from all chunks with its identity.
final class FoldedAgentMessage extends FoldedSessionEntry {
  const FoldedAgentMessage({
    required this.text,
    required this.messageId,
    required this.seq,
    required this.timestamp,
  });

  final String text;
  final String? messageId;
  final int? seq;
  final DateTime? timestamp;
}

/// One logical reasoning item assembled from all chunks with its identity.
final class FoldedAgentThought extends FoldedSessionEntry {
  const FoldedAgentThought({
    required this.text,
    required this.messageId,
    required this.seq,
    required this.timestamp,
  });

  final String text;
  final String? messageId;
  final int? seq;
  final DateTime? timestamp;
}

/// One generation of a tool call, including every provider snapshot.
///
/// Most surfaces render only [latest]. The full client also consumes the
/// snapshots of legacy Ante `Agent` calls to preserve their progress steps.
final class FoldedToolCall extends FoldedSessionEntry {
  const FoldedToolCall(this.snapshots);

  final List<ToolCall> snapshots;

  ToolCall get latest => snapshots.last;
}

/// The latest snapshot of one provider activity at its first position.
final class FoldedAgentActivity extends FoldedSessionEntry {
  const FoldedAgentActivity(this.activity);

  final AgentActivity activity;
}

/// Folds raw persisted/live events into stable logical timeline entries.
///
/// Message and thought chunks with a non-null `messageId` merge by identity
/// within their turn, regardless of interleaved tool/activity updates. Legacy
/// chunks without identity merge while no newly inserted visible entry occurs;
/// updates to an existing tool/activity are transparent. Tool snapshots update
/// their first entry in place, while a provider reusing a terminal tool id for
/// a new active call starts a new generation.
List<FoldedSessionEntry> foldSessionEvents(List<SessionEvent> events) {
  final List<_EntryBuilder> builders = <_EntryBuilder>[];
  final Map<(bool, String), _ChunkBuilder> identifiedChunks =
      <(bool, String), _ChunkBuilder>{};
  final Map<String, _ToolBuilder> tools = <String, _ToolBuilder>{};
  final Map<String, _ActivityBuilder> activities = <String, _ActivityBuilder>{};
  _ChunkBuilder? legacyMessage;
  _ChunkBuilder? legacyThought;

  void breakLegacyChunks() {
    legacyMessage = null;
    legacyThought = null;
  }

  void resetTurnIdentities() {
    breakLegacyChunks();
    identifiedChunks.clear();
    tools.clear();
    activities.clear();
  }

  void addVisible(_EntryBuilder builder) {
    breakLegacyChunks();
    builders.add(builder);
  }

  void foldChunk({
    required bool message,
    required String text,
    required String? messageId,
    required int? seq,
    required DateTime? timestamp,
  }) {
    if (messageId != null) {
      final (bool, String) key = (message, messageId);
      final _ChunkBuilder? existing = identifiedChunks[key];
      if (existing != null) {
        existing.append(text, seq, timestamp);
        return;
      }
      final _ChunkBuilder created = _ChunkBuilder(
        message: message,
        text: text,
        messageId: messageId,
        seq: seq,
        timestamp: timestamp,
      );
      addVisible(created);
      identifiedChunks[key] = created;
      return;
    }

    if (message) {
      legacyThought = null;
      final _ChunkBuilder? existing = legacyMessage;
      if (existing != null) {
        existing.append(text, seq, timestamp);
        return;
      }
      final _ChunkBuilder created = _ChunkBuilder(
        message: true,
        text: text,
        messageId: null,
        seq: seq,
        timestamp: timestamp,
      );
      builders.add(created);
      legacyMessage = created;
      return;
    }

    legacyMessage = null;
    final _ChunkBuilder? existing = legacyThought;
    if (existing != null) {
      existing.append(text, seq, timestamp);
      return;
    }
    final _ChunkBuilder created = _ChunkBuilder(
      message: false,
      text: text,
      messageId: null,
      seq: seq,
      timestamp: timestamp,
    );
    builders.add(created);
    legacyThought = created;
  }

  for (final SessionEvent event in events) {
    switch (event) {
      case AgentMessageChunkEvent(
        :final text,
        :final messageId,
        :final seq,
        :final timestamp,
      ):
        foldChunk(
          message: true,
          text: text,
          messageId: messageId,
          seq: seq,
          timestamp: timestamp,
        );
      case AgentThoughtChunkEvent(
        :final text,
        :final messageId,
        :final seq,
        :final timestamp,
      ):
        foldChunk(
          message: false,
          text: text,
          messageId: messageId,
          seq: seq,
          timestamp: timestamp,
        );
      case ToolCallEvent(:final toolCall):
        final _ToolBuilder? existing = tools[toolCall.id];
        final bool reused =
            existing != null &&
            _isTerminalToolStatus(existing.latest.status) &&
            _isActiveToolStatus(toolCall.status);
        if (existing != null && !reused) {
          existing.snapshots.add(toolCall);
        } else {
          final _ToolBuilder created = _ToolBuilder(toolCall);
          addVisible(created);
          tools[toolCall.id] = created;
        }
      case AgentActivityEvent(:final activity):
        final _ActivityBuilder? existing = activities[activity.id];
        if (existing != null) {
          existing.activity = activity;
        } else {
          final _ActivityBuilder created = _ActivityBuilder(activity);
          addVisible(created);
          activities[activity.id] = created;
        }
      case UsageEvent():
        // Usage has no timeline row and is transparent to legacy chunks.
        break;
      case UserMessageEvent():
        resetTurnIdentities();
        builders.add(_EventBuilder(event));
      case TurnCompleteEvent() || SessionErrorEvent():
        addVisible(_EventBuilder(event));
        resetTurnIdentities();
      default:
        addVisible(_EventBuilder(event));
    }
  }

  return List<FoldedSessionEntry>.unmodifiable(
    builders.map((_EntryBuilder builder) => builder.build()),
  );
}

bool _isActiveToolStatus(ToolCallStatus status) => switch (status) {
  ToolCallStatus.pending || ToolCallStatus.running => true,
  ToolCallStatus.completed || ToolCallStatus.failed => false,
};

bool _isTerminalToolStatus(ToolCallStatus status) => switch (status) {
  ToolCallStatus.pending || ToolCallStatus.running => false,
  ToolCallStatus.completed || ToolCallStatus.failed => true,
};

sealed class _EntryBuilder {
  FoldedSessionEntry build();
}

final class _EventBuilder implements _EntryBuilder {
  const _EventBuilder(this.event);

  final SessionEvent event;

  @override
  FoldedSessionEntry build() => FoldedSessionEvent(event);
}

final class _ChunkBuilder implements _EntryBuilder {
  _ChunkBuilder({
    required this.message,
    required String text,
    required this.messageId,
    required this.seq,
    required this.timestamp,
  }) : text = StringBuffer(text);

  final bool message;
  final StringBuffer text;
  final String? messageId;
  int? seq;
  DateTime? timestamp;

  void append(String delta, int? latestSeq, DateTime? latestTimestamp) {
    text.write(delta);
    seq = latestSeq;
    timestamp = latestTimestamp;
  }

  @override
  FoldedSessionEntry build() => message
      ? FoldedAgentMessage(
          text: text.toString(),
          messageId: messageId,
          seq: seq,
          timestamp: timestamp,
        )
      : FoldedAgentThought(
          text: text.toString(),
          messageId: messageId,
          seq: seq,
          timestamp: timestamp,
        );
}

final class _ToolBuilder implements _EntryBuilder {
  _ToolBuilder(ToolCall initial) : snapshots = <ToolCall>[initial];

  final List<ToolCall> snapshots;

  ToolCall get latest => snapshots.last;

  @override
  FoldedSessionEntry build() =>
      FoldedToolCall(List<ToolCall>.unmodifiable(snapshots));
}

final class _ActivityBuilder implements _EntryBuilder {
  _ActivityBuilder(this.activity);

  AgentActivity activity;

  @override
  FoldedSessionEntry build() => FoldedAgentActivity(activity);
}
