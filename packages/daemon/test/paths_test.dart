import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_daemon/src/paths.dart';
import 'package:test/test.dart';

void main() {
  group('homeDir', () {
    test('reflects \$HOME, else %USERPROFILE%', () {
      final String? env = Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'];
      if (env == null || env.isEmpty) {
        expect(homeDir(), isNull);
      } else {
        expect(homeDir(), env);
      }
    });
  });

  group('expandTilde', () {
    test('expands a bare ~ to the home directory', () {
      expect(expandTilde('~', home: '/home/user'), '/home/user');
    });

    test('expands ~/child against home', () {
      expect(expandTilde('~/code/x', home: '/home/user'),
          p.join('/home/user', 'code', 'x'));
    });

    test('expands a backslash-separated child too', () {
      expect(expandTilde(r'~\code', home: '/home/user'),
          p.join('/home/user', 'code'));
    });

    test('leaves ~user paths unchanged', () {
      expect(expandTilde('~root/x', home: '/home/user'), '~root/x');
    });

    test('passes non-tilde paths through untouched', () {
      expect(expandTilde('/abs/path', home: '/home/user'), '/abs/path');
      expect(expandTilde('rel/path', home: '/home/user'), 'rel/path');
      expect(expandTilde('', home: '/home/user'), '');
    });

    test('falls back to the process home when home is omitted', () {
      final String? home = homeDir();
      if (home == null) {
        expect(expandTilde('~/x'), '~/x');
      } else {
        expect(expandTilde('~/x'), p.join(home, 'x'));
      }
    });
  });
}
