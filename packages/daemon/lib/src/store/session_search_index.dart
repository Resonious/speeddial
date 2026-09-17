import 'dart:async';
import 'dart:isolate';

import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

typedef SearchRows = ({List<Map<String, Object?>> rows, bool indexing});

/// A derived, restartable index. The event log remains authoritative.
///
/// Triggers queue work in the same transaction as the source writes. Indexing
/// yields between small batches and persists its position with the documents,
/// so old databases and interrupted backfills need no special startup pass.
class SessionSearchIndex {
  SessionSearchIndex(this._db) {
    _init();
    schedule();
  }

  final Database _db;
  Timer? _timer;
  Object? _error;
  bool _disposed = false;
  // Cache only the event currently spanning batches; its persisted offset
  // prevents duplicate text if indexing is interrupted by a restart.
  Row? _event;
  String? _eventSession;
  static const int _blockSize = 4096;
  // Every permitted query fits across a block boundary, including surrogate
  // pairs. Completed blocks are never rewritten as a conversation grows.
  static const int _overlap = sessionSearchMaxLength;

  void _init() {
    final bool exists = _db
        .select(
          "SELECT 1 FROM sqlite_master WHERE name = 'session_search_state'",
        )
        .isNotEmpty;
    if (exists) return;
    _db.execute('SAVEPOINT search_init');
    try {
      _db.execute('''
        CREATE TABLE session_search_state (
          session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
          indexed_seq INTEGER NOT NULL DEFAULT 0,
          event_offset INTEGER NOT NULL DEFAULT 0,
          last_seq INTEGER NOT NULL DEFAULT 0,
          title_dirty INTEGER NOT NULL DEFAULT 1,
          turn_seq INTEGER NOT NULL DEFAULT 0,
          last_kind TEXT NOT NULL DEFAULT '',
          last_key TEXT NOT NULL DEFAULT ''
        );
        CREATE INDEX session_search_pending
          ON session_search_state(title_dirty DESC, session_id)
          WHERE title_dirty = 1 OR indexed_seq < last_seq;
        CREATE TABLE session_search_documents (
          id INTEGER PRIMARY KEY,
          session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
          message_key TEXT NOT NULL,
          text TEXT NOT NULL
        );
        CREATE INDEX session_search_message
          ON session_search_documents(session_id, message_key, id);
        CREATE INDEX session_search_activity ON sessions(last_activity_at DESC, id DESC);
        CREATE VIRTUAL TABLE session_search_fts USING fts5(
          text, content='session_search_documents', content_rowid='id',
          tokenize='trigram'
        );
        CREATE TRIGGER session_search_document_insert
          AFTER INSERT ON session_search_documents BEGIN
          INSERT INTO session_search_fts(rowid, text) VALUES (new.id, new.text);
        END;
        CREATE TRIGGER session_search_document_delete
          AFTER DELETE ON session_search_documents BEGIN
          INSERT INTO session_search_fts(session_search_fts, rowid, text)
            VALUES ('delete', old.id, old.text);
        END;
        CREATE TRIGGER session_search_document_update
          AFTER UPDATE ON session_search_documents BEGIN
          INSERT INTO session_search_fts(session_search_fts, rowid, text)
            VALUES ('delete', old.id, old.text);
          INSERT INTO session_search_fts(rowid, text) VALUES (new.id, new.text);
        END;
        CREATE TRIGGER session_search_session_insert AFTER INSERT ON sessions BEGIN
          INSERT INTO session_search_state(session_id) VALUES (new.id);
        END;
        CREATE TRIGGER session_search_title_update AFTER UPDATE OF title ON sessions
          WHEN old.title != new.title BEGIN
          UPDATE session_search_state SET title_dirty = 1 WHERE session_id = new.id;
        END;
        CREATE TRIGGER session_search_event_insert AFTER INSERT ON session_events BEGIN
          UPDATE session_search_state SET last_seq = MAX(last_seq, new.seq)
            WHERE session_id = new.session_id;
        END;
        INSERT INTO session_search_state(session_id, last_seq)
          SELECT s.id, COALESCE((SELECT MAX(e.seq) FROM session_events e
            WHERE e.session_id = s.id), 0) FROM sessions s;
      ''');
      _db.execute('RELEASE search_init');
    } on Object {
      _db.execute('ROLLBACK TO search_init');
      _db.execute('RELEASE search_init');
      rethrow;
    }
  }

