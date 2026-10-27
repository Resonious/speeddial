import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('normalizes PR subpages, query and fragment', () {
    expect(
      GithubPrLink.parse(
        ' https://github.com/org/repo/pull/42/files?diff=split#x ',
      )?.url,
      'https://github.com/org/repo/pull/42',
    );
  });
  test('rejects non-PR links and untrusted hosts/options', () {
    for (final String input in <String>[
      '--help',
      'https://github.com/%ff/repo/pull/1',
      'https://github.com.evil/org/repo/pull/1',
      'https://github.com@evil/org/repo/pull/1',
      'https://user@github.com/org/repo/pull/1',
      'http://github.com/org/repo/pull/1',
      'https://github.com/org/repo/issues/1',
      'https://github.com/org/repo/pull/0',
      'https://github.com/org/repo/pull/nope',
      'https://github.com:444/org/repo/pull/1',
    ]) {
      expect(GithubPrLink.parse(input), isNull, reason: input);
    }
  });
}
