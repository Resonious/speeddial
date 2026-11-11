/// A to-do note attached to a session (see PROTOCOL.md "Notes").
class SessionNote {
  const SessionNote({
    required this.id,
    required this.sessionId,
    required this.projectId,
    required this.text,
    required this.done,
    required this.createdAt,
    required this.updatedAt,
    this.doneAt,
  });

  final String id;
  final String sessionId;
  final String projectId;
  final String text;
  final bool done;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// When the note was checked off; null while it is open.
  final DateTime? doneAt;

  SessionNote copyWith({
    String? text,
    bool? done,
    DateTime? updatedAt,
    DateTime? Function()? doneAt,
  }) => SessionNote(
    id: id,
    sessionId: sessionId,
    projectId: projectId,
    text: text ?? this.text,
    done: done ?? this.done,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    doneAt: doneAt == null ? this.doneAt : doneAt(),
  );

  factory SessionNote.fromJson(Map<String, Object?> json) => SessionNote(
    id: json['id']! as String,
    sessionId: json['sessionId']! as String,
    projectId: json['projectId']! as String,
    text: json['text']! as String,
    done: json['done'] as bool? ?? false,
    createdAt: DateTime.parse(json['createdAt']! as String).toUtc(),
    updatedAt: DateTime.parse(json['updatedAt']! as String).toUtc(),
    doneAt: json['doneAt'] == null
        ? null
        : DateTime.parse(json['doneAt']! as String).toUtc(),
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'sessionId': sessionId,
    'projectId': projectId,
    'text': text,
    'done': done,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'doneAt': doneAt?.toUtc().toIso8601String(),
  };

  @override
  bool operator ==(Object other) =>
      other is SessionNote &&
      other.id == id &&
      other.sessionId == sessionId &&
      other.projectId == projectId &&
      other.text == text &&
      other.done == done &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt &&
      other.doneAt == doneAt;

  @override
  int get hashCode => Object.hash(
    id,
    sessionId,
    projectId,
    text,
    done,
    createdAt,
    updatedAt,
    doneAt,
  );
}

/// Longest note text the daemon accepts, in UTF-16 code units.
const int kMaxNoteLength = 4000;
