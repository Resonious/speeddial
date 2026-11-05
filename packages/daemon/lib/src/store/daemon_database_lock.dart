import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

/// One daemon owns a database at a time, across ports and embedding processes.
///
/// Hold an exclusive SQLite transaction in a separate sidecar so ordinary
/// reads/writes to the session database remain possible. SQLite handles both
/// same-process contention and crash recovery, without PID or stale-file checks.
/// Never delete the sidecar: unlinking a locked file could admit another owner.
class DaemonDatabaseLock {
  DaemonDatabaseLock._(this._database);

  final Database _database;
  bool _closed = false;

  static DaemonDatabaseLock acquire(String path) {
    // Private, in-memory stores cannot be shared by another daemon.
    if (path == ':memory:' || path.isEmpty) {
      return DaemonDatabaseLock._(sqlite3.openInMemory());
    }
    final File file = File(p.absolute(path));
    final String canonicalPath = file.existsSync()
        ? file.resolveSymbolicLinksSync()
        : p.join(file.parent.resolveSymbolicLinksSync(), p.basename(file.path));
    final Database database = sqlite3.open('$canonicalPath.daemon-lock');
    try {
      database.execute('BEGIN EXCLUSIVE');
      return DaemonDatabaseLock._(database);
    } on SqliteException catch (error) {
      database.close();
      // SQLITE_BUSY and SQLITE_LOCKED: preserve actual filesystem/database
      // errors rather than misreporting them as another daemon.
      if (error.resultCode != 5 && error.resultCode != 6) rethrow;
      throw DaemonError(
        kErrConflict,
        'A daemon already owns database "$canonicalPath". '
        'Connect to the running daemon or use a different database.',
      );
    } on Object {
      database.close();
      rethrow;
    }
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    _database.close();
  }
}
