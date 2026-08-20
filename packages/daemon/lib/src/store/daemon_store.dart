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
///                      status, mode, model NULL, models TEXT JSON-array
///                      (default '[]'), cwd, base_branch NULL,
///                      acp_session_id NULL (provider-side id for resume),
///                      fork_context_seq NULL (copied history to inject into
///                      the fork's first provider turn), thinking_level NULL,
///                      thinking_levels TEXT JSON-array (default '[]'),
///                      yolo INT (auto-approve permissions), archived INT,
///                      created_at, updated_at
///   * `session_events` session_id FK→sessions ON DELETE CASCADE, seq,
///                      timestamp, json, PK (session_id, seq)
///   * `attachments`    id PK, session_id FK→sessions ON DELETE CASCADE,
///                      name, mime_type, size, data
library;

import 'dart:io';

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart' hide Session;
import 'package:speeddial_protocol/speeddial_protocol.dart';

typedef StoredMcpServer = ({
  McpServerProfile profile,
  Map<String, String> secrets,
});

/// Daemon-only OAuth state. Token and client-secret values never cross the
/// public wire API.
class StoredMcpOAuth {
  const StoredMcpOAuth({
    required this.status,
    required this.scopes,
    required this.clientSecretConfigured,
    this.clientId,
    this.clientSecret,
    this.tokenEndpointAuthMethod,
    this.authorizationServer,
    this.authorizationEndpoint,
    this.tokenEndpoint,
    this.registrationEndpoint,
    this.resource,
    this.redirectUri,
    this.accessToken,
    this.refreshToken,
    this.expiresAt,
    this.error,
  });

  final McpOAuthStatus status;
  final String? clientId;
  final String? clientSecret;
  final bool clientSecretConfigured;
  final String? tokenEndpointAuthMethod;
  final String? authorizationServer;
  final String? authorizationEndpoint;
  final String? tokenEndpoint;
  final String? resource;
  final String? registrationEndpoint;
  final String? redirectUri;
  final String? accessToken;
  final String? refreshToken;
  final DateTime? expiresAt;
  final List<String> scopes;
  final String? error;
}

/// SQLite extended result code for a UNIQUE/PK constraint violation.
const int _sqliteConstraintUnique = 2067;

