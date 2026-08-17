@TestOn('vm')
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_daemon/src/server/fs_service.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late FsService fs;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('fs_service_test_');
    fs = FsService();
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } on Object {
      // Cleanup failure is not a test failure.
    }
  });

  void write(String relative, String content) {
    final file = File(p.join(tempDir.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  group('list', () {
    test('lists dirs first then names ascending, skipping .git', () {
      Directory(p.join(tempDir.path, 'sub')).createSync();
      Directory(p.join(tempDir.path, '.git')).createSync();
      write('alpha.txt', 'alpha');
      write('zebra.txt', 'zebra');

      final entries = fs.list(rootPath: tempDir.path);

      expect(entries.map((e) => e.name).toList(),
          <String>['sub', 'alpha.txt', 'zebra.txt']);
      expect(entries.first.isDir, isTrue);
      expect(entries.first.size, 0);
      expect(entries.first.path, 'sub');
      expect(entries.where((e) => e.name == '.git'), isEmpty,
          reason: 'git internals must never surface in listings');
      final alpha = entries.firstWhere((e) => e.name == 'alpha.txt');
      expect(alpha.path, 'alpha.txt');
      expect(alpha.size, 'alpha'.length);
      expect(alpha.isDir, isFalse);
      expect(alpha.modifiedAt.isUtc, isTrue);
    });

    test('lists nested paths with root-relative entry paths', () {
      write('sub/inner.txt', 'inner');
      write('sub/deeper/nested.txt', 'deeper');

      final entries = fs.list(rootPath: tempDir.path, path: 'sub');

      expect(
        entries.map((e) => e.name).toList(),
        <String>['deeper', 'inner.txt'],
      );
      expect(
        entries.map((e) => e.path).toList(),
        <String>['sub/deeper', 'sub/inner.txt'],
      );
    });

    test('rejects non-directories, escapes, and absolute paths with -32602',
        () {
      write('file.txt', 'x');

      for (final path in <String?>['file.txt', '..', '/etc', 'nope']) {
        expect(
          () => fs.list(rootPath: tempDir.path, path: path),
          throwsA(isA<DaemonError>()
              .having((e) => e.code, 'code', -32602)),
          reason: 'expected -32602 for path "$path"',
        );
      }
    });
  });

  group('read', () {
    test('returns utf-8 content unchanged for small files', () {
      write('hello.txt', 'hello wörld\n');

      final result = fs.read(rootPath: tempDir.path, path: 'hello.txt');

      expect(result.content, 'hello wörld\n');
      expect(result.truncated, isFalse);
      expect(result.isBinary, isFalse);
    });

    test('truncates at the default 512 KiB cap', () {
      write('big.txt', 'x' * (600 * 1024));

      final result = fs.read(rootPath: tempDir.path, path: 'big.txt');

      expect(result.truncated, isTrue);
      expect(result.isBinary, isFalse);
      expect(result.content, hasLength(512 * 1024));
    });

    test('honours maxBytes up to the 4 MiB hard cap', () {
      write('mid.txt', 'y' * (900 * 1024));

      final capped = fs.read(
        rootPath: tempDir.path,
        path: 'mid.txt',
        maxBytes: 300 * 1024,
      );
      expect(capped.truncated, isTrue);
      expect(capped.content, hasLength(300 * 1024));

      // Requested 8 MiB on a 5 MiB file: clamped to the 4 MiB hard cap.
      write('huge.txt', 'z' * (5 * 1024 * 1024));
      final hard = fs.read(
        rootPath: tempDir.path,
        path: 'huge.txt',
        maxBytes: 8 * 1024 * 1024,
      );
      expect(hard.truncated, isTrue);
      expect(hard.content, hasLength(4 * 1024 * 1024));
    });

    test('detects binary via a NUL byte in the first 8 KiB', () {
      File(p.join(tempDir.path, 'bin.dat'))
          .writeAsBytesSync(<int>[0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02]);

      final result = fs.read(rootPath: tempDir.path, path: 'bin.dat');

      expect(result.isBinary, isTrue);
      expect(result.content, isEmpty);
      expect(result.truncated, isFalse);
    });

    test('NUL bytes past the 8 KiB probe are not treated as binary', () {
      final bytes = List<int>.filled(16 * 1024, 0x78) // 'x'
        ..[16 * 1024 - 1] = 0;
      File(p.join(tempDir.path, 'late.bin')).writeAsBytesSync(bytes);

      final result = fs.read(rootPath: tempDir.path, path: 'late.bin');

      expect(result.isBinary, isFalse);
      expect(result.content, hasLength(16 * 1024));
      // The trailing NUL round-trips through the lossy UTF-8 decode.
      expect(result.content.codeUnits, contains(0));
    });

    test('rejects escapes, absolute and missing paths with -32602', () {
      write('inside.txt', 'x');
      // A file just outside the root for the escape probe.
      final outside = File(p.join(tempDir.parent.path, 'outside_secret.txt'))
        ..writeAsStringSync('secret');

      for (final bad in <String>[
        '../outside_secret.txt',
        '/etc/hostname',
        'missing.txt',
      ]) {
        expect(
          () => fs.read(rootPath: tempDir.path, path: bad),
          throwsA(isA<DaemonError>()
              .having((e) => e.code, 'code', -32602)),
          reason: 'expected -32602 for $bad',
        );
      }
      // Reading a directory is invalid too.
      expect(
        () => fs.read(rootPath: tempDir.path, path: '.'),
        throwsA(isA<DaemonError>().having((e) => e.code, 'code', -32602)),
      );

      outside.deleteSync();
    });
  });

  group('resolveInRoot', () {
    test('confines nested paths and rejects escapes', () {
      expect(fs.resolveInRoot(tempDir.path, '.'), p.canonicalize(tempDir.path));
      expect(
        fs.resolveInRoot(tempDir.path, 'a/b/../c'),
        p.join(tempDir.path, 'a', 'c'),
      );
      expect(
        () => fs.resolveInRoot(tempDir.path, '..'),
        throwsA(isA<DaemonError>().
            having((e) => e.code, 'code', -32602)),
      );
      expect(
        () => fs.resolveInRoot(tempDir.path, '../../etc'),
        throwsA(isA<DaemonError>().
            having((e) => e.code, 'code', -32602)),
      );
    });
  });

  group('symlink confinement', () {
    late Directory outside;

    setUp(() {
      outside = Directory.systemTemp.createTempSync('fs_outside_');
      File(p.join(outside.path, 'secret.txt')).writeAsStringSync('secret');
    });

    tearDown(() {
      try {
        outside.deleteSync(recursive: true);
      } on Object {
        // Cleanup failure is not a test failure.
      }
    });

    test('rejects a directory symlink pointing outside the root', () {
      Link(p.join(tempDir.path, 'evil')).createSync(outside.path);

      expect(
        () => fs.list(rootPath: tempDir.path, path: 'evil'),
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', -32602)),
        reason: 'listing a symlinked escape must be rejected',
      );
      expect(
        () => fs.read(rootPath: tempDir.path, path: 'evil/secret.txt'),
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', -32602)),
        reason: 'reading through a symlinked escape must be rejected',
      );
    });

    test('rejects a file symlink pointing outside the root', () {
      Link(p.join(tempDir.path, 'leak.txt')).createSync(
          p.join(outside.path, 'secret.txt'));

      expect(
        () => fs.read(rootPath: tempDir.path, path: 'leak.txt'),
        throwsA(isA<DaemonError>()
            .having((e) => e.code, 'code', -32602)),
      );
    });

    test('still allows symlinks that stay inside the root', () {
      write('real.txt', 'inner');
      Link(p.join(tempDir.path, 'alias.txt'))
          .createSync(p.join(tempDir.path, 'real.txt'));

      // The deepest existing ancestor of a missing target under a symlinked
      // dir stays inside (the sibling symlink resolves within the root).
      expect(
        fs.read(rootPath: tempDir.path, path: 'alias.txt').content,
        'inner',
      );

      // Even a *missing* path under an in-root symlinked directory is fine
      // as long as the resolved real ancestor stays inside the root.
      Link(p.join(tempDir.path, 'inroot')).createSync(tempDir.path);
      final resolved =
          fs.resolveInRoot(tempDir.path, 'inroot/not-there-yet.txt');
      expect(resolved, p.join(tempDir.path, 'inroot', 'not-there-yet.txt'));
    });
  });
}
