@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_daemon/src/store/daemon_database_lock.dart';
import 'package:speeddial_daemon/src/store/daemon_store.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String databasePath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('daemon_database_lock_');
    databasePath = p.join(tempDir.path, 'speeddial.db');
    addTearDown(() => tempDir.deleteSync(recursive: true));
  });

  final conflict = throwsA(
    isA<DaemonError>().having((error) => error.code, 'code', kErrConflict),
  );

  test('same-process daemon stores contend for one database', () {
    final owner = DaemonStore.forDaemon(databasePath);
    addTearDown(owner.dispose);

    expect(() => DaemonStore.forDaemon(databasePath), conflict);
    expect(() => DaemonDatabaseLock.acquire(databasePath), conflict);
  });

  test('independent databases can be owned concurrently', () {
    final first = DaemonStore.forDaemon(databasePath);
    addTearDown(first.dispose);
    final otherPath = p.join(tempDir.path, 'other.db');
    final second = DaemonStore.forDaemon(otherPath);
    addTearDown(second.dispose);

    expect(() => DaemonStore.forDaemon(databasePath), conflict);
    expect(() => DaemonStore.forDaemon(otherPath), conflict);
  });

  test('existing database relative and canonical aliases share ownership', () {
    final owner = DaemonStore.forDaemon(databasePath);
    addTearDown(owner.dispose);
    final canonicalPath = File(databasePath).resolveSymbolicLinksSync();
    final nested = Directory(p.join(tempDir.path, 'nested'))..createSync();
    final alias = '${nested.path}${p.separator}..${p.separator}speeddial.db';

    expect(() => DaemonStore.forDaemon(canonicalPath), conflict);
    expect(() => DaemonStore.forDaemon(alias), conflict);
    // A relative path cannot cross volumes on Windows.
    final relativePath = p.relative(databasePath);
    if (p.isRelative(relativePath)) {
      expect(() => DaemonStore.forDaemon(relativePath), conflict);
    }
  });

  test('graceful close leaves the sidecar and allows reacquisition', () {
    final owner = DaemonStore.forDaemon(databasePath);
    owner.dispose();
    final sidecar = File(
      '${File(databasePath).resolveSymbolicLinksSync()}.daemon-lock',
    );
    expect(sidecar.existsSync(), isTrue);

    final replacement = DaemonStore.forDaemon(databasePath);
    addTearDown(replacement.dispose);
    expect(sidecar.existsSync(), isTrue);
    expect(() => DaemonStore.forDaemon(databasePath), conflict);
  });

  test('disposing a claim twice does not release a later owner', () {
    final first = DaemonDatabaseLock.acquire(databasePath);
    addTearDown(first.dispose);
    first.dispose();
    final second = DaemonDatabaseLock.acquire(databasePath);
    addTearDown(second.dispose);

    first.dispose();
    expect(() => DaemonDatabaseLock.acquire(databasePath), conflict);
  });

  test('failed store creation releases its claim', () {
    // The sidecar is valid, but SQLite cannot open a directory as the main DB.
    final directory = Directory(databasePath)..createSync();
    expect(
      () => DaemonStore.forDaemon(directory.path),
      throwsA(isA<SqliteException>()),
    );

    final claim = DaemonDatabaseLock.acquire(directory.path);
    addTearDown(claim.dispose);
  });

  test(
    'process death releases ownership without deleting the sidecar',
    () async {
      final child = await Process.start(Platform.resolvedExecutable, <String>[
        'test/fixtures/daemon_database_lock_holder.dart',
        databasePath,
      ]);
      final stderrOutput = child.stderr.transform(utf8.decoder).join();
      addTearDown(() async {
        child.kill(ProcessSignal.sigkill);
        await child.exitCode.timeout(const Duration(seconds: 10));
      });
      final ready = await child.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 30));
      expect(ready, 'ready');
      expect(() => DaemonStore.forDaemon(databasePath), conflict);

      expect(child.kill(ProcessSignal.sigkill), isTrue);
      await child.exitCode.timeout(const Duration(seconds: 10));
      expect(await stderrOutput, isEmpty);
      expect(
        File('${File(databasePath).resolveSymbolicLinksSync()}.daemon-lock')
            .existsSync(),
        isTrue,
      );

      final replacement = DaemonStore.forDaemon(databasePath);
      addTearDown(replacement.dispose);
      expect(() => DaemonStore.forDaemon(databasePath), conflict);
    },
  );
}