  void schedule() {
    if (_disposed || _timer != null || _error != null) return;
    _timer = Timer(const Duration(milliseconds: 10), () {
      _timer = null;
      try {
        if (_indexBatch()) schedule();
      } on Object catch (error) {
        // Keep ordinary session persistence usable; search requests report the
        // actual failure instead of returning silently incomplete results.
        _error = error;
      }
    });
  }

  bool _indexBatch() {
    final Stopwatch budget = Stopwatch()..start();
    _db.execute('SAVEPOINT search_batch');
    try {
      int processed = 0;
      while (processed < 64 && budget.elapsedMilliseconds < 8) {
        final ResultSet pending = _db.select('''
          SELECT * FROM session_search_state
          WHERE title_dirty = 1 OR indexed_seq < last_seq
          ORDER BY title_dirty DESC, session_id LIMIT 1
        ''');
        if (pending.isEmpty) {
          _db.execute('RELEASE search_batch');
          return false;
        }
        final Row state = pending.first;
        final String sessionId = state['session_id'] as String;
        if (state['title_dirty'] == 1) {
          _db.execute(
            "DELETE FROM session_search_documents WHERE session_id = ? "
            "AND message_key = 'title'",
            <Object?>[sessionId],
          );
          final String title =
              _db.select('SELECT title FROM sessions WHERE id = ?', <Object?>[
                    sessionId,
                  ]).first['title']
                  as String;
          _appendText(sessionId, 'title', title);
          _db.execute(
            'UPDATE session_search_state SET title_dirty = 0 WHERE session_id = ?',
            <Object?>[sessionId],
          );
          processed++;
          continue;
        }
        // Project text in SQLite, avoiding transfer/decoding of large tool
        // payloads, images, or other non-conversation event JSON into Dart.
        final int offset = state['event_offset'] as int;
        if (offset == 0 || _eventSession != sessionId || _event == null) {
          final ResultSet events = _db.select(
            '''
          SELECT seq, json_extract(json, '\$.type') AS kind,
            json_extract(json, '\$.messageId') AS message_id,
            CASE json_extract(json, '\$.type')
              WHEN 'userMessage' THEN json_extract(json, '\$.text')
              WHEN 'agentMessageChunk' THEN json_extract(json, '\$.text')
              WHEN 'agentThoughtChunk' THEN json_extract(json, '\$.text')
              WHEN 'sessionError' THEN json_extract(json, '\$.message')
            END AS text
          FROM session_events WHERE session_id = ? AND seq > ?
          ORDER BY seq LIMIT 1
        ''',
            <Object?>[sessionId, state['indexed_seq']],
          );
          if (events.isEmpty) {
            _db.execute(
              'UPDATE session_search_state SET indexed_seq = last_seq, event_offset = 0 '
              'WHERE session_id = ?',
              <Object?>[sessionId],
            );
            _event = null;
            continue;
          }
          _event = events.first;
          _eventSession = sessionId;
        }
        final Row event = _event!;
        final int seq = event['seq'] as int;
        final String kind = event['kind'] as String;
        final String? messageId = event['message_id'] as String?;
        int turn = state['turn_seq'] as int;
        if (kind == 'userMessage' || kind == 'turnComplete') turn = seq;
        final bool chunk =
            kind == 'agentMessageChunk' || kind == 'agentThoughtChunk';
        final String key = chunk && messageId != null
            ? '$kind:$turn:id:$messageId'
            : chunk &&
                  state['last_kind'] == kind &&
                  !(state['last_key'] as String).contains(':id:')
            ? state['last_key'] as String
            : '$kind:$seq';
        final String? text = event['text'] as String?;
        final int end = text == null
            ? 0
            : _safeBoundary(text, (offset + _blockSize).clamp(0, text.length));
        if (text != null && end > offset) {
          _appendText(sessionId, key, text.substring(offset, end));
        }
        final bool complete = text == null || end == text.length;
        _db.execute(
          '''
          UPDATE session_search_state SET indexed_seq = ?, event_offset = ?, turn_seq = ?,
            last_kind = ?, last_key = ? WHERE session_id = ?
        ''',
          <Object?>[
            complete ? seq : state['indexed_seq'],
            complete ? 0 : end,
            turn,
            kind,
            key,
            sessionId,
          ],
        );
        if (complete) _event = null;
        processed++;
      }
      _db.execute('RELEASE search_batch');
      return true;
    } on Object {
      _db.execute('ROLLBACK TO search_batch');
      _db.execute('RELEASE search_batch');
      rethrow;
    }
  }

