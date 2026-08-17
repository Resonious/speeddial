import 'package:flutter/foundation.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../api/daemon_client.dart';

/// Caches sessions bucketed by project and keyed by id.
///
/// [refresh] rebuilding all buckets is the source of truth for a listing;
/// mutating methods ([create], [rename], [archive], [delete], [setMode])
/// update both the by-project bucket and the by-id index immediately and
/// notify. Buckets keep the complete picture (archived included); the public
/// [sessionsFor] view omits archived sessions.
class SessionsStore extends ChangeNotifier {
  SessionsStore({required DaemonClient Function(String daemonId) clientFor})
      // ignore: prefer_initializing_formals
      : _clientFor = clientFor;

  final DaemonClient Function(String daemonId) _clientFor;

  final Map<String, List<Session>> _sessionsByProject =
      <String, List<Session>>{};
  final Map<String, Session> _sessionsById = <String, Session>{};

  /// Active (non-archived) sessions for [projectId]; empty until the first
  /// refresh. Archived sessions stay available via [byId] (the by-id index is
  /// always the complete picture).
  List<Session> sessionsFor(String projectId) => List<Session>.unmodifiable(
      _sessionsByProject[projectId]?.where((Session s) => !s.archived) ??
          const <Session>[]);

  /// The session with [sessionId], wherever it lives.
  Session? byId(String sessionId) => _sessionsById[sessionId];

  /// Refetches sessions (including archived ones so the store stays the
  /// complete picture; panes filter what they show).
  Future<void> refresh(String daemonId, {String? projectId}) async {
    final List<Session> sessions = await _clientFor(daemonId)
        .listSessions(projectId: projectId, includeArchived: true);
    if (projectId == null) {
      _sessionsByProject.clear();
      for (final Session session in sessions) {
        _sessionsByProject.putIfAbsent(session.projectId,
            () => <Session>[]).add(session);
      }
    } else {
      _sessionsByProject[projectId] = List<Session>.of(sessions);
    }
    for (final Session session in sessions) {
      _sessionsById[session.id] = session;
    }
    notifyListeners();
  }

  Future<Session> create(
    String daemonId, {
    required String projectId,
    required String providerId,
    String? model,
    SessionMode? mode,
    String? title,
  }) async {
    final Session session = await _clientFor(daemonId).createSession(
      projectId: projectId,
      providerId: providerId,
      model: model,
      mode: mode,
      title: title,
    );
    _sessionsByProject.putIfAbsent(projectId, () => <Session>[]).add(session);
    _sessionsById[session.id] = session;
    notifyListeners();
    return session;
  }

  Future<void> rename(String daemonId, String sessionId, String title) async {
    _replace(await _clientFor(daemonId).renameSession(sessionId, title));
  }

  Future<void> archive(
      String daemonId, String sessionId, bool archived) async {
    _replace(
        await _clientFor(daemonId).archiveSession(sessionId, archived));
  }

  Future<void> delete(String daemonId, String sessionId) async {
    final Session? before = _sessionsById[sessionId];
    await _clientFor(daemonId).deleteSession(sessionId);
    _sessionsById.remove(sessionId);
    if (before != null) {
      _sessionsByProject[before.projectId]
          ?.removeWhere((Session s) => s.id == sessionId);
    }
    notifyListeners();
  }

  Future<void> setMode(String daemonId, String sessionId, SessionMode mode) async {
    _replace(await _clientFor(daemonId).setMode(sessionId, mode));
  }

  void _replace(Session session) {
    _sessionsById[session.id] = session;
    final List<Session>? bucket = _sessionsByProject[session.projectId];
    if (bucket != null) {
      final int index = bucket.indexWhere((Session s) => s.id == session.id);
      if (index >= 0) {
        bucket[index] = session;
      } else {
        bucket.add(session);
      }
    }
    notifyListeners();
  }
}
