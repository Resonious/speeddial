import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../git/git_service.dart';
import '../store/daemon_store.dart';

enum _WorktreeKind { missing, removable, retained, project }

/// Previews and clears an explicit archive snapshot. The engine serializes
/// cleanup against session mutations before calling [clear].
class ArchiveService {
  ArchiveService({
    required this.store,
    required this.git,
    required this.isBusy,
    required this.stopSession,
    required this.deleteSession,
  });

  final DaemonStore store;
  final GitService git;
  final bool Function(String) isBusy;
  final Future<void> Function(String) stopSession;
  final Future<void> Function(String) deleteSession;

  Future<String> _canonical(String path) async {
    if (await Directory(path).exists()) {
      return Directory(path).resolveSymbolicLinks();
    }
    return p.normalize(p.absolute(path));
  }

  Future<Map<String, List<Session>>> _groups(List<Session> sessions) async {
    final Map<String, List<Session>> groups = <String, List<Session>>{};
    for (final Session session in sessions) {
      final String path = await _canonical(session.cwd);
      groups.putIfAbsent(path, () => <Session>[]).add(session);
    }
    return groups;
  }

  Future<_WorktreeKind> _kind(
    String path,
    List<Session> sessions,
    Set<String> selected,
  ) async {
    for (final Project project in store.listProjects()) {
      final String projectPath = await _canonical(project.path);
      if (projectPath == path || p.isWithin(path, projectPath)) {
        return _WorktreeKind.project;
      }
    }
    if (!await Directory(path).exists()) return _WorktreeKind.missing;
    if (!sessions.any((Session session) => session.baseBranch != null) &&
        await FileSystemEntity.type(p.join(path, '.git'), followLinks: false) !=
            FileSystemEntityType.file) {
      return _WorktreeKind.project;
    }
    if (sessions.any((Session session) => !selected.contains(session.id)) ||
        !sessions.any((Session session) => session.baseBranch != null) ||
        p.basename(p.dirname(path)) != '.speeddial-worktrees') {
      return _WorktreeKind.retained;
    }
    // Only daemon-created paths with verified Git registration may be removed.
    await git.validateLinkedWorktree(path);
    return _WorktreeKind.removable;
  }

  Future<int> _directoryBytes(String path) async {
    int bytes = 0;
    await for (final FileSystemEntity entity in Directory(
      path,
    ).list(recursive: true, followLinks: false)) {
      if (entity is File) bytes += await entity.length();
    }
    return bytes;
  }

  Future<ArchivePreview> preview() async {
    final List<Session> sessions = store.listSessions(includeArchived: true);
    final Set<String> selected = <String>{};
    final List<ArchiveFailure> blocked = <ArchiveFailure>[];
    for (final Session session in sessions.where(
      (Session session) => session.archived,
    )) {
      if (isBusy(session.id)) {
        blocked.add(
          ArchiveFailure(
            sessionId: session.id,
            message: 'Session is active or preparing.',
          ),
        );
      } else {
        selected.add(session.id);
      }
    }
    final Map<String, List<Session>> groups = await _groups(sessions);
    int worktreeCount = 0;
    int worktreeBytes = 0;
    int retainedCount = 0;
    for (final MapEntry<String, List<Session>> group in groups.entries) {
      final List<Session> targets = group.value
          .where((Session session) => selected.contains(session.id))
          .toList();
      if (targets.isEmpty) continue;
      try {
        final _WorktreeKind kind = await _kind(
          group.key,
          group.value,
          selected,
        );
        if (kind == _WorktreeKind.removable) {
          worktreeBytes += await _directoryBytes(group.key);
          worktreeCount++;
        } else if (kind == _WorktreeKind.retained) {
          retainedCount++;
        }
      } catch (error) {
        for (final Session session in targets) {
          selected.remove(session.id);
          blocked.add(
            ArchiveFailure(sessionId: session.id, message: error.toString()),
          );
        }
      }
    }
    int transcripts = 0;
    int attachments = 0;
    for (final String id in selected) {
      final usage = store.sessionStorageBytes(id);
      transcripts += usage.transcriptBytes;
      attachments += usage.attachmentBytes;
    }
    return ArchivePreview(
      sessionIds: selected.toList(growable: false),
      worktreeCount: worktreeCount,
      worktreeBytes: worktreeBytes,
      transcriptBytes: transcripts,
      attachmentBytes: attachments,
      retainedWorktreeCount: retainedCount,
      blockedSessions: blocked,
    );
  }

  Future<ClearArchiveResult> clear(List<String> sessionIds) async {
    final List<Session> sessions = store.listSessions(includeArchived: true);
    final Map<String, Session> byId = <String, Session>{
      for (final Session session in sessions) session.id: session,
    };
    final Set<String> selected = <String>{};
    final List<ArchiveFailure> failures = <ArchiveFailure>[];
    for (final String id in sessionIds.toSet()) {
      final Session? session = byId[id];
      if (session == null) continue; // Another client already deleted it.
      if (!session.archived || isBusy(id)) {
        failures.add(
          ArchiveFailure(
            sessionId: id,
            message: 'Session is no longer archived or is active.',
          ),
        );
      } else {
        selected.add(id);
      }
    }
    final Map<String, List<Session>> groups = await _groups(sessions);
    final List<String> deleted = <String>[];
    int removedWorktrees = 0;
    for (final MapEntry<String, List<Session>> group in groups.entries) {
      final List<Session> targets = group.value
          .where((Session session) => selected.contains(session.id))
          .toList();
      if (targets.isEmpty) continue;
      try {
        final _WorktreeKind kind = await _kind(
          group.key,
          group.value,
          selected,
        );
        for (final Session session in targets) {
          await stopSession(session.id);
        }
        if (kind == _WorktreeKind.removable) {
          await git.removeLinkedWorktree(group.key);
          removedWorktrees++;
        }
        for (final Session session in targets) {
          await deleteSession(session.id);
          deleted.add(session.id);
        }
      } catch (error) {
        for (final Session session in targets) {
          if (!deleted.contains(session.id)) {
            failures.add(
              ArchiveFailure(sessionId: session.id, message: error.toString()),
            );
          }
        }
      }
    }
    return ClearArchiveResult(
      deletedSessionIds: deleted,
      removedWorktreeCount: removedWorktrees,
      failures: failures,
    );
  }
}