  void _appendText(String sessionId, String key, String text) {
    final ResultSet tail = _db.select(
      '''
      SELECT id, text FROM session_search_documents
      WHERE session_id = ? AND message_key = ? ORDER BY id DESC LIMIT 1
    ''',
      <Object?>[sessionId, key],
    );
    int? id = tail.isEmpty ? null : tail.first['id'] as int;
    String prefix = tail.isEmpty ? '' : tail.first['text'] as String;
    int offset = 0;
    while (offset < text.length) {
      if (prefix.length >= _blockSize - 1) {
        prefix = prefix.substring(
          _safeBoundary(prefix, prefix.length - _overlap),
        );
        id = null;
      }
      final int end = _safeBoundary(
        text,
        (offset + _blockSize - prefix.length).clamp(0, text.length),
      );
      final String block = prefix + text.substring(offset, end);
      if (id == null) {
        _db.execute(
          'INSERT INTO session_search_documents(session_id, message_key, text) '
          'VALUES (?, ?, ?)',
          <Object?>[sessionId, key, block],
        );
      } else {
        _db.execute(
          'UPDATE session_search_documents SET text = ? WHERE id = ?',
          <Object?>[block, id],
        );
      }
      offset = end;
      prefix = block;
      id = null;
    }
  }

  /// Separate read-only connections keep broad MATCH queries off the daemon
  /// (and embedded Flutter) event loop. WAL lets indexing/writes keep moving.
  Future<SearchRows> search({
    required String query,
    String? projectId,
    bool includeArchived = false,
    int limit = 50,
    SessionSearchCursor? cursor,
  }) {
    if (_error != null) return Future<SearchRows>.error(_error!);
    schedule();
    final String path =
        _db.select('PRAGMA database_list').first['file'] as String;
    final SearchRequest request = (
      query: query,
      projectId: projectId,
      includeArchived: includeArchived,
      limit: limit,
      cursor: cursor,
    );
    if (path.isEmpty) return Future<SearchRows>.value(_query(_db, request));
    return _queryInIsolate(path, request);
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }
}

int _safeBoundary(String text, int offset) =>
    offset > 0 &&
        offset < text.length &&
        text.codeUnitAt(offset) >= 0xdc00 &&
        text.codeUnitAt(offset) <= 0xdfff
    ? offset - 1
    : offset;

typedef SearchRequest = ({
  String query,
  String? projectId,
  bool includeArchived,
  int limit,
  SessionSearchCursor? cursor,
});

Future<SearchRows> _queryInIsolate(String path, SearchRequest request) =>
    Isolate.run(() {
      final Database db = sqlite3.open(path, mode: OpenMode.readOnly);
      try {
        db.execute('PRAGMA busy_timeout = 1000');
        db.execute('BEGIN');
        return _query(db, request);
      } finally {
        db.close();
      }
    });

SearchRows _query(Database db, SearchRequest request) {
  final bool indexing = db.select('''
    SELECT 1 FROM session_search_state
    WHERE title_dirty = 1 OR indexed_seq < last_seq LIMIT 1
  ''').isNotEmpty;
  final SessionSearchCursor? cursor = request.cursor;
  // Quoting the entire input makes operators, punctuation, quotes, and SQL
  // wildcard characters literal text. No LIKE fallback scans the transcript.
  final String match = '"${request.query.replaceAll('"', '""')}"';
  // A common phrase may match every message in thousands of sessions. Probe
  // a bounded part of the posting list, then try finding a page in activity
  // order instead of grouping every hit. Sparse/old-only matches retain the
  // normal inverted-index plan below; no path scans source event JSON.
  final ResultSet probe = db.select(
    '''
    SELECT d.session_id FROM session_search_fts f
    JOIN session_search_documents d ON d.id = f.rowid
    WHERE session_search_fts MATCH ? LIMIT 1024
  ''',
    <Object?>[match],
  );
  if (probe.length == 1024 ||
      probe.map((Row row) => row['session_id']).toSet().length >
          request.limit * 2) {
    final List<int>? ids = _recentMatches(db, request, match);
    if (ids != null) {
      final ResultSet rows = db.select('''
        SELECT s.*, p.name AS project_name, d.text AS search_text
        FROM session_search_documents d JOIN sessions s ON s.id = d.session_id
        LEFT JOIN projects p ON p.id = s.project_id
        WHERE d.id IN (${List<String>.filled(ids.length, '?').join(',')})
        ORDER BY s.last_activity_at DESC, s.id DESC
      ''', ids);
      return (
        rows: rows
            .map((Row row) => Map<String, Object?>.of(row))
            .toList(growable: false),
        indexing: indexing,
      );
    }
  }
  final ResultSet rows = db.select(
    '''
    WITH matches AS (
      SELECT d.session_id, MIN(d.id) AS document_id
      FROM session_search_fts f
      JOIN session_search_documents d ON d.id = f.rowid
      JOIN sessions s ON s.id = d.session_id
      WHERE session_search_fts MATCH ?
        ${request.includeArchived ? '' : 'AND s.archived = 0'}
        ${request.projectId == null ? '' : 'AND s.project_id = ?'}
        ${cursor == null ? '' : 'AND (s.last_activity_at, s.id) < (?, ?)'}
      GROUP BY d.session_id
    )
    SELECT s.*, p.name AS project_name, d.text AS search_text
    FROM matches m JOIN sessions s ON s.id = m.session_id
    JOIN session_search_documents d ON d.id = m.document_id
    LEFT JOIN projects p ON p.id = s.project_id
    ORDER BY s.last_activity_at DESC, s.id DESC LIMIT ?
  ''',
    <Object?>[
      match,
      if (request.projectId != null) request.projectId,
      if (cursor != null) ...<Object?>[
        cursor.lastActivityAt.microsecondsSinceEpoch,
        cursor.id,
      ],
      request.limit + 1,
    ],
  );
  return (
    rows: rows
        .map((Row row) => Map<String, Object?>.of(row))
        .toList(growable: false),
    indexing: indexing,
  );
}

