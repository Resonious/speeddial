import 'models.dart';

/// A message the user sent while a turn was running, held by the daemon
/// until the session is free (PROTOCOL.md `sessions.send` with `queue`).
class QueuedMessage {
  const QueuedMessage({
    required this.id,
    required this.text,
    this.attachments = const <Attachment>[],
    required this.createdAt,
  });

  /// Daemon-assigned id, unique within its session's queue.
  final String id;
  final String text;

  /// Attachment metadata; payloads are already persisted and fetchable via
  /// `attachments.read`.
  final List<Attachment> attachments;
  final DateTime createdAt;

  factory QueuedMessage.fromJson(Map<String, Object?> json) => QueuedMessage(
    id: json['id']! as String,
    text: json['text']! as String,
    attachments:
        (json['attachments'] as List<Object?>?)
            ?.map(
              (Object? e) => Attachment.fromJson(e! as Map<String, Object?>),
            )
            .toList(growable: false) ??
        const <Attachment>[],
    createdAt: DateTime.parse(json['createdAt']! as String),
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'text': text,
    if (attachments.isNotEmpty)
      'attachments': attachments
          .map((Attachment a) => a.toMetadataJson())
          .toList(growable: false),
    'createdAt': createdAt.toUtc().toIso8601String(),
  };
}

/// A session's queued messages, oldest first, plus whether its live harness
/// can steer them into a running turn.
class SessionQueue {
  const SessionQueue({
    required this.sessionId,
    this.messages = const <QueuedMessage>[],
    this.canSteer = false,
    this.paused = false,
  });

  final String sessionId;
  final List<QueuedMessage> messages;

  /// The live harness accepts messages into a running turn
  /// (`sessions.sendQueued` steers instead of waiting).
  final bool canSteer;

  /// The daemon stopped delivering automatically because the last turn was
  /// cancelled or failed; `sessions.sendQueued` resumes delivery.
  final bool paused;

  factory SessionQueue.fromJson(Map<String, Object?> json) => SessionQueue(
    sessionId: json['sessionId']! as String,
    messages:
        (json['messages'] as List<Object?>?)
            ?.map(
              (Object? e) => QueuedMessage.fromJson(e! as Map<String, Object?>),
            )
            .toList(growable: false) ??
        const <QueuedMessage>[],
    canSteer: json['canSteer'] as bool? ?? false,
    paused: json['paused'] as bool? ?? false,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'sessionId': sessionId,
    'messages': messages
        .map((QueuedMessage m) => m.toJson())
        .toList(growable: false),
    'canSteer': canSteer,
    'paused': paused,
  };
}
