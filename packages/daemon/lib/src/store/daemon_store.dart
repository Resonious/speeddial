/// SQLite persistence for the daemon: projects, sessions, and per-session
/// event logs.
///
/// The database is opened in WAL mode with foreign keys enforced. Timestamps
/// are stored as unix-microsecond INTEGERs (deterministically sortable); the
/// wire-facing models still carry ISO-8601 UTC [DateTime]s.
///
/// Map:
///   * `projects`       id TEXT PK, name, path TEXT UNIQUE, added_at,
///                      last_active_at
///   * `sessions`       id PK, project_id FK→projects, provider_id, title,
///                      status, mode, model NULL, cwd, archived INT,
///                      created_at, updated_at
///   * `session_events` session_id FK→sessions ON DELETE CASCADE, seq,
///                      timestamp, json, PK (session_id, seq)
library;

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart' hide Session;
import 'package:speeddial_protocol/speeddial_protocol.dart';

/// SQLite extended result code for a UNIQUE/PK constraint violation.
const int _sqliteConstraintUnique = 2067;

/// SQLite-backed store for the daemon's bookkeeping.
///
/// All methods are synchronous (the engine drives them from the event loop,
/// never concurrently). Access from multiple isolates is not supported.
class DaemonStore {
  DaemonStore(String path) : _db = sqlite3.open(path) {
    _init();
  }

  final Database _db;

