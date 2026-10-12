@TestOn('vm')
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_daemon/src/daemon_config.dart';
import 'package:test/test.dart';

void main() {
  test(
    'defaults to 72 hours and keeps five sessions, ignoring provider settings',
    () {
      expect(const DaemonConfig().autoArchiveKeep, 5);
      expect(
        DaemonConfig.fromJson(<String, Object?>{
          'providers': <String, Object?>{},
        }).autoArchiveAfter,
        const Duration(hours: 72),
      );
      expect(DaemonConfig.fromJson(<String, Object?>{}).autoArchiveKeep, 5);
    },
  );

  test('accepts custom hours and zero to disable archival', () {
    for (final int hours in <int>[0, 1, 24, 168]) {
      expect(
        DaemonConfig.fromJson(<String, Object?>{'autoArchiveHours': hours})
            .autoArchiveAfter,
        Duration(hours: hours),
      );
    }
  });

  test('rejects invalid and overflowing timeouts', () {
    for (final Object? hours in <Object?>[
      null,
      -1,
      1.5,
      '24',
      false,
      0x7fffffffffffffff,
    ]) {
      expect(
        () =>
            DaemonConfig.fromJson(<String, Object?>{'autoArchiveHours': hours}),
        throwsFormatException,
        reason: 'hours: $hours',
      );
    }
  });

  test('accepts custom keep counts and zero to remove the minimum', () {
    for (final int count in <int>[0, 1, 5, 20]) {
      expect(
        DaemonConfig.fromJson(<String, Object?>{'autoArchiveKeep': count})
            .autoArchiveKeep,
        count,
      );
    }
  });

  test('rejects invalid keep counts', () {
    for (final Object? count in <Object?>[null, -1, 1.5, '5', false]) {
      expect(
        () =>
            DaemonConfig.fromJson(<String, Object?>{'autoArchiveKeep': count}),
        throwsFormatException,
      );
    }
  });

  group('config file', () {
    late Directory directory;
    late File file;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('daemon_config_test');
      file = File(p.join(directory.path, 'config.json'));
    });

    tearDown(() => directory.deleteSync(recursive: true));

    test('missing file uses defaults', () {
      expect(DaemonConfig.load(path: file.path).autoArchiveHours, 72);
      expect(DaemonConfig.load(path: file.path).autoArchiveKeep, 5);
      expect(
        DaemonConfig.load(path: file.path, autoArchiveKeep: 0).autoArchiveKeep,
        0,
      );
    });

    test('reads the configured timeout', () {
      file.writeAsStringSync('{"autoArchiveHours":168,"providers":{}}');
      expect(DaemonConfig.load(path: file.path).autoArchiveHours, 168);
      file.writeAsStringSync('{"autoArchiveHours":0}');
      expect(DaemonConfig.load(path: file.path).autoArchiveHours, 0);
    });

    test('reads the keep count and applies overrides independently', () {
      file.writeAsStringSync('{"autoArchiveHours":168,"autoArchiveKeep":12}');
      final DaemonConfig saved = DaemonConfig.load(path: file.path);
      expect(saved.autoArchiveHours, 168);
      expect(saved.autoArchiveKeep, 12);
      final DaemonConfig hours = DaemonConfig.load(
        path: file.path,
        autoArchiveHours: 24,
      );
      expect(hours.autoArchiveHours, 24);
      expect(hours.autoArchiveKeep, 12);
      final DaemonConfig keep = DaemonConfig.load(
        path: file.path,
        autoArchiveKeep: 2,
      );
      expect(keep.autoArchiveHours, 168);
      expect(keep.autoArchiveKeep, 2);
      final DaemonConfig zero = DaemonConfig.load(
        path: file.path,
        autoArchiveHours: 0,
        autoArchiveKeep: 0,
      );
      expect(zero.autoArchiveHours, 0);
      expect(zero.autoArchiveKeep, 0);
    });

    test(
      'an explicit override replaces an invalid stored value for that setting',
      () {
        file.writeAsStringSync('{"autoArchiveHours":72,"autoArchiveKeep":-1}');
        expect(
          DaemonConfig.load(
            path: file.path,
            autoArchiveKeep: 5,
          ).autoArchiveKeep,
          5,
        );
      },
    );

    test('invalid files fail before archival can start', () {
      for (final String content in <String>[
        '{',
        '[]',
        '{"autoArchiveHours":-1}',
        '{"autoArchiveKeep":-1}',
      ]) {
        file.writeAsStringSync(content);
        expect(() => DaemonConfig.load(path: file.path), throwsFormatException);
      }
    });
  });
}
