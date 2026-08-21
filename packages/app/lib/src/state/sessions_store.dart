import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../api/daemon_client.dart';
import 'store_base.dart';

/// Caches sessions bucketed by project and keyed by id.
///
/// Mutating methods ([create], [fork], [rename], [archive], [delete],
/// [setMode]) update both the by-project bucket and the by-id index
/// immediately and notify.
/// Buckets keep the complete picture (archived included), ordered by last
/// activity newest-first; the public [sessionsFor] view omits archived sessions.
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
/// devices) are reflected without a manual [refresh], and to its `resynced`
/// stream so changes missed while the socket was down are refetched on
/// reconnect; subscriptions live until the store is disposed.
class SessionsStore extends StoreBase {
  factory SessionsStore({
    required DaemonClient Function(String daemonId) clientFor,
    required Listenable selection,
    required String? Function() selectedDaemonId,
    required String? Function() selectedSessionId,
  }) => SessionsStore._(
    clientFor,
    selection,
    selectedDaemonId,
    selectedSessionId,
  );

  SessionsStore._(
    this._clientFor,
    this._selection,
    this._selectedDaemonId,
    this._selectedSessionId,
  ) {
    _selection.addListener(_onSelectionChanged);
  }

  final DaemonClient Function(String daemonId) _clientFor;
  final Listenable _selection;
  final String? Function() _selectedDaemonId;
  final String? Function() _selectedSessionId;

  /// `daemonId/projectId` → sessions (archived included); per daemon.
  final Map<String, List<Session>> _sessionsByProject =
      <String, List<Session>>{};

  /// `daemonId/sessionId` → session; always the complete picture.
  final Map<String, Session> _sessionsById = <String, Session>{};

  /// Mutation revision per scoped session id, including removal tombstones.
  final Map<String, int> _revisionBySession = <String, int>{};
  int _nextRevision = 0;

  /// Most recently used daemon per session/project id; disambiguates
  /// cross-daemon id collisions in the public single-id getters.
  final Map<String, String> _lastDaemonBySession = <String, String>{};
  final Map<String, String> _lastDaemonByProject = <String, String>{};

  /// Scoped session ids whose latest observed turn completed while unselected.
  final Set<String> _unseenCompleted = <String>{};

  /// One `sessionUpdates`/`sessionRemovals` subscription per daemon, alive
  /// from first use until [dispose].
  final Map<String, StreamSubscription<Session>> _updateSubs =
      <String, StreamSubscription<Session>>{};
  final Map<String, StreamSubscription<String>> _removalSubs =
      <String, StreamSubscription<String>>{};

  /// One `resynced` subscription per daemon: after a reconnect the daemon
  /// may have changed sessions while we were offline (a restart flags
  /// interrupted turns, other devices rename/archive), so the cached
  /// listings are refetched wholesale.
  final Map<String, StreamSubscription<void>> _resyncSubs =
      <String, StreamSubscription<void>>{};