  void _init() {
    _db.execute('PRAGMA journal_mode = WAL;');
    _db.execute('PRAGMA foreign_keys = ON;');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        path TEXT NOT NULL UNIQUE,
        added_at INTEGER NOT NULL,
        last_active_at INTEGER NOT NULL
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL REFERENCES projects(id),
        provider_id TEXT NOT NULL,
        title TEXT NOT NULL,
        status TEXT NOT NULL,
        mode TEXT NOT NULL,
        model TEXT,
        cwd TEXT NOT NULL,
        archived INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS session_events (
        session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        seq INTEGER NOT NULL,
        timestamp INTEGER NOT NULL,
        json TEXT NOT NULL,
        PRIMARY KEY (session_id, seq)
      );
    ''');
  }

  // -------------------------------------------------------------------------
  // Projects
  // -------------------------------------------------------------------------

  /// Inserts [project]; throws `DaemonError(kErrConflict)` when another
  /// project already uses the same path.
  void insertProject(Project project) {
    try {
      _db.execute(
        'INSERT INTO projects (id, name, path, added_at, last_active_at) '
        'VALUES (?, ?, ?, ?, ?)',
        [
          project.id,
          project.name,
          project.path,
          _ts(project.addedAt),
          _ts(project.lastActiveAt),
        ],
      );
    } on SqliteException catch (e) {
      if (e.extendedResultCode == _sqliteConstraintUnique) {
        throw DaemonError(
          kErrConflict,
          'Project path already exists: ${project.path}',
        );
      }
      rethrow;
    }
  }

  /// All projects ordered by when they were added (oldest first).
  List<Project> listProjects() {
    final rows = _db.select(
      'SELECT id, name, path, added_at, last_active_at '
      'FROM projects ORDER BY added_at ASC, id ASC',
    );
    return rows.map(_projectFromRow).toList(growable: false);
  }

  /// The project with [id], or null when unknown.
  Project? getProject(String id) {
    final rows = _db.select(
      'SELECT id, name, path, added_at, last_active_at '
      'FROM projects WHERE id = ?',
      [id],
    );
    if (rows.isEmpty) return null;
    return _projectFromRow(rows.first);
  }

  /// Bumps a project's `last_active_at` to now.
  void touchProject(String id) {
    _db.execute(
      'UPDATE projects SET last_active_at = ? WHERE id = ?',
      [_ts(DateTime.now()), id],
    );
  }

  /// Removes [id] and archives all of its sessions (the filesystem is never
  /// touched here). Runs in one transaction.
  ///
  /// The sessions reference the project via an enforcing FK, so the project
  /// row cannot be deleted while they exist. Enforcement is briefly suspended
  /// for the deletion transaction: the aim is to *detach* the project while
  /// keeping its archived sessions around, which is exactly what the FK would
  /// forbid. Inserts keep full enforcement (unknown project ids fail).
  void removeProject(String id) {
    _db.execute('PRAGMA foreign_keys = OFF;');
    try {
      _db.execute('BEGIN;');
      _db.execute('UPDATE sessions SET archived = 1 WHERE project_id = ?', [id]);
      _db.execute('DELETE FROM projects WHERE id = ?', [id]);
      _db.execute('COMMIT;');
    } on Object {
      _db.execute('ROLLBACK;');
      rethrow;
    } finally {
      _db.execute('PRAGMA foreign_keys = ON;');
    }
  }

  /// Renames the project with [id]; throws `DaemonError(kErrNotFound)` for an
  /// unknown id. The project path (and therefore the filesystem mapping) is
  /// untouched.
  Project renameProject(String id, String name) {
    _db.execute('UPDATE projects SET name = ? WHERE id = ?', [name, id]);
    if (_db.updatedRows == 0) {
      throw DaemonError(kErrNotFound, 'Project not found: $id');
    }
    return getProject(id)!;
  }

  // -------------------------------------------------------------------------
  // Sessions
  // -------------------------------------------------------------------------

  void insertSession(Session session) {
    _db.execute(
      'INSERT INTO sessions (id, project_id, provider_id, title, status, '
      'mode, model, cwd, archived, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        session.id,
        session.projectId,
        session.providerId,
        session.title,
        session.status.wire,
        session.mode.wire,
        session.model,
        session.cwd,
        session.archived ? 1 : 0,
        _ts(session.createdAt),
        _ts(session.updatedAt),
      ],
    );
  }

  /// Sessions, optionally filtered by [projectId] and/or hiding archived
  /// rows, ordered by creation time (oldest first).
  List<Session> listSessions({
    String? projectId,
    bool includeArchived = false,
  }) {
    final rows = _db.select(
      'SELECT id, project_id, provider_id, title, status, mode, model, cwd, '
      'archived, created_at, updated_at FROM sessions '
      'WHERE (? IS NULL OR project_id = ?) AND (? = 1 OR archived = 0) '
      'ORDER BY created_at ASC, id ASC',
      [projectId, projectId, includeArchived ? 1 : 0],
    );
    return rows.map(_sessionFromRow).toList(growable: false);
  }

  /// The session with [id], or null when unknown.
  Session? getSession(String id) {
    final rows = _db.select(
      'SELECT id, project_id, provider_id, title, status, mode, model, cwd, '
      'archived, created_at, updated_at FROM sessions WHERE id = ?',
      [id],
    );
    if (rows.isEmpty) return null;
    return _sessionFromRow(rows.first);
  }

  /// Replaces the row for [session] (must already exist).
  void updateSession(Session session) {
    _db.execute(
      'UPDATE sessions SET project_id = ?, provider_id = ?, title = ?, '
      'status = ?, mode = ?, model = ?, cwd = ?, archived = ?, '
      'created_at = ?, updated_at = ? WHERE id = ?',
      [
        session.projectId,
        session.providerId,
        session.title,
        session.status.wire,
        session.mode.wire,
        session.model,
        session.cwd,
        session.archived ? 1 : 0,
        _ts(session.createdAt),
        _ts(session.updatedAt),
        session.id,
      ],
    );
    if (_db.updatedRows == 0) {
      throw DaemonError(kErrNotFound, 'Session not found: ${session.id}');
    }
  }

  /// Permanently removes a session and (via cascade) its events.
  void deleteSession(String id) {
    _db.execute('DELETE FROM sessions WHERE id = ?', [id]);
  }

  // -------------------------------------------------------------------------
  // Session events
  // -------------------------------------------------------------------------

  /// The next sequence number for [sessionId] (`max(seq) + 1`, starting at 1).
  int nextSeq(String sessionId) {
    final rows = _db.select(
      'SELECT COALESCE(MAX(seq), 0) + 1 AS next FROM session_events '
      'WHERE session_id = ?',
      [sessionId],
    );
    return rows.first['next'] as int;
  }

  /// Persists [event] with the given [seq] and a "now" timestamp, returning
  /// the fully-populated event (seq + timestamp set) for broadcasting.
  SessionEvent appendEvent(String sessionId, int seq, SessionEvent event) {
    final timestamp = DateTime.now().toUtc();
    final json = event.toJson()
      ..['seq'] = seq
      ..['timestamp'] = timestamp.toIso8601String();
    _db.execute(
      'INSERT INTO session_events (session_id, seq, timestamp, json) '
      'VALUES (?, ?, ?, ?)',
      [sessionId, seq, _ts(timestamp), jsonEncode(json)],
    );
    return SessionEvent.fromJson(json);
  }

  /// Events of [sessionId] in ascending `seq` order.
  ///
  /// Without [beforeSeq] this returns the newest page; with it, the page of
  /// events strictly below that sequence. `hasMore` reports whether an older
  /// page exists. The default [limit] is 200; there is no hard cap here (the
  /// callers enforce protocol limits).
  ({List<SessionEvent> events, bool hasMore}) listEvents(
    String sessionId, {
    int limit = 200,
    int? beforeSeq,
  }) {
    final rows = _db.select(
      'SELECT json FROM session_events '
      'WHERE session_id = ? AND (? IS NULL OR seq < ?) '
      'ORDER BY seq DESC LIMIT ?',
      [sessionId, beforeSeq, beforeSeq, limit + 1],
    );
    final hasMore = rows.length > limit;
    final kept = hasMore ? rows.sublist(0, limit) : rows;
    final events = kept.reversed
        .map((row) => SessionEvent.fromJson(
              jsonDecode(row['json'] as String) as Map<String, Object?>,
            ))
        .toList(growable: false);
    return (events: events, hasMore: hasMore);
  }

  void dispose() => _db.dispose();

  // -------------------------------------------------------------------------
  // Row mapping
  // -------------------------------------------------------------------------

  Project _projectFromRow(Row row) => Project(
        id: row['id'] as String,
        name: row['name'] as String,
        path: row['path'] as String,
        addedAt: _fromTs(row['added_at'] as int),
        lastActiveAt: _fromTs(row['last_active_at'] as int),
      );

  Session _sessionFromRow(Row row) => Session(
        id: row['id'] as String,
        projectId: row['project_id'] as String,
        providerId: row['provider_id'] as String,
        title: row['title'] as String,
        status: SessionStatus.parse(row['status'] as String),
        mode: SessionMode.parse(row['mode'] as String),
        model: row['model'] as String?,
        cwd: row['cwd'] as String,
        archived: (row['archived'] as int) != 0,
        createdAt: _fromTs(row['created_at'] as int),
        updatedAt: _fromTs(row['updated_at'] as int),
      );

  static int _ts(DateTime value) => value.toUtc().microsecondsSinceEpoch;

  static DateTime _fromTs(int value) =>
      DateTime.fromMicrosecondsSinceEpoch(value).toUtc();
}
