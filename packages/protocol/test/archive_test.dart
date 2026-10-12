import 'dart:convert';

import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('archive preview round-trips storage and blocked sessions', () {
    const ArchivePreview preview = ArchivePreview(
      sessionIds: <String>['one', 'two'],
      worktreeCount: 1,
      worktreeBytes: 1000,
      transcriptBytes: 200,
      attachmentBytes: 300,
      retainedWorktreeCount: 1,
      blockedSessions: <ArchiveFailure>[
        ArchiveFailure(sessionId: 'busy', message: 'Active'),
      ],
    );
    final ArchivePreview decoded = ArchivePreview.fromJson(
      (jsonDecode(jsonEncode(preview.toJson())) as Map).cast<String, Object?>(),
    );
    expect(decoded.toJson(), preview.toJson());
    expect(decoded.totalBytes, 1500);
  });

  test('clear result round-trips partial failures', () {
    const ClearArchiveResult result = ClearArchiveResult(
      deletedSessionIds: <String>['one'],
      removedWorktreeCount: 1,
      failures: <ArchiveFailure>[
        ArchiveFailure(sessionId: 'two', message: 'Locked worktree'),
      ],
    );
    expect(
      ClearArchiveResult.fromJson(result.toJson()).toJson(),
      result.toJson(),
    );
  });
}
