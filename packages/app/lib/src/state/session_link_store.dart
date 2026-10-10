import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../api/daemon_client.dart';
import '../api/ws_daemon_client.dart';
import '../scope.dart';
import 'store_base.dart';

typedef _SessionLinkResult = ({
  String daemonId,
  Session? session,
  Object? error,
});

class SessionLinkException implements Exception {
  const SessionLinkException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Resolves notification links using saved daemon connections. Never adds a
/// connection or takes credentials from a link. Only the latest open wins.
class SessionLinkStore extends StoreBase {
  SessionLinkStore(this._data);

  final AppData _data;
  int _request = 0;
  Object? _lastError;
  Object? get lastError => _lastError;

  Future<bool> open(SessionLink link) async {
    final int request = ++_request;
    _lastError = null;
    notifyListeners();
    try {
      final List<_SessionLinkResult>
      results = await Future.wait<_SessionLinkResult>(
        _data.connections.endpoints.map((DaemonEndpoint endpoint) async {
          try {
            final DaemonClient client = _data.clientFor(endpoint.id);
            // On cold launch the initial connection may still be in flight.
            if (client is WsDaemonClient) await client.connect();
            if (isDisposed || _data.isDisposed || request != _request) {
              return (daemonId: endpoint.id, session: null, error: null);
            }
            final List<Session> listed = await client.listSessions(
              projectId: link.projectId,
              includeArchived: true,
            );
            Session? session;
            for (final Session candidate in listed) {
              if (candidate.id == link.sessionId &&
                  candidate.projectId == link.projectId) {
                session = candidate;
                break;
              }
            }
            return (daemonId: endpoint.id, session: session, error: null);
          } on Object catch (error) {
            // Other saved daemons may still resolve the link. Retain failures
            // and surface one if none succeeds.
            return (daemonId: endpoint.id, session: null, error: error);
          }
        }),
      );
      if (isDisposed || _data.isDisposed || request != _request) return false;
      final matches = results
          .where((result) => result.session != null)
          .toList();
      if (matches.length > 1) {
        throw const SessionLinkException(
          'This session exists on multiple daemons. Choose it in the session list.',
        );
      }
      if (matches.isEmpty) {
        for (final result in results) {
          if (result.error != null) throw result.error!;
        }
        throw const SessionLinkException(
          'This session is not available on your configured daemons.',
        );
      }
      final match = matches.single;
      _data.sessions.rememberSearchResult(match.daemonId, match.session!);
      _data.selection.selectSession(
        daemonId: match.daemonId,
        projectId: link.projectId,
        sessionId: link.sessionId,
      );
      return true;
    } on Object catch (error) {
      if (isDisposed || _data.isDisposed || request != _request) return false;
      _lastError = error;
      notifyListeners();
      rethrow;
    }
  }
}