  /// Active (non-archived) sessions for [projectId] on the most recently
  /// used daemon; empty until the first refresh. Archived sessions stay
  /// available via [byId] (the by-id index is always the complete picture).
  List<Session> sessionsFor(String projectId) {
    final List<Session>? bucket = _bucketFor(projectId);
    return List<Session>.unmodifiable(
      bucket?.where((Session s) => !s.archived) ?? const <Session>[],
    );
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

  bool isDone(String daemonId, String sessionId) =>
      _unseenCompleted.contains(_scopedKey(daemonId, sessionId));

  /// Refetches sessions (including archived ones so the store stays the
  /// complete picture; panes filter what they show).
  Future<void> refresh(String daemonId, {String? projectId}) async {
    _ensureDaemonSubscriptions(daemonId);
    final Map<String, int> revisionsAtStart = <String, int>{
      for (final MapEntry<String, Session> entry in _sessionsById.entries)
        if (_daemonOf(entry.key) == daemonId &&
            (projectId == null || entry.value.projectId == projectId))
          entry.key: _revisionBySession[entry.key] ?? 0,
    };
    final List<Session> sessions = await _clientFor(daemonId)
        .listSessions(projectId: projectId, includeArchived: true);
    final Map<String, Session> listed = <String, Session>{
      for (final Session session in sessions)
        _scopedKey(daemonId, session.id): session,
    };
    final Set<String> keys = <String>{
      ...revisionsAtStart.keys,
      ...listed.keys,
      for (final MapEntry<String, Session> entry in _sessionsById.entries)
        if (_daemonOf(entry.key) == daemonId &&
            (projectId == null || entry.value.projectId == projectId))
          entry.key,
    };
    final List<Session> merged = <Session>[];
    for (final String key in keys) {
      final int revisionAtStart = revisionsAtStart[key] ?? 0;
      final int currentRevision = _revisionBySession[key] ?? 0;
      final Session? current = _sessionsById[key];
      final Session? snapshot = listed[key];
      if (currentRevision != revisionAtStart) {
        if (current != null) merged.add(current);
        continue;
      }
      if (snapshot == null) continue;
      merged.add(
        current != null && current.updatedAt.isAfter(snapshot.updatedAt)
            ? current
            : snapshot,
      );
    }

    final Set<String> mergedKeys = <String>{
      for (final Session session in merged) _scopedKey(daemonId, session.id),
    };
    final List<String> removedKeys = <String>[
      for (final MapEntry<String, Session> entry in _sessionsById.entries)
        if (_daemonOf(entry.key) == daemonId &&
            (projectId == null || entry.value.projectId == projectId) &&
            !mergedKeys.contains(entry.key))
          entry.key,
    ];
    _sessionsById.removeWhere(
      (String key, Session session) =>
          _daemonOf(key) == daemonId &&
          (projectId == null || session.projectId == projectId),
    );
    for (final String key in removedKeys) {
      _touch(key);
    }
    if (projectId == null) {
      _sessionsByProject.removeWhere(
        (String key, List<Session> _) => _daemonOf(key) == daemonId,
      );
    } else {
      _sessionsByProject.remove(_scopedKey(daemonId, projectId));
    }
    for (final Session session in merged) {
      final List<Session> bucket = _sessionsByProject.putIfAbsent(
        _scopedKey(daemonId, session.projectId),
        () => <Session>[],
      );
      _upsertNewestFirst(bucket, session);
      _note(daemonId, session);
      _touch(_scopedKey(daemonId, session.id));
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
    String? baseBranch,
    SessionSandboxMode? sandboxMode,
    bool yolo = false,
  }) async {
    _ensureDaemonSubscriptions(daemonId);
    final Session session = await _clientFor(daemonId).createSession(
      projectId: projectId,
      providerId: providerId,
      model: model,
      mode: mode,
      title: title,
      baseBranch: baseBranch,
      sandboxMode: sandboxMode,
      yolo: yolo,
    );
    // Upsert rather than blind-add: daemons surface the created session on
    // `sessionUpdates`, and a live listener (running synchronously inside
    // createSession, before this continuation) may already have inserted it.
    final List<Session> bucket = _sessionsByProject.putIfAbsent(
      _scopedKey(daemonId, projectId),
      () => <Session>[],
    );
    _upsertNewestFirst(bucket, session);
    _note(daemonId, session);
    notifyListeners();
    return session;
  }

  /// Creates a new session whose copied history ends at message event [seq].
  Future<Session> fork(String daemonId, String sourceSessionId, int seq) async {
    _ensureDaemonSubscriptions(daemonId);
    final Session session = await _clientFor(daemonId)
        .forkSession(sourceSessionId, seq);
    final List<Session> bucket = _sessionsByProject.putIfAbsent(
      _scopedKey(daemonId, session.projectId),
      () => <Session>[],
    );
    _upsertNewestFirst(bucket, session);
    _note(daemonId, session);
    notifyListeners();
    return session;
  }

  Future<void> rename(String daemonId, String sessionId, String title) async {
    _ensureDaemonSubscriptions(daemonId);
    _replace(
      daemonId,
      await _clientFor(daemonId).renameSession(sessionId, title),
    );
  }

  Future<void> archive(String daemonId, String sessionId, bool archived) async {
    _ensureDaemonSubscriptions(daemonId);
    _replace(
      daemonId,
      await _clientFor(daemonId).archiveSession(sessionId, archived),
    );
  }

  Future<void> delete(String daemonId, String sessionId) async {
    _ensureDaemonSubscriptions(daemonId);
    final String key = _scopedKey(daemonId, sessionId);
    final Session? before = _sessionsById[key];
    await _clientFor(daemonId).deleteSession(sessionId);
    _sessionsById.remove(key);
    _touch(key);
    _unseenCompleted.remove(key);
    if (before != null) {
      _sessionsByProject[_scopedKey(daemonId, before.projectId)]?.removeWhere(
        (Session s) => s.id == sessionId,
      );
    }
    notifyListeners();
  }

  Future<void> setMode(
    String daemonId,
    String sessionId,
    SessionMode mode,
  ) async {
    _ensureDaemonSubscriptions(daemonId);
    _replace(daemonId, await _clientFor(daemonId).setMode(sessionId, mode));
  }

  Future<void> setThinkingLevel(
    String daemonId,
    String sessionId,
    String level,
  ) async {
    _ensureDaemonSubscriptions(daemonId);
    _replace(
      daemonId,
      await _clientFor(daemonId).setThinkingLevel(sessionId, level),
    );
  }

  /// Sets the session's model. Valid ids come from `Session.models`; the
  /// current selection is `Session.model`.
  Future<void> setModel(String daemonId, String sessionId, String model) async {
    _ensureDaemonSubscriptions(daemonId);
    _replace(daemonId, await _clientFor(daemonId).setModel(sessionId, model));
  }

  // ---------------------------------------------------------------------
  // Notifications
  // ---------------------------------------------------------------------

  void _ensureDaemonSubscriptions(String daemonId) {
    if (_updateSubs.containsKey(daemonId)) return;
    final DaemonClient client = _clientFor(daemonId);
    _updateSubs[daemonId] = client.sessionUpdates.listen(
      (Session session) => _onSessionUpdate(daemonId, session),
    );
    _removalSubs[daemonId] = client.sessionRemovals.listen(
      (String sessionId) => _onSessionRemoved(daemonId, sessionId),
    );
    _resyncSubs[daemonId] = client.resynced.listen(
      (void _) => unawaited(_resync(daemonId)),
    );
  }

  /// Refetch after a reconnect; a failure here races a fresh drop and is
  /// healed by the next resync (or manual refresh).
  Future<void> _resync(String daemonId) async {
    try {
      await refresh(daemonId);
    } on Object {
      // Healed by the next resync or manual refresh.
    }
  }

  /// Upserts a session that changed daemon-side (created/updated) into the
  /// by-id index and — when a listing for its project exists — its bucket.
  void _onSessionUpdate(String daemonId, Session session) {
    final String key = _scopedKey(daemonId, session.id);
    final Session? current = _sessionsById[key];
    if (current != null && current.updatedAt.isAfter(session.updatedAt)) return;
    _note(daemonId, session);
    _touch(key);
    final List<Session>? bucket =
        _sessionsByProject[_scopedKey(daemonId, session.projectId)];
    if (bucket == null) return; // never listed: nothing observable to change.
    _upsertNewestFirst(bucket, session);
    notifyListeners();
  }

  /// Removes a session the daemon deleted.
  void _onSessionRemoved(String daemonId, String sessionId) {
    final String key = _scopedKey(daemonId, sessionId);
    final Session? before = _sessionsById.remove(key);
    _touch(key);
    _unseenCompleted.remove(key);
    if (before == null) return;
    _sessionsByProject[_scopedKey(daemonId, before.projectId)]?.removeWhere(
      (Session s) => s.id == sessionId,
    );
    notifyListeners();
  }

  void _replace(String daemonId, Session session) {
    final String key = _scopedKey(daemonId, session.id);
    final Session? current = _sessionsById[key];
    if (current != null && current.updatedAt.isAfter(session.updatedAt)) return;
    _note(daemonId, session);
    _touch(key);
    final List<Session>? bucket =
        _sessionsByProject[_scopedKey(daemonId, session.projectId)];
    if (bucket != null) {
      _upsertNewestFirst(bucket, session);
    }
    notifyListeners();
  }

  /// Records [session] in the by-id index and remembers [daemonId] as the
  /// most recently used daemon for its session and project ids.
  void _note(String daemonId, Session session) {
    final String key = _scopedKey(daemonId, session.id);
    final Session? previous = _sessionsById[key];
    if (session.archived || session.status != SessionStatus.idle) {
      _unseenCompleted.remove(key);
    } else if (_wasActive(previous?.status) &&
        !_isSelected(daemonId, session.id)) {
      _unseenCompleted.add(key);
    }
    _lastDaemonBySession[session.id] = daemonId;
    _lastDaemonByProject[session.projectId] = daemonId;
    _sessionsById[key] = session;
  }

  void _touch(String key) {
    _revisionBySession[key] = ++_nextRevision;
  }

  void _onSelectionChanged() {
    final String? daemonId = _selectedDaemonId();
    final String? sessionId = _selectedSessionId();
    if (daemonId == null || sessionId == null) return;
    if (_unseenCompleted.remove(_scopedKey(daemonId, sessionId))) {
      notifyListeners();
    }
  }

  bool _isSelected(String daemonId, String sessionId) =>
      _selectedDaemonId() == daemonId && _selectedSessionId() == sessionId;

  static bool _wasActive(SessionStatus? status) =>
      status == SessionStatus.running ||
      status == SessionStatus.waitingPermission;

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

  static void _upsertNewestFirst(List<Session> bucket, Session session) {
    bucket.removeWhere((Session item) => item.id == session.id);
    final int insertionIndex = bucket.indexWhere(
      (Session item) => _compareActivity(session, item) < 0,
    );
    bucket.insert(insertionIndex < 0 ? bucket.length : insertionIndex, session);
  }

  static int _compareActivity(Session a, Session b) {
    final int activity = b.lastActivityAt.compareTo(a.lastActivityAt);
    if (activity != 0) return activity;
    final int created = b.createdAt.compareTo(a.createdAt);
    if (created != 0) return created;
    return a.id.compareTo(b.id);
  }

  static String _scopedKey(String daemonId, String id) => '$daemonId/$id';
  static String _daemonOf(String key) => key.substring(0, key.indexOf('/'));
  static String _idOf(String key) => key.substring(key.indexOf('/') + 1);

  @override
  void dispose() {
    _selection.removeListener(_onSelectionChanged);
    for (final StreamSubscription<Session> sub in _updateSubs.values) {
      sub.cancel();
    }
    _updateSubs.clear();
    for (final StreamSubscription<String> sub in _removalSubs.values) {
      sub.cancel();
    }
    _removalSubs.clear();
    for (final StreamSubscription<void> sub in _resyncSubs.values) {
      sub.cancel();
    }
    _resyncSubs.clear();
    super.dispose();
  }
}
