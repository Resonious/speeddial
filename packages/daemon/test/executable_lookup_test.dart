import 'package:speeddial_daemon/src/executable_lookup.dart';
import 'package:test/test.dart';

void main() {
  for (final String extension in <String>['exe', 'cmd', 'bat', 'com']) {
    test('Windows finds goose.$extension on PATH', () {
      expect(
        isExecutableResolvable(
          'goose',
          <String, String>{'PATH': r'C:\missing;C:\Program Files\Goose'},
          isWindows: true,
          fileExists: (String path) =>
              path == 'C:\\Program Files\\Goose\\goose.$extension',
        ),
        isTrue,
      );
    });
  }

  test('Windows respects PATHEXT and explicit extensions', () {
    final Map<String, String> environment = <String, String>{
      'PATH': r'C:\bin',
      'PATHEXT': '.CUSTOM',
    };
    bool exists(String path) => path == r'C:\bin\goose.custom';
    for (final String command in <String>['goose', 'goose.custom']) {
      expect(
        isExecutableResolvable(
          command,
          environment,
          isWindows: true,
          fileExists: exists,
        ),
        isTrue,
      );
    }
    expect(
      isExecutableResolvable(
        'goose',
        environment,
        isWindows: true,
        fileExists: (String path) => path == r'C:\bin\goose.exe',
      ),
      isFalse,
    );
  });

  test('POSIX does not append Windows extensions', () {
    for (final String filename in <String>['goose', 'goose.exe']) {
      expect(
        isExecutableResolvable(
          'goose',
          <String, String>{'PATH': '/missing:/bin', 'PATHEXT': '.EXE'},
          isWindows: false,
          fileExists: (String path) => path == '/bin/$filename',
        ),
        filename == 'goose',
      );
    }
  });

  test('absolute paths work without PATH and missing commands do not', () {
    expect(
      isExecutableResolvable(
        r'C:\bin\goose.exe',
        <String, String>{},
        isWindows: true,
        fileExists: (String path) => path == r'C:\bin\goose.exe',
      ),
      isTrue,
    );
    expect(isExecutableResolvable('goose', <String, String>{}), isFalse);
  });
}
