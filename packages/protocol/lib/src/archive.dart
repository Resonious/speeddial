/// A session retained during archive cleanup, with a reason to show the user.
class ArchiveFailure {
  const ArchiveFailure({required this.sessionId, required this.message});

  final String sessionId;
  final String message;

  factory ArchiveFailure.fromJson(Map<String, Object?> json) => ArchiveFailure(
    sessionId: json['sessionId']! as String,
    message: json['message']! as String,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'sessionId': sessionId,
    'message': message,
  };
}

/// A snapshot of archived sessions and estimated storage eligible for deletion.
class ArchivePreview {
  const ArchivePreview({
    required this.sessionIds,
    required this.worktreeCount,
    required this.worktreeBytes,
    required this.transcriptBytes,
    required this.attachmentBytes,
    required this.retainedWorktreeCount,
    this.blockedSessions = const <ArchiveFailure>[],
  });

  final List<String> sessionIds;
  final int worktreeCount;
  final int worktreeBytes;
  final int transcriptBytes;
  final int attachmentBytes;
  final int retainedWorktreeCount;
  final List<ArchiveFailure> blockedSessions;

  int get totalBytes => worktreeBytes + transcriptBytes + attachmentBytes;

  factory ArchivePreview.fromJson(Map<String, Object?> json) => ArchivePreview(
    sessionIds: (json['sessionIds']! as List).cast<String>(),
    worktreeCount: json['worktreeCount']! as int,
    worktreeBytes: json['worktreeBytes']! as int,
    transcriptBytes: json['transcriptBytes']! as int,
    attachmentBytes: json['attachmentBytes']! as int,
    retainedWorktreeCount: json['retainedWorktreeCount']! as int,
    blockedSessions: (json['blockedSessions']! as List)
        .map(
          (Object? value) =>
              ArchiveFailure.fromJson((value! as Map).cast<String, Object?>()),
        )
        .toList(growable: false),
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'sessionIds': sessionIds,
    'worktreeCount': worktreeCount,
    'worktreeBytes': worktreeBytes,
    'transcriptBytes': transcriptBytes,
    'attachmentBytes': attachmentBytes,
    'retainedWorktreeCount': retainedWorktreeCount,
    'blockedSessions': blockedSessions
        .map((ArchiveFailure failure) => failure.toJson())
        .toList(growable: false),
  };
}

class ClearArchiveResult {
  const ClearArchiveResult({
    required this.deletedSessionIds,
    required this.removedWorktreeCount,
    this.failures = const <ArchiveFailure>[],
  });

  final List<String> deletedSessionIds;
  final int removedWorktreeCount;
  final List<ArchiveFailure> failures;

  factory ClearArchiveResult.fromJson(Map<String, Object?> json) =>
      ClearArchiveResult(
        deletedSessionIds: (json['deletedSessionIds']! as List).cast<String>(),
        removedWorktreeCount: json['removedWorktreeCount']! as int,
        failures: (json['failures']! as List)
            .map(
              (Object? value) => ArchiveFailure.fromJson(
                (value! as Map).cast<String, Object?>(),
              ),
            )
            .toList(growable: false),
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'deletedSessionIds': deletedSessionIds,
    'removedWorktreeCount': removedWorktreeCount,
    'failures': failures
        .map((ArchiveFailure failure) => failure.toJson())
        .toList(growable: false),
  };
}
