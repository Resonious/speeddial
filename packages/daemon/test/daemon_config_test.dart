@TestOn('vm')
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_daemon/src/daemon_config.dart';
import 'package:test/test.dart';

void main() {
  test('defaults to 72 hours and ignores unrelated provider settings', () {
    expect(
      DaemonConfig.fromJson(<String, Object?>{'providers': <String, Object?>{}})
          .autoArchiveAfter,
      const Duration(hours: 72),
    );
  });

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
    });

    test('reads the configured timeout', () {
      file.writeAsStringSync('{"autoArchiveHours":168,"providers":{}}');
      expect(DaemonConfig.load(path: file.path).autoArchiveHours, 168);
      file.writeAsStringSync('{"autoArchiveHours":0}');
      expect(DaemonConfig.load(path: file.path).autoArchiveHours, 0);
    });

    test('invalid files fail before archival can start', () {
      for (final String content in <String>[
        '{',
        '[]',
        '{"autoArchiveHours":-1}',
      ]) {
        file.writeAsStringSync(content);
        expect(() => DaemonConfig.load(path: file.path), throwsFormatException);
      }
    });
  });
}
