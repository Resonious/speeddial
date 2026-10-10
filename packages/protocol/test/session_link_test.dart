import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:test/test.dart';

void main() {
  const SessionLink link = SessionLink(
    sessionId: 'session-123',
    projectId: 'p1',
  );

  test('mobile session links round trip without daemon credentials', () {
    final Uri uri = link.toUri();
    expect(uri.scheme, 'speeddial');
    expect(uri.host, 'session');
    expect(
      uri.queryParameters.keys,
      unorderedEquals(['sessionId', 'projectId']),
    );
    final SessionLink parsed = SessionLink.fromUri(uri)!;
    expect(parsed.sessionId, link.sessionId);
    expect(parsed.projectId, link.projectId);
  });

  test('web links preserve the deployment path, query and fragment', () {
    final Uri uri = link.toUri(
      appUrl: Uri.parse('https://app.example/speeddial/?theme=dark#/'),
    );
    expect(uri.path, '/speeddial/');
    expect(uri.queryParameters['theme'], 'dark');
    expect(uri.fragment, '/');
    expect(SessionLink.fromUri(uri)!.sessionId, 'session-123');
  });

  test('relative Flutter route information can resolve a web link', () {
    expect(
      SessionLink.fromUri(Uri.parse('/?sessionId=session-123&projectId=p1'))!
          .sessionId,
      'session-123',
    );
  });

  test('unrelated and incomplete links are ignored', () {
    for (final String url in <String>[
      'speeddial://other?sessionId=s1&projectId=p1',
      'speeddial://session/other?sessionId=s1&projectId=p1',
      'file:///tmp/?sessionId=s1&projectId=p1',
      'speeddial://session?sessionId=s1',
      'speeddial://session?sessionId=&projectId=p1',
      'speeddial://session?sessionId=..%2Fs1&projectId=p1',
      'speeddial://session?sessionId=s1%0A&projectId=p1',
      '/',
    ]) {
      expect(SessionLink.fromUri(Uri.parse(url)), isNull, reason: url);
    }
  });
}
