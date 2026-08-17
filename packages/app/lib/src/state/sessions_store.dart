import 'dart:async';

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
///
/// Caches are keyed by composite `daemonId/id` strings because session and
/// project ids are daemon-scoped (PROTOCOL.md): the same id may exist on
/// several daemons. Public single-id getters resolve across daemons by
/// preferring the daemon most recently used for that id (see
/// [_lastDaemonBySession] / [_lastDaemonByProject]), with any residual
/// ambiguity resolved last-write-wins — the UI always selects an explicit
/// daemon alongside a session id.
///
/// On first use of a daemon the store subscribes to its `sessionUpdates` /
/// `sessionRemovals` notifications so external changes (including other
/// devices) are reflected without a manual [refresh]; subscriptions live
/// until the store is disposed.
class SessionsStore extends ChangeNotifier {
  SessionsStore({required DaemonClient Function(String daemonId) clientFor})
      // ignore: prefer_initializing_formals
      : _clientFor = clientFor;

  final DaemonClient Function(String daemonId) _clientFor;

  /// `daemonId/projectId` → sessions (archived included); per daemon.
  final Map<String, List<Session>> _sessionsByProject =
      <String, List<Session>>{};

  /// `daemonId/sessionId` → session; always the complete picture.
  final Map<String, Session> _sessionsById = <String, Session>{};

  /// Most recently used daemon per session/project id; disambiguates
  /// cross-daemon id collisions in the public single-id getters.
  final Map<String, String> _lastDaemonBySession = <String, String>{};
  final Map<String, String> _lastDaemonByProject = <String, String>{};

  /// One `sessionUpdates`/`sessionRemovals` subscription per daemon, alive
  /// from first use until [dispose].
  final Map<String, StreamSubscription<Session>> _updateSubs =
      <String, StreamSubscription<Session>>{};
  final Map<String, StreamSubscription<String>> _removalSubs =
      <String, StreamSubscription<String>>{};

  /// Active (non-archived) sessions for [projectId] on the most recently
  /// used daemon; empty until the first refresh. Archived sessions stay
  /// available via [byId] (the by-id index is always the complete picture).
  List<Session> sessionsFor(String projectId) {
    final List<Session>? bucket = _bucketFor(projectId);
    return List<Session>.unmodifiable(
        bucket?.where((Session s) => !s.archived) ?? const <Session>[]);
  }

  /// The session with [sessionId] (preferring the last-used daemon for that
  /// id), wherever it lives; null when unknown.
  Session? byId(String sessionId) {
    final String? daemonId = _lastDaemonBySession[sessionId];
    if (daemonId != null) {
      final Session? preferred = _sessionsById[_scopedKey(daemonId, sessionId)];
      if (preferred != null) return preferred;
    }
    for (final Session session in _sessionsById.values) {
      if (session.id == sessionId) return session;
    }
    return null;
  }

