import 'dart:async';

import 'package:flutter/material.dart';

import '../../scope.dart';
import '../../state/sessions_store.dart';
import 'inbox_new_session.dart';
import 'session_list.dart';

/// Activity-sorted sessions from every configured daemon.
class InboxTab extends StatefulWidget {
  const InboxTab({super.key, this.onSessionCreated});

  final VoidCallback? onSessionCreated;

  @override
  State<InboxTab> createState() => _InboxTabState();
}

class _InboxTabState extends State<InboxTab> {
  AppData? _data;
  final Set<String> _requested = <String>{};
  final Set<String> _loading = <String>{};
  final Map<String, Object> _errors = <String, Object>{};
  final ValueNotifier<int> _loadRevision = ValueNotifier<int>(0);
  bool _refreshScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final AppData data = AppScope.of(context);
    if (!identical(_data, data)) {
      _data?.connections.removeListener(_scheduleRefresh);
      _data = data;
      data.connections.addListener(_scheduleRefresh);
      _requested.clear();
      _loading.clear();
      _errors.clear();
    }
    _scheduleRefresh();
  }

  @override
  void dispose() {
    _data?.connections.removeListener(_scheduleRefresh);
    _loadRevision.dispose();
    super.dispose();
  }

  void _scheduleRefresh() {
    if (_refreshScheduled) return;
    _refreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshScheduled = false;
      if (mounted) _refreshNewEndpoints();
    });
  }

  void _refreshNewEndpoints() {
    final AppData? data = _data;
    if (data == null) return;
    final Set<String> configured = <String>{
      for (final DaemonEndpoint endpoint in data.connections.endpoints)
        endpoint.id,
    };
    _requested.removeWhere((String id) => !configured.contains(id));
    _errors.removeWhere((String id, Object _) => !configured.contains(id));
    for (final String daemonId in configured) {
      // Real WebSocket clients reject requests until the connection handshake
      // finishes. Registered fake clients stay `disconnected` and can be read
      // immediately. The connection listener retries this check on `connected`.
      data.clientFor(daemonId);
      final ConnectionStatus status = data.connections.statusOf(daemonId);
      if (status != ConnectionStatus.connected &&
          status != ConnectionStatus.disconnected) {
        continue;
      }
      if (!_requested.add(daemonId)) continue;
      _loading.add(daemonId);
      unawaited(_loadDaemon(data, daemonId));
    }
    _loadRevision.value++;
  }

  Future<void> _loadDaemon(AppData data, String daemonId) async {
    try {
      await Future.wait<void>(<Future<void>>[
        data.projects.refresh(daemonId),
        data.sessions.refresh(daemonId),
      ]);
      if (!data.projects.hasLoaded(daemonId)) {
        throw data.projects.lastError ?? StateError('Could not load projects');
      }
      _errors.remove(daemonId);
    } on Object catch (error) {
      _errors[daemonId] = error;
    } finally {
      _loading.remove(daemonId);
      if (mounted) _loadRevision.value++;
    }
  }

  void _retryFailed() {
    _requested.removeAll(_errors.keys);
    _errors.clear();
    _refreshNewEndpoints();
  }

  @override
  Widget build(BuildContext context) {
    final AppData data = AppScope.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;

    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        data.connections,
        data.projects,
        data.sessions,
        data.selection,
        _loadRevision,
      ]),
      builder: (BuildContext context, Widget? _) {
        final List<DaemonEndpoint> endpoints = data.connections.endpoints;
        final Set<String> daemonIds = <String>{
          for (final DaemonEndpoint endpoint in endpoints) endpoint.id,
        };
        final List<RecentSession> sessions = data.sessions.recentSessions(
          daemonIds: daemonIds,
        );
        final bool waitingForConnection = endpoints.any((
          DaemonEndpoint endpoint,
        ) {
          final ConnectionStatus status = data.connections.statusOf(
            endpoint.id,
          );
          return status == ConnectionStatus.connecting ||
              status == ConnectionStatus.reconnecting;
        });

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 8, top: 8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'All sessions',
                      style: textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('inbox-new-session'),
                    tooltip: 'New session',
                    icon: const Icon(Icons.add_comment, size: 18),
                    visualDensity: VisualDensity.compact,
                    onPressed: endpoints.isEmpty
                        ? null
                        : () => showInboxNewSession(
                            context,
                            onSessionCreated: widget.onSessionCreated,
                          ),
                  ),
                ],
              ),
            ),
            if (_errors.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        'Could not load ${_errors.length} '
                        '${_errors.length == 1 ? 'daemon' : 'daemons'}',
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.error,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _retryFailed,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: endpoints.isEmpty
                  ? Center(
                      child: Text(
                        'Add a daemon to begin',
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : sessions.isEmpty &&
                        (_loading.isNotEmpty || waitingForConnection)
                  ? const Center(child: CircularProgressIndicator())
                  : sessions.isEmpty
                  ? Center(
                      child: Text(
                        'No sessions',
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : InboxSessionList(
                      sessions: sessions,
                      daemonNames: <String, String>{
                        for (final DaemonEndpoint endpoint in endpoints)
                          endpoint.id: endpoint.name,
                      },
                      projectNames: <String, Map<String, String>>{
                        for (final DaemonEndpoint endpoint in endpoints)
                          endpoint.id: <String, String>{
                            for (final project in data.projects.projectsFor(
                              endpoint.id,
                            ))
                              project.id: project.name,
                          },
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}