/// SQLite-backed store for the daemon's bookkeeping.
///
/// All methods are synchronous (the engine drives them from the event loop,
/// never concurrently). Access from multiple isolates is not supported.
class DaemonStore {
  DaemonStore(String path) : _db = sqlite3.open(path) {
    _init();
    _restrictDatabasePermissions(path);
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
        models TEXT NOT NULL DEFAULT '[]',
        cwd TEXT NOT NULL,
        base_branch TEXT,
        fork_context_seq INTEGER,
        archived INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');
    // Older databases may lack columns introduced after their initial
    // release. Add each one in place without rewriting existing rows.
    final sessionColumns = _db
        .select('PRAGMA table_info(sessions)')
        .map((row) => row['name'] as String)
        .toSet();
    if (!sessionColumns.contains('base_branch')) {
      _db.execute('ALTER TABLE sessions ADD COLUMN base_branch TEXT');
    }
    if (!sessionColumns.contains('acp_session_id')) {
      _db.execute('ALTER TABLE sessions ADD COLUMN acp_session_id TEXT');
    }
    if (!sessionColumns.contains('thinking_level')) {
      _db.execute('ALTER TABLE sessions ADD COLUMN thinking_level TEXT');
    }
    if (!sessionColumns.contains('thinking_levels')) {
      _db.execute(
        "ALTER TABLE sessions ADD COLUMN thinking_levels TEXT NOT NULL "
        "DEFAULT '[]'",
      );
    }
    if (!sessionColumns.contains('models')) {
      _db.execute(
        "ALTER TABLE sessions ADD COLUMN models TEXT NOT NULL DEFAULT '[]'",
      );
    }
    if (!sessionColumns.contains('yolo')) {
      _db.execute(
        'ALTER TABLE sessions ADD COLUMN yolo INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (!sessionColumns.contains('fork_context_seq')) {
      _db.execute('ALTER TABLE sessions ADD COLUMN fork_context_seq INTEGER');
    }
    _db.execute('''
      CREATE TABLE IF NOT EXISTS session_events (
        session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        seq INTEGER NOT NULL,
        timestamp INTEGER NOT NULL,
        json TEXT NOT NULL,
        PRIMARY KEY (session_id, seq)
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS attachments (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        mime_type TEXT NOT NULL,
        size INTEGER NOT NULL,
        data BLOB NOT NULL
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS mcp_servers (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL COLLATE NOCASE UNIQUE,
        transport TEXT NOT NULL,
        enabled INTEGER NOT NULL,
        command TEXT,
        args TEXT NOT NULL DEFAULT '[]',
        url TEXT,
        auth_type TEXT NOT NULL DEFAULT 'none',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');
    final Set<String> mcpServerColumns = _db
        .select('PRAGMA table_info(mcp_servers)')
        .map((Row row) => row['name'] as String)
        .toSet();
    if (!mcpServerColumns.contains('auth_type')) {
      _db.execute(
        "ALTER TABLE mcp_servers ADD COLUMN auth_type TEXT NOT NULL "
        "DEFAULT 'none'",
      );
    }
    _db.execute('''
      CREATE TABLE IF NOT EXISTS mcp_secrets (
        server_id TEXT NOT NULL REFERENCES mcp_servers(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        value TEXT NOT NULL,
        PRIMARY KEY (server_id, name)
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS mcp_oauth (
        server_id TEXT PRIMARY KEY
          REFERENCES mcp_servers(id) ON DELETE CASCADE,
        status TEXT NOT NULL DEFAULT 'not_connected',
        client_id TEXT,
        client_secret TEXT,
        token_endpoint_auth_method TEXT,
        authorization_server TEXT,
        authorization_endpoint TEXT,
        token_endpoint TEXT,
        registration_endpoint TEXT,
        resource TEXT,
        redirect_uri TEXT,
        access_token TEXT,
        refresh_token TEXT,
        expires_at INTEGER,
        scopes TEXT NOT NULL DEFAULT '[]',
        error TEXT,
        updated_at INTEGER NOT NULL
      );
    ''');
    final Set<String> mcpOAuthColumns = _db
        .select('PRAGMA table_info(mcp_oauth)')
        .map((Row row) => row['name'] as String)
        .toSet();
    if (!mcpOAuthColumns.contains('resource')) {
      _db.execute('ALTER TABLE mcp_oauth ADD COLUMN resource TEXT');
    }
    _db.execute(
      "UPDATE mcp_oauth SET status = 'not_connected', "
      "error = 'Authorization was interrupted by a daemon restart' "
      "WHERE status = 'authorizing'",
    );
  }

  void _restrictDatabasePermissions(String path) {
    if ((!Platform.isLinux && !Platform.isMacOS) || path == ':memory:') return;
    for (final String candidate in <String>[path, '$path-wal', '$path-shm']) {
      if (!File(candidate).existsSync()) continue;
      try {
        Process.runSync('chmod', <String>['0600', candidate]);
      } on ProcessException {
        // Best-effort. SQLite remains usable on hosts without chmod.
      }
    }
  }

  // -------------------------------------------------------------------------
  // MCP servers
  // -------------------------------------------------------------------------

  List<McpServerProfile> listMcpServers() {
    final rows = _db.select(
      'SELECT id, name, transport, enabled, command, args, url, auth_type, '
      'created_at, updated_at FROM mcp_servers ',
    );
    return rows
        .map((Row row) => _mcpProfileFromRow(row))
        .toList(growable: false);
  }

  List<StoredMcpServer> listEnabledMcpServers() {
    final rows = _db.select(
      'SELECT id, name, transport, enabled, command, args, url, auth_type, '
      'created_at, updated_at FROM mcp_servers WHERE enabled = 1 '
      'ORDER BY name COLLATE NOCASE, id',
    );
    final List<StoredMcpServer> servers = <StoredMcpServer>[];
    for (final Row row in rows) {
      final McpServerProfile profile = _mcpProfileFromRow(row);
      final Map<String, String> secrets = _mcpSecrets(profile.id);
      if (profile.authType == McpAuthType.oauth) {
        final StoredMcpOAuth? oauth = getMcpOAuth(profile.id);
        if (profile.oauthStatus != McpOAuthStatus.authorized ||
            oauth?.accessToken == null) {
          continue;
        }
        secrets['Authorization'] = 'Bearer ${oauth!.accessToken}';
      }
      servers.add((profile: profile, secrets: secrets));
    }
    return servers;
  }

  McpServerProfile? getMcpServer(String id) {
    final rows = _db.select(
      'SELECT id, name, transport, enabled, command, args, url, auth_type, '
      'created_at, updated_at FROM mcp_servers WHERE id = ?',
      <Object?>[id],
    );
    return rows.isEmpty ? null : _mcpProfileFromRow(rows.first);
  }

  void insertMcpServer(McpServerProfile profile, Map<String, String> secrets) {
    _db.execute('BEGIN');
    try {
      _db.execute(
        'INSERT INTO mcp_servers '
        '(id, name, transport, enabled, command, args, url, auth_type, '
        'created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          profile.id,
          profile.name,
          profile.transport.wire,
          profile.enabled ? 1 : 0,
          profile.command,
          jsonEncode(profile.args),
          profile.url,
          profile.authType.wire,
          _ts(profile.createdAt),
          _ts(profile.updatedAt),
        ],
      );
      _setMcpSecrets(profile.id, secrets);
      _db.execute('COMMIT');
    } on SqliteException catch (error) {
      _db.execute('ROLLBACK');
      if (error.extendedResultCode == _sqliteConstraintUnique) {
        throw DaemonError(
          kErrConflict,
          'An MCP server named "${profile.name}" already exists',
        );
      }
      rethrow;
    } on Object {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void updateMcpServer(
    McpServerProfile profile, {
    Map<String, String> setSecrets = const <String, String>{},
    List<String> removeSecretNames = const <String>[],
  }) {
    _db.execute('BEGIN');
    try {
      _db.execute(
        'UPDATE mcp_servers SET name = ?, transport = ?, enabled = ?, '
        'command = ?, args = ?, url = ?, auth_type = ?, updated_at = ? '
        'WHERE id = ?',
        <Object?>[
          profile.name,
          profile.transport.wire,
          profile.enabled ? 1 : 0,
          profile.command,
          jsonEncode(profile.args),
          profile.url,
          profile.authType.wire,
          _ts(profile.updatedAt),
          profile.id,
        ],
      );
      for (final String name in removeSecretNames) {
        _db.execute(
          'DELETE FROM mcp_secrets WHERE server_id = ? AND name = ?',
          <Object?>[profile.id, name],
        );
      }
      _setMcpSecrets(profile.id, setSecrets);
      _db.execute('COMMIT');
    } on SqliteException catch (error) {
      _db.execute('ROLLBACK');
      if (error.extendedResultCode == _sqliteConstraintUnique) {
        throw DaemonError(
          kErrConflict,
          'An MCP server named "${profile.name}" already exists',
        );
      }
      rethrow;
    } on Object {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  bool deleteMcpServer(String id) {
    _db.execute('DELETE FROM mcp_servers WHERE id = ?', <Object?>[id]);
    return _db.updatedRows != 0;
  }

  McpServerProfile _mcpProfileFromRow(Row row) {
    final String id = row['id'] as String;
    final List<String> secretNames = _mcpSecrets(id).keys.toList()..sort();
    final McpAuthType authType = McpAuthType.parse(row['auth_type'] as String);
    final StoredMcpOAuth? oauth = authType == McpAuthType.oauth
        ? getMcpOAuth(id)
        : null;
    McpOAuthStatus status = oauth?.status ?? McpOAuthStatus.notConnected;
    final DateTime? expiresAt = oauth?.expiresAt;
    if (status == McpOAuthStatus.authorized &&
        expiresAt != null &&
        !expiresAt.isAfter(DateTime.now().toUtc())) {
      status = McpOAuthStatus.expired;
    }
    return McpServerProfile(
      id: id,
      name: row['name'] as String,
      transport: McpTransport.parse(row['transport'] as String),
      enabled: (row['enabled'] as int) != 0,
      command: row['command'] as String?,
      args: _models(row['args'] as String?),
      url: row['url'] as String?,
      secretNames: secretNames,
      authType: authType,
      oauthStatus: status,
      oauthClientId: oauth?.clientId,
      oauthClientSecretConfigured: oauth?.clientSecretConfigured ?? false,
      oauthScopes: oauth?.scopes ?? const <String>[],
      oauthExpiresAt: expiresAt,
      oauthError: oauth?.error,
      createdAt: _fromTs(row['created_at'] as int),
      updatedAt: _fromTs(row['updated_at'] as int),
    );
  }

  Map<String, String> _mcpSecrets(String serverId) {
    final rows = _db.select(
      'SELECT name, value FROM mcp_secrets WHERE server_id = ? ORDER BY name',
      <Object?>[serverId],
    );
    return <String, String>{
      for (final Row row in rows) row['name'] as String: row['value'] as String,
    };
  }

  void _setMcpSecrets(String serverId, Map<String, String> secrets) {
    for (final MapEntry<String, String> secret in secrets.entries) {
      _db.execute(
        'INSERT INTO mcp_secrets (server_id, name, value) VALUES (?, ?, ?) '
        'ON CONFLICT(server_id, name) DO UPDATE SET value = excluded.value',
        <Object?>[serverId, secret.key, secret.value],
      );
    }
  }

  StoredMcpOAuth? getMcpOAuth(String serverId) {
    final ResultSet rows = _db.select(
      'SELECT status, client_id, client_secret, token_endpoint_auth_method, '
      'authorization_server, authorization_endpoint, token_endpoint, '
      'registration_endpoint, resource, redirect_uri, access_token, '
      'refresh_token, expires_at, scopes, error FROM mcp_oauth '
      'WHERE server_id = ?',
      <Object?>[serverId],
    );
    if (rows.isEmpty) return null;
    final Row row = rows.first;
    final String? clientSecret = row['client_secret'] as String?;
    return StoredMcpOAuth(
      status: McpOAuthStatus.parse(row['status'] as String),
      clientId: row['client_id'] as String?,
      clientSecret: clientSecret,
      clientSecretConfigured: clientSecret != null,
      tokenEndpointAuthMethod: row['token_endpoint_auth_method'] as String?,
      authorizationServer: row['authorization_server'] as String?,
      authorizationEndpoint: row['authorization_endpoint'] as String?,
      tokenEndpoint: row['token_endpoint'] as String?,
      registrationEndpoint: row['registration_endpoint'] as String?,
      resource: row['resource'] as String?,
      redirectUri: row['redirect_uri'] as String?,
      accessToken: row['access_token'] as String?,
      refreshToken: row['refresh_token'] as String?,
      expiresAt: switch (row['expires_at']) {
        final int value => _fromTs(value),
        _ => null,
      },
      scopes: _models(row['scopes'] as String?),
      error: row['error'] as String?,
    );
  }

  void setMcpOAuthClient(
    String serverId, {
    required String clientId,
    String? clientSecret,
    String? tokenEndpointAuthMethod,
    String? redirectUri,
  }) {
    _ensureMcpOAuth(serverId);
    _db.execute(
      'UPDATE mcp_oauth SET client_id = ?, client_secret = ?, '
      'token_endpoint_auth_method = ?, redirect_uri = ?, updated_at = ? '
      'WHERE server_id = ?',
      <Object?>[
        clientId,
        clientSecret,
        tokenEndpointAuthMethod,
        redirectUri,
        _ts(DateTime.now()),
        serverId,
      ],
    );
  }

  void setMcpOAuthDiscovery(
    String serverId, {
    required String authorizationServer,
    required String authorizationEndpoint,
    required String tokenEndpoint,
    required String resource,
    String? registrationEndpoint,
  }) {
    _ensureMcpOAuth(serverId);
    _db.execute(
      'UPDATE mcp_oauth SET authorization_server = ?, '
      'authorization_endpoint = ?, token_endpoint = ?, '
      'registration_endpoint = ?, resource = ?, updated_at = ? '
      'WHERE server_id = ?',
      <Object?>[
        authorizationServer,
        authorizationEndpoint,
        tokenEndpoint,
        registrationEndpoint,
        resource,
        _ts(DateTime.now()),
        serverId,
      ],
    );
  }

  void setMcpOAuthStatus(
    String serverId,
    McpOAuthStatus status, {
    String? error,
  }) {
    _ensureMcpOAuth(serverId);
    _db.execute(
      'UPDATE mcp_oauth SET status = ?, error = ?, updated_at = ? '
      'WHERE server_id = ?',
      <Object?>[status.wire, error, _ts(DateTime.now()), serverId],
    );
  }

  void setMcpOAuthTokens(
    String serverId, {
    required String accessToken,
    String? refreshToken,
    DateTime? expiresAt,
    required List<String> scopes,
  }) {
    _ensureMcpOAuth(serverId);
    _db.execute(
      'UPDATE mcp_oauth SET status = ?, access_token = ?, '
      'refresh_token = COALESCE(?, refresh_token), expires_at = ?, '
      'scopes = ?, error = NULL, updated_at = ? WHERE server_id = ?',
      <Object?>[
        McpOAuthStatus.authorized.wire,
        accessToken,
        refreshToken,
        expiresAt == null ? null : _ts(expiresAt),
        jsonEncode(scopes),
        _ts(DateTime.now()),
        serverId,
      ],
    );
  }

  void clearMcpOAuthTokens(String serverId) {
    _ensureMcpOAuth(serverId);
    _db.execute(
      'UPDATE mcp_oauth SET status = ?, access_token = NULL, '
      'refresh_token = NULL, expires_at = NULL, scopes = ?, error = NULL, '
      'updated_at = ? WHERE server_id = ?',
      <Object?>[
        McpOAuthStatus.notConnected.wire,
        '[]',
        _ts(DateTime.now()),
        serverId,
      ],
    );
  }

  void resetMcpOAuth(String serverId) {
    _db.execute('DELETE FROM mcp_oauth WHERE server_id = ?', <Object?>[
      serverId,
    ]);
  }

  void _ensureMcpOAuth(String serverId) {
    _db.execute(
      'INSERT INTO mcp_oauth (server_id, updated_at) VALUES (?, ?) '
      'ON CONFLICT(server_id) DO NOTHING',
      <Object?>[serverId, _ts(DateTime.now())],
    );
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
    _db.execute('UPDATE projects SET last_active_at = ? WHERE id = ?', [
      _ts(DateTime.now()),
      id,
    ]);
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
      _db.execute('UPDATE sessions SET archived = 1 WHERE project_id = ?', [
        id,
      ]);
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
      'mode, model, models, cwd, base_branch, thinking_level, '
      'thinking_levels, yolo, archived, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        session.id,
        session.projectId,
        session.providerId,
        session.title,
        session.status.wire,
        session.mode.wire,
        session.model,
        jsonEncode(session.models),
        session.cwd,
        session.baseBranch,
        session.thinkingLevel,
        jsonEncode(session.thinkingLevels),
        session.yolo ? 1 : 0,
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
      'SELECT id, project_id, provider_id, title, status, mode, model, '
      'models, cwd, base_branch, thinking_level, thinking_levels, yolo, '
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
      'SELECT id, project_id, provider_id, title, status, mode, model, '
      'models, cwd, base_branch, thinking_level, thinking_levels, yolo, '
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
      'status = ?, mode = ?, model = ?, models = ?, cwd = ?, base_branch = ?, '
      'thinking_level = ?, thinking_levels = ?, '
      'yolo = ?, archived = ?, created_at = ?, updated_at = ? WHERE id = ?',
      [
        session.projectId,
        session.providerId,
        session.title,
        session.status.wire,
        session.mode.wire,
        session.model,
        jsonEncode(session.models),
        session.cwd,
        session.baseBranch,
        session.thinkingLevel,
        jsonEncode(session.thinkingLevels),
        session.yolo ? 1 : 0,
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

  /// Permanently removes a session and (via cascade) its events and
  /// attachments.
  void deleteSession(String id) {
    _db.execute('DELETE FROM sessions WHERE id = ?', [id]);
  }

  /// Persists the provider-side ACP session id for [sessionId] so the
  /// session can be resumed (ACP `session/load`) after a daemon restart.
  /// Throws `DaemonError(kErrNotFound)` for an unknown id.
  void setAcpSessionId(String sessionId, String acpSessionId) {
    _db.execute('UPDATE sessions SET acp_session_id = ? WHERE id = ?', [
      acpSessionId,
      sessionId,
    ]);
    if (_db.updatedRows == 0) {
      throw DaemonError(kErrNotFound, 'Session not found: $sessionId');
    }
  }

  /// The stored ACP session id for [sessionId]; null for unknown sessions
  /// and for sessions persisted before resume support existed.
  String? acpSessionIdOf(String sessionId) {
    final rows = _db.select(
      'SELECT acp_session_id FROM sessions WHERE id = ?',
      [sessionId],
    );
    if (rows.isEmpty) return null;
    return rows.first['acp_session_id'] as String?;
  }

  /// The copied-history boundary that must be supplied as inherited context
  /// with this session's first new provider turn. Null for ordinary sessions
  /// and forks whose handoff has completed.
  int? forkContextSeqOf(String sessionId) {
    final rows = _db.select(
      'SELECT fork_context_seq FROM sessions WHERE id = ?',
      [sessionId],
    );
    if (rows.isEmpty) return null;
    return rows.first['fork_context_seq'] as int?;
  }

  /// Sets or clears the pending fork-context boundary for [sessionId].
  void setForkContextSeq(String sessionId, int? seq) {
    _db.execute('UPDATE sessions SET fork_context_seq = ? WHERE id = ?', [
      seq,
      sessionId,
    ]);
    if (_db.updatedRows == 0) {
      throw DaemonError(kErrNotFound, 'Session not found: $sessionId');
    }
  }

  /// Searches non-archived sessions by title and persisted event JSON.
  /// Results exclude the caller's own session and include a short matching
  /// conversation excerpt so an MCP caller can decide what to inspect.
  List<Map<String, Object?>> searchSessions({
    required String query,
    required String excludeSessionId,
    String? projectId,
    int limit = 20,
  }) {
    final String needle = query.toLowerCase();
    final rows = _db.select(
      'SELECT s.id, s.project_id, p.name AS project_name, s.provider_id, '
      's.title, s.status, s.mode, s.updated_at '
      'FROM sessions s JOIN projects p ON p.id = s.project_id '
      'WHERE s.id != ? AND s.archived = 0 '
      'AND (? IS NULL OR s.project_id = ?) '
      "AND (? = '' OR instr(lower(s.title), ?) > 0 OR EXISTS ("
      'SELECT 1 FROM session_events e WHERE e.session_id = s.id '
      'AND instr(lower(e.json), ?) > 0)) '
      'ORDER BY s.updated_at DESC LIMIT ?',
      <Object?>[
        excludeSessionId,
        projectId,
        projectId,
        needle,
        needle,
        needle,
        limit,
      ],
    );
    return rows
        .map((row) {
          final String id = row['id'] as String;
          return <String, Object?>{
            'id': id,
            'projectId': row['project_id'] as String,
            'projectName': row['project_name'] as String,
            'providerId': row['provider_id'] as String,
            'title': row['title'] as String,
            'status': row['status'] as String,
            'mode': row['mode'] as String,
            'updatedAt': _fromTs(row['updated_at'] as int).toIso8601String(),
            'excerpt': _sessionSearchExcerpt(id, needle),
          };
        })
        .toList(growable: false);
  }

  String _sessionSearchExcerpt(String sessionId, String needle) {
    final rows = _db.select(
      'SELECT json FROM session_events WHERE session_id = ? '
      "AND (? = '' OR instr(lower(json), ?) > 0) "
      'ORDER BY seq DESC LIMIT 20',
      <Object?>[sessionId, needle, needle],
    );
    for (final row in rows) {
      final json = jsonDecode(row['json'] as String) as Map<String, Object?>;
      final Object? rawText = switch (json['type']) {
        'userMessage' ||
        'agentMessageChunk' ||
        'agentThoughtChunk' => json['text'],
        'sessionError' => json['message'],
        _ => null,
      };
      if (rawText is! String || rawText.isEmpty) continue;
      final String text = rawText.replaceAll(RegExp(r'\s+'), ' ').trim();
      return text.length <= 240 ? text : '${text.substring(0, 237)}...';
    }
    return '';
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

  /// The event at exactly [seq], or null when that sequence is absent.
  SessionEvent? eventAt(String sessionId, int seq) {
    final rows = _db.select(
      'SELECT json FROM session_events WHERE session_id = ? AND seq = ?',
      [sessionId, seq],
    );
    if (rows.isEmpty) return null;
    return SessionEvent.fromJson(
      jsonDecode(rows.first['json'] as String) as Map<String, Object?>,
    );
  }

  /// Every event from the start of [sessionId] through [throughSeq],
  /// inclusive and ordered ascending. Used only when materializing a fork.
  List<SessionEvent> eventsThrough(String sessionId, int throughSeq) {
    final rows = _db.select(
      'SELECT json FROM session_events '
      'WHERE session_id = ? AND seq <= ? ORDER BY seq ASC',
      [sessionId, throughSeq],
    );
    return rows
        .map(
          (row) => SessionEvent.fromJson(
            jsonDecode(row['json'] as String) as Map<String, Object?>,
          ),
        )
        .toList(growable: false);
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
        .map(
          (row) => SessionEvent.fromJson(
            jsonDecode(row['json'] as String) as Map<String, Object?>,
          ),
        )
        .toList(growable: false);
    return (events: events, hasMore: hasMore);
  }

  void dispose() => _db.dispose();

  // -------------------------------------------------------------------------
  // Attachments
  // -------------------------------------------------------------------------

  /// Persists [attachment] for [sessionId], storing its base64 payload as a
  /// BLOB. The caller (the engine) has already validated the base64 and the
  /// size caps; a malformed payload here would surface as a
  /// [FormatException] from `base64Decode`.
  void insertAttachment(String sessionId, AttachmentData attachment) {
    _db.execute(
      'INSERT INTO attachments (id, session_id, name, mime_type, size, data) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      [
        attachment.id,
        sessionId,
        attachment.name,
        attachment.mimeType,
        attachment.size,
        base64Decode(attachment.data),
      ],
    );
  }

  /// The stored attachment of [sessionId] with [attachmentId], or null when
  /// unknown (payload re-encoded to base64).
  AttachmentData? getAttachment(String sessionId, String attachmentId) {
    final rows = _db.select(
      'SELECT id, name, mime_type, size, data FROM attachments '
      'WHERE session_id = ? AND id = ?',
      [sessionId, attachmentId],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return AttachmentData(
      id: row['id'] as String,
      name: row['name'] as String,
      mimeType: row['mime_type'] as String,
      size: row['size'] as int,
      data: base64Encode(row['data'] as List<int>),
    );
  }

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
    models: _models(row['models'] as String?),
    cwd: row['cwd'] as String,
    baseBranch: row['base_branch'] as String?,
    thinkingLevel: row['thinking_level'] as String?,
    thinkingLevels: _thinkingLevels(row['thinking_levels'] as String?),
    yolo: (row['yolo'] as int? ?? 0) != 0,
    archived: (row['archived'] as int) != 0,
    createdAt: _fromTs(row['created_at'] as int),
    updatedAt: _fromTs(row['updated_at'] as int),
  );

  /// Decodes a stored `models` JSON-array string; anything malformed
  /// degrades to an empty list.
  static List<String> _models(String? raw) {
    if (raw == null) return const <String>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.whereType<String>().toList(growable: false);
      }
    } on FormatException {
      // Malformed row; fall through to the empty list.
    }
    return const <String>[];
  }

  /// Decodes a stored `thinking_levels` JSON-array string; anything
  /// malformed degrades to an empty list.
  static List<String> _thinkingLevels(String? raw) {
    if (raw == null) return const <String>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.whereType<String>().toList(growable: false);
      }
    } on FormatException {
      // Malformed row; fall through to the empty list.
    }
    return const <String>[];
  }

  static int _ts(DateTime value) => value.toUtc().microsecondsSinceEpoch;

  static DateTime _fromTs(int value) =>
      DateTime.fromMicrosecondsSinceEpoch(value).toUtc();
}
