import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('escapes the title and message', () {
    final String page = oauthCallbackPage(
      title: 'Failed <b>',
      message: '<script>alert(1)</script>',
      tone: OAuthCallbackTone.failure,
    );

    expect(page, isNot(contains('<script>')));
    expect(page, contains('&lt;script&gt;'));
    expect(page, contains('<h1>Failed &lt;b&gt;</h1>'));
  });

  test('marks each tone on the body', () {
    for (final OAuthCallbackTone tone in OAuthCallbackTone.values) {
      final String page = oauthCallbackPage(
        title: 'Title',
        message: 'Message',
        tone: tone,
      );

      expect(page, contains('<body class="${tone.name}">'));
    }
  });

  test('is self-contained and honours theme and motion settings', () {
    final String page = oauthCallbackPage(
      title: 'Title',
      message: 'Message',
      tone: OAuthCallbackTone.success,
    );

    expect(page, contains('prefers-color-scheme: light'));
    expect(page, contains('prefers-reduced-motion: reduce'));
    expect(page, isNot(contains('<script')));
    expect(page, isNot(contains('url(')));
    expect(page, isNot(contains('src=')));
  });
}