  /// Refetches sessions (including archived ones so the store stays the
  /// complete picture; panes filter what they show).
  Future<void> refresh(String daemonId, {String? projectId}) async {
    _ensureDaemonSubscriptions(daemonId);
    final List<Session> sessions = await _clientFor(daemonId)
        .listSessions(projectId: projectId, includeArchived: true);
    // Drop only this daemon's cached buckets; other daemons' listings stay.
    _sessionsByProject.removeWhere(
        (String key, List<Session> _) => _daemonOf(key) == daemonId);
    if (projectId == null) {
      for (final Session session in sessions) {
        // Upsert: a sessionUpdates notification (create/rename on another
        // path) may have created the bucket mid-refresh with this session.
        final List<Session> bucket = _sessionsByProject.putIfAbsent(
            _scopedKey(daemonId, session.projectId), () => <Session>[]);
        final int index = bucket.indexWhere((Session s) => s.id == session.id);
        if (index >= 0) {
          bucket[index] = session;
        } else {
          bucket.add(session);
        }
        _note(daemonId, session);
      }
    } else {
      _sessionsByProject[_scopedKey(daemonId, projectId)] =
          List<Session>.of(sessions);
      for (final Session session in sessions) {
        _note(daemonId, session);
      }
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
    _ensureDaemonSubscriptions(daemonId);
    final Session session = await _clientFor(daemonId).createSession(
      projectId: projectId,
      providerId: providerId,
      model: model,
      mode: mode,
      title: title,
    );
    // Upsert rather than blind-add: daemons surface the created session on
    // `sessionUpdates`, and a live listener (running synchronously inside
    // createSession, before this continuation) may already have inserted it.
    final List<Session> bucket =
        _sessionsByProject.putIfAbsent(_scopedKey(daemonId, projectId),
            () => <Session>[]);
    final int index = bucket.indexWhere((Session s) => s.id == session.id);
    if (index >= 0) {
      bucket[index] = session;
    } else {
      bucket.add(session);
    }
    _note(daemonId, session);
    notifyListeners();
    return session;
  }

  Future<void> rename(String daemonId, String sessionId, String title) async {
    _ensureDaemonSubscriptions(daemonId);
    _replace(daemonId, await _clientFor(daemonId).renameSession(sessionId, title));
  }

  Future<void> archive(
      String daemonId, String sessionId, bool archived) async {
    _ensureDaemonSubscriptions(daemonId);
    _replace(
        daemonId, await _clientFor(daemonId).archiveSession(sessionId, archived));
  }

  Future<void> delete(String daemonId, String sessionId) async {
    _ensureDaemonSubscriptions(daemonId);
    final String key = _scopedKey(daemonId, sessionId);
    final Session? before = _sessionsById[key];
    await _clientFor(daemonId).deleteSession(sessionId);
    _sessionsById.remove(key);
    if (before != null) {
      _sessionsByProject[_scopedKey(daemonId, before.projectId)]
          ?.removeWhere((Session s) => s.id == sessionId);
    }
    notifyListeners();
  }

  Future<void> setMode(String daemonId, String sessionId, SessionMode mode) async {
    _ensureDaemonSubscriptions(daemonId);
    _replace(daemonId, await _clientFor(daemonId).setMode(sessionId, mode));
  }

  // ---------------------------------------------------------------------
  // Notifications
  // ---------------------------------------------------------------------

  void _ensureDaemonSubscriptions(String daemonId) {
    if (_updateSubs.containsKey(daemonId)) return;
    final DaemonClient client = _clientFor(daemonId);
    _updateSubs[daemonId] = client.sessionUpdates
        .listen((Session session) => _onSessionUpdate(daemonId, session));
    _removalSubs[daemonId] = client.sessionRemovals
        .listen((String sessionId) => _onSessionRemoved(daemonId, sessionId));
  }

  /// Upserts a session that changed daemon-side (created/updated) into the
  /// by-id index and — when a listing for its project exists — its bucket.
  void _onSessionUpdate(String daemonId, Session session) {
    _note(daemonId, session);
    final List<Session>? bucket =
        _sessionsByProject[_scopedKey(daemonId, session.projectId)];
    if (bucket == null) return; // never listed: nothing observable to change.
    final int index = bucket.indexWhere((Session s) => s.id == session.id);
    if (index >= 0) {
      bucket[index] = session;
    } else {
      bucket.add(session);
    }
    notifyListeners();
  }

  /// Removes a session the daemon deleted.
  void _onSessionRemoved(String daemonId, String sessionId) {
    final String key = _scopedKey(daemonId, sessionId);
    final Session? before = _sessionsById.remove(key);
    if (before == null) return;
    _sessionsByProject[_scopedKey(daemonId, before.projectId)]
        ?.removeWhere((Session s) => s.id == sessionId);
    notifyListeners();
  }

  void _replace(String daemonId, Session session) {
    _note(daemonId, session);
    final List<Session>? bucket =
        _sessionsByProject[_scopedKey(daemonId, session.projectId)];
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

  /// Records [session] in the by-id index and remembers [daemonId] as the
  /// most recently used daemon for its session and project ids.
  void _note(String daemonId, Session session) {
    _lastDaemonBySession[session.id] = daemonId;
    _lastDaemonByProject[session.projectId] = daemonId;
    _sessionsById[_scopedKey(daemonId, session.id)] = session;
  }

  List<Session>? _bucketFor(String projectId) {
    final String? daemonId = _lastDaemonByProject[projectId];
    if (daemonId != null) {
      final List<Session>? preferred =
          _sessionsByProject[_scopedKey(daemonId, projectId)];
      if (preferred != null) return preferred;
    }
    for (final String key in _sessionsByProject.keys) {
      if (_idOf(key) == projectId) return _sessionsByProject[key];
    }
    return null;
  }

  static String _scopedKey(String daemonId, String id) => '$daemonId/$id';
  static String _daemonOf(String key) => key.substring(0, key.indexOf('/'));
  static String _idOf(String key) => key.substring(key.indexOf('/') + 1);

  @override
  void dispose() {
    for (final StreamSubscription<Session> sub in _updateSubs.values) {
      sub.cancel();
    }
    _updateSubs.clear();
    for (final StreamSubscription<String> sub in _removalSubs.values) {
      sub.cancel();
    }
    _removalSubs.clear();
    super.dispose();
  }
}
