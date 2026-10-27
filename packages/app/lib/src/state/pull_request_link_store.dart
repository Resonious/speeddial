import 'package:flutter/foundation.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../api/daemon_client.dart';
import '../api/ws_daemon_client.dart';
import '../scope.dart';
import 'store_base.dart';

typedef PullRequestMatch = ({DaemonEndpoint daemon, Session session});

/// Shared and dropped links use the same lookup. A later link supersedes an
/// earlier one, and every daemon gets a chance to resolve its own worktrees.
class PullRequestLinkStore extends StoreBase {
  PullRequestLinkStore(this.data);
  final AppData data;
  int _request = 0;
  int _revealRevision = 0;
  int get revealRevision => _revealRevision;
  List<PullRequestMatch> _matches = const <PullRequestMatch>[];
  List<PullRequestMatch> get matches => _matches;

  Future<void> open(String text) async {
    final GithubPrLink? link = GithubPrLink.parse(text);
    if (link == null) return;
    final int request = ++_request;
    _matches = const <PullRequestMatch>[];
    notifyListeners();
    final List<List<PullRequestMatch>> results = await Future.wait(
      data.connections.endpoints.map((DaemonEndpoint endpoint) async {
        try {
          final DaemonClient client = data.clientFor(endpoint.id);
          if (client is WsDaemonClient) {
            await client.connect().timeout(const Duration(seconds: 20));
          }
          final List<Session> sessions = await client
              .findSessionsByPullRequest(link.url)
              .timeout(const Duration(seconds: 20));
          return <PullRequestMatch>[
            for (final Session session in sessions)
              (daemon: endpoint, session: session),
          ];
        } on Object catch (error) {
          // Best-effort link handling is deliberately silent in the UI,
          // including older daemons that don't implement the lookup RPC.
          debugPrint('Warning: PR lookup on ${endpoint.name} failed: $error');
          return <PullRequestMatch>[];
        }
      }),
    );
    if (isDisposed || data.isDisposed || request != _request) return;
    _matches = List<PullRequestMatch>.unmodifiable(results.expand((r) => r));
    if (_matches.isNotEmpty) ++_revealRevision;
    if (_matches.length == 1) {
      select(_matches.single);
    } else {
      notifyListeners();
    }
  }

  void select(PullRequestMatch match) {
    data.sessions.rememberSearchResult(match.daemon.id, match.session);
    data.selection.selectSession(
      daemonId: match.daemon.id,
      projectId: match.session.projectId,
      sessionId: match.session.id,
    );
    dismiss();
  }

  void dismiss() {
    ++_request;
    _matches = const <PullRequestMatch>[];
    notifyListeners();
  }
}