/// Returns a complete newest page, or null if a bounded attempt cannot prove
/// that page is complete. In particular, never skip an expensive/old session
/// and return a newer partial page as though no other matches existed.
List<int>? _recentMatches(Database db, SearchRequest request, String match) {
  final SessionSearchCursor? cursor = request.cursor;
  final ResultSet recent = db.select(
    '''
    SELECT s.id FROM sessions s WHERE 1 = 1
      ${request.includeArchived ? '' : 'AND s.archived = 0'}
      ${request.projectId == null ? '' : 'AND s.project_id = ?'}
      ${cursor == null ? '' : 'AND (s.last_activity_at, s.id) < (?, ?)'}
    ORDER BY s.last_activity_at DESC, s.id DESC LIMIT 512
  ''',
    <Object?>[
      if (request.projectId != null) request.projectId,
      if (cursor != null) ...<Object?>[
        cursor.lastActivityAt.microsecondsSinceEpoch,
        cursor.id,
      ],
    ],
  );
  final PreparedStatement size = db.prepare('''
    SELECT COUNT(*) AS n FROM (SELECT id FROM session_search_documents
      WHERE session_id = ? LIMIT 129)
  ''');
  final PreparedStatement hit = db.prepare('''
    SELECT d.id FROM session_search_documents d
    CROSS JOIN session_search_fts f ON f.rowid = d.id
    WHERE d.session_id = ? AND session_search_fts MATCH ? LIMIT 1
  ''');
  try {
    final List<int> ids = <int>[];
    for (final Row session in recent) {
      if ((size.select(<Object?>[session['id']]).first['n'] as int) > 128) {
        // A long session is cheaper to check by intersecting its document-id
        // range with the posting list. Other sessions can be interleaved in
        // that range, so cap the attempt and fall back if it is inconclusive.
        final Row bounds = db
            .select(
              '''
          SELECT MIN(id) AS lo, MAX(id) AS hi FROM session_search_documents
          WHERE session_id = ?
        ''',
              <Object?>[session['id']],
            )
            .first;
        final ResultSet candidates = db.select(
          '''
          SELECT d.id, d.session_id FROM session_search_fts f
          JOIN session_search_documents d ON d.id = f.rowid
          WHERE session_search_fts MATCH ? AND f.rowid >= ? AND f.rowid <= ?
          LIMIT 513
        ''',
          <Object?>[match, bounds['lo'], bounds['hi']],
        );
        final Row? found = candidates
            .where((Row r) => r['session_id'] == session['id'])
            .firstOrNull;
        if (found != null) {
          ids.add(found['id'] as int);
          if (ids.length > request.limit) return ids;
        } else if (candidates.length == 513) {
          return null;
        }
        continue;
      }
      final ResultSet found = hit.select(<Object?>[session['id'], match]);
      if (found.isNotEmpty) ids.add(found.first['id'] as int);
      if (ids.length > request.limit) return ids;
    }
    return recent.length < 512 ? ids : null;
  } finally {
    size.close();
    hit.close();
  }
}
