/// A notification link to a session on an already configured daemon.
/// Credentials and device-local daemon IDs never appear in the URL.
class SessionLink {
  const SessionLink({required this.sessionId, required this.projectId});

  final String sessionId;
  final String projectId;

  /// Mobile links use SpeedDial's URL scheme. A hosted web app can instead
  /// supply its base URL; existing query parameters and fragments survive.
  Uri toUri({Uri? appUrl}) =>
      (appUrl ?? Uri(scheme: 'speeddial', host: 'session')).replace(
        queryParameters: <String, String>{
          ...?appUrl?.queryParameters,
          'sessionId': sessionId,
          'projectId': projectId,
        },
      );

  static SessionLink? fromUri(Uri uri) {
    final bool mobile =
        uri.scheme == 'speeddial' &&
        uri.host == 'session' &&
        (uri.path.isEmpty || uri.path == '/');
    final bool web = uri.scheme == 'http' || uri.scheme == 'https';
    final bool route = !uri.hasScheme && !uri.hasAuthority;
    if (!mobile && !web && !route) return null;
    final String? sessionId = uri.queryParameters['sessionId'];
    final String? projectId = uri.queryParameters['projectId'];
    if (sessionId == null ||
        projectId == null ||
        _id.stringMatch(sessionId) != sessionId ||
        _id.stringMatch(projectId) != projectId) {
      return null;
    }
    return SessionLink(sessionId: sessionId, projectId: projectId);
  }

  static final RegExp _id = RegExp(r'^[A-Za-z0-9_-]+$');
}
