import 'dart:async';

import 'package:flutter/material.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../api/ws_daemon_client.dart';
import '../../scope.dart';
import '../../state/projects_store.dart';
import 'wear_chat.dart';
import 'wear_scaffold.dart';

/// Root navigation for the watch client.
class WearSpeedDialShell extends StatelessWidget {
  const WearSpeedDialShell({super.key});

  @override
  Widget build(BuildContext context) {
    final AppData data = AppScope.of(context);
    return ListenableBuilder(
      listenable: data.connections,
      builder: (BuildContext context, Widget? _) {
        if (data.connections.endpoints.isEmpty) {
          return const WearScaffold(
            title: 'SpeedDial',
            child: WearEmptyState(
              message: 'Add a daemon in SpeedDial on your paired phone',
              icon: Icons.phone_android,
            ),
          );
        }
        return _WearDaemonListPage(data: data);
      },
    );
  }
}

class _WearDaemonListPage extends StatelessWidget {
  const _WearDaemonListPage({required this.data});

  final AppData data;

  @override
  Widget build(BuildContext context) {
    return WearScaffold(
      title: 'SpeedDial',
      child: ListView.builder(
        key: const Key('wear-daemon-list'),
        padding: wearListPadding,
        itemCount: data.connections.endpoints.length,
        itemBuilder: (BuildContext context, int index) {
          final DaemonEndpoint endpoint = data.connections.endpoints[index];
          final ConnectionStatus status = data.connections.statusOf(
            endpoint.id,
          );
          return _WearListTile(
            key: ValueKey<String>('wear-daemon-${endpoint.id}'),
            title: endpoint.name,
            subtitle: _connectionLabel(status),
            leading: _StatusDot(status: status),
            onTap: () {
              data.selection
                ..selectedDaemonId = endpoint.id
                ..selectedProjectId = null
                ..selectedSessionId = null;
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (BuildContext context) =>
                      _WearProjectListPage(data: data, endpoint: endpoint),
                ),
              );
            },
          );
        },
      ),
    );
  }

  static String _connectionLabel(ConnectionStatus status) => switch (status) {
    ConnectionStatus.connected => 'Connected',
    ConnectionStatus.connecting => 'Connecting…',
    ConnectionStatus.reconnecting => 'Reconnecting…',
    ConnectionStatus.failed => 'Tap to retry',
    ConnectionStatus.disconnected => 'Disconnected',
  };
}

class _WearProjectListPage extends StatefulWidget {
  const _WearProjectListPage({required this.data, required this.endpoint});

  final AppData data;
  final DaemonEndpoint endpoint;

  @override
  State<_WearProjectListPage> createState() => _WearProjectListPageState();
}

class _WearProjectListPageState extends State<_WearProjectListPage> {
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      // A newly saved endpoint may still be in its first WebSocket handshake.
      // Join that attempt before issuing projects.list so first navigation
      // does not briefly fail with "client is not connected".
      final client = widget.data.clientFor(widget.endpoint.id);
      if (client is WsDaemonClient && !client.isConnected) {
        await client.connect();
      }
      await widget.data.projects.refresh(widget.endpoint.id);
      _error = widget.data.projects.lastError;
    } on Object catch (error) {
      _error = error;
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final ProjectsStore projects = widget.data.projects;
    return WearScaffold(
      title: widget.endpoint.name,
      showBack: true,
      action: IconButton(
        tooltip: 'Refresh projects',
        padding: EdgeInsets.zero,
        icon: const Icon(Icons.refresh, size: 19),
        onPressed: _loading ? null : _refresh,
      ),
      child: ListenableBuilder(
        listenable: Listenable.merge(<Listenable>[
          projects,
          widget.data.connections,
        ]),
        builder: (BuildContext context, Widget? _) {
          final List<Project> items = projects.projectsFor(widget.endpoint.id);
          final Object? error = _error ?? projects.lastError;
          if (_loading && items.isEmpty) {
            return const Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            );
          }
          if (error != null && items.isEmpty) {
            return WearEmptyState(
              message: 'Could not load projects',
              details: wearErrorText(error),
              icon: Icons.cloud_off,
              action: FilledButton(
                onPressed: _refresh,
                child: const Text('Retry'),
              ),
            );
          }
          if (items.isEmpty) {
            return const WearEmptyState(
              message: 'No projects on this daemon',
              icon: Icons.folder_off_outlined,
            );
          }
          return ListView.builder(
            key: const Key('wear-project-list'),
            padding: wearListPadding,
            itemCount: items.length,
            itemBuilder: (BuildContext context, int index) {
              final Project project = items[index];
              return _WearListTile(
                key: ValueKey<String>('wear-project-${project.id}'),
                title: project.name,
                subtitle: project.path,
                leading: const Icon(Icons.folder_outlined, size: 20),
                onTap: () {
                  widget.data.selection
                    ..selectedProjectId = project.id
                    ..selectedSessionId = null;
                  Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (BuildContext context) => _WearSessionListPage(
                        data: widget.data,
                        daemonId: widget.endpoint.id,
                        project: project,
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

class _WearSessionListPage extends StatefulWidget {
  const _WearSessionListPage({
    required this.data,
    required this.daemonId,
    required this.project,
  });

  final AppData data;
  final String daemonId;
  final Project project;

  @override
  State<_WearSessionListPage> createState() => _WearSessionListPageState();
}

class _WearSessionListPageState extends State<_WearSessionListPage> {
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      await Future.wait<void>(<Future<void>>[
        widget.data.sessions.refresh(
          widget.daemonId,
          projectId: widget.project.id,
        ),
        widget.data.git.refreshSessionSummaries(
          widget.daemonId,
          widget.project.id,
        ),
      ]);
    } on Object catch (error) {
      _error = error;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _newSession() async {
    final Session? session = await Navigator.of(context).push<Session>(
      MaterialPageRoute<Session>(
        builder: (BuildContext context) => _WearNewSessionPage(
          data: widget.data,
          daemonId: widget.daemonId,
          project: widget.project,
        ),
      ),
    );
    if (!mounted || session == null) return;
    _openSession(session);
  }

  void _openSession(Session session) {
    widget.data.selection.selectedSessionId = session.id;
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => WearChatPage(
          data: widget.data,
          daemonId: widget.daemonId,
          sessionId: session.id,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return WearScaffold(
      title: widget.project.name,
      showBack: true,
      action: IconButton(
        key: const Key('wear-new-session'),
        tooltip: 'New session',
        padding: EdgeInsets.zero,
        icon: const Icon(Icons.add_comment_outlined, size: 19),
        onPressed: _newSession,
      ),
      child: ListenableBuilder(
        listenable: Listenable.merge(<Listenable>[
          widget.data.sessions,
          widget.data.git,
        ]),
        builder: (BuildContext context, Widget? _) {
          final List<Session> sessions = widget.data.sessions.sessionsFor(
            widget.project.id,
          );
          if (_loading && sessions.isEmpty) {
            return const Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            );
          }
          if (_error != null && sessions.isEmpty) {
            return WearEmptyState(
              message: 'Could not load sessions',
              icon: Icons.cloud_off,
              action: FilledButton(
                onPressed: _refresh,
                child: const Text('Retry'),
              ),
            );
          }
          if (sessions.isEmpty) {
            return WearEmptyState(
              message: 'No sessions yet',
              icon: Icons.chat_bubble_outline,
              action: FilledButton(
                onPressed: _newSession,
                child: const Text('New session'),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView.builder(
              key: const Key('wear-session-list'),
              padding: wearListPadding,
              itemCount: sessions.length,
              itemBuilder: (BuildContext context, int index) {
                final Session session = sessions[index];
                return _WearListTile(
                  key: ValueKey<String>('wear-session-${session.id}'),
                  title: session.title,
                  subtitle:
                      '${session.providerId} · ${_statusLabel(session.status)}',
                  details: _WearGitState(
                    session: session,
                    summary: widget.data.git.sessionSummaryFor(session.id),
                  ),
                  leading: _SessionStatusIcon(status: session.status),
                  onTap: () => _openSession(session),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _WearNewSessionPage extends StatefulWidget {
  const _WearNewSessionPage({
    required this.data,
    required this.daemonId,
    required this.project,
  });

  final AppData data;
  final String daemonId;
  final Project project;

  @override
  State<_WearNewSessionPage> createState() => _WearNewSessionPageState();
}

class _WearNewSessionPageState extends State<_WearNewSessionPage> {
  late Future<DaemonInfo> _info;
  String? _creatingProvider;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _info = widget.data.clientFor(widget.daemonId).info();
  }

  void _retry() {
    setState(() {
      _error = null;
      _info = widget.data.clientFor(widget.daemonId).info();
    });
  }

  Future<void> _create(ProviderInfo provider) async {
    if (_creatingProvider != null || !provider.available) return;
    setState(() {
      _creatingProvider = provider.id;
      _error = null;
    });
    try {
      final Session session = await widget.data.sessions.create(
        widget.daemonId,
        projectId: widget.project.id,
        providerId: provider.id,
      );
      widget.data.selection.selectedSessionId = session.id;
      if (mounted) Navigator.of(context).pop(session);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _creatingProvider = null;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return WearScaffold(
      title: 'New session',
      showBack: true,
      child: FutureBuilder<DaemonInfo>(
        future: _info,
        builder: (BuildContext context, AsyncSnapshot<DaemonInfo> snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            );
          }
          final List<ProviderInfo> providers =
              snapshot.data?.providers ?? const <ProviderInfo>[];
          if (snapshot.hasError || providers.isEmpty) {
            return WearEmptyState(
              message: 'Could not load providers',
              icon: Icons.cloud_off,
              action: FilledButton(
                onPressed: _retry,
                child: const Text('Retry'),
              ),
            );
          }
          return ListView.builder(
            key: const Key('wear-provider-list'),
            padding: wearListPadding,
            itemCount: providers.length + (_error == null ? 0 : 1),
            itemBuilder: (BuildContext context, int index) {
              if (index == providers.length) {
                return Padding(
                  padding: const EdgeInsets.all(6),
                  child: Text(
                    wearErrorText(_error!),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelSmall
                        ?.copyWith(color: Theme.of(context).colorScheme.error),
                  ),
                );
              }
              final ProviderInfo provider = providers[index];
              final bool creating = _creatingProvider == provider.id;
              return _WearListTile(
                key: ValueKey<String>('wear-provider-${provider.id}'),
                title: provider.name,
                subtitle: provider.available ? 'Start session' : 'Unavailable',
                leading: creating
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.smart_toy_outlined, size: 20),
                onTap: provider.available ? () => _create(provider) : null,
              );
            },
          );
        },
      ),
    );
  }
}

class _WearListTile extends StatelessWidget {
  const _WearListTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.leading,
    this.details,
    this.onTap,
  });

  final String title;
  final String subtitle;
  final Widget leading;
  final Widget? details;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Material(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 54),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                children: <Widget>[
                  SizedBox.square(dimension: 24, child: Center(child: leading)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                        ?details,
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, size: 18),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WearGitState extends StatelessWidget {
  const _WearGitState({required this.session, required this.summary});

  final Session session;
  final SessionGitSummary? summary;

  @override
  Widget build(BuildContext context) {
    final SessionGitSummary? summary = this.summary;
    if (summary == null) return const SizedBox.shrink();
    final int ahead = summary.aheadOfBase ?? 0;
    final int behind = summary.behindBase ?? 0;
    if (summary.dirty != true &&
        ahead == 0 &&
        behind == 0 &&
        summary.mergedIntoBase != true) {
      return const SizedBox.shrink();
    }
    final ColorScheme colors = Theme.of(context).colorScheme;
    final String base = session.baseBranch ?? 'base';
    return Padding(
      key: ValueKey<String>('wear-git-${session.id}'),
      padding: const EdgeInsets.only(top: 3),
      child: Wrap(
        spacing: 3,
        runSpacing: 2,
        children: <Widget>[
          if (summary.dirty == true)
            _WearGitBadge(
              key: ValueKey<String>('wear-git-${session.id}-dirty'),
              label: 'changes',
              tooltip: 'Uncommitted changes',
              color: colors.tertiary,
            ),
          if (ahead > 0)
            _WearGitBadge(
              key: ValueKey<String>('wear-git-${session.id}-ahead'),
              label: '↑$ahead',
              tooltip: '$ahead ahead of $base',
              color: colors.primary,
            ),
          if (behind > 0)
            _WearGitBadge(
              key: ValueKey<String>('wear-git-${session.id}-behind'),
              label: '↓$behind',
              tooltip: '$behind behind $base',
              color: colors.tertiary,
            ),
          if (summary.mergedIntoBase == true)
            _WearGitBadge(
              key: ValueKey<String>('wear-git-${session.id}-merged'),
              label: 'merged',
              tooltip: 'Merged into $base',
              color: Colors.green,
            ),
        ],
      ),
    );
  }
}

class _WearGitBadge extends StatelessWidget {
  const _WearGitBadge({
    super.key,
    required this.label,
    required this.tooltip,
    required this.color,
  });

  final String label;
  final String tooltip;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: color, fontSize: 9, height: 1.15),
          ),
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});

  final ConnectionStatus status;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color color = switch (status) {
      ConnectionStatus.connected => Colors.green,
      ConnectionStatus.connecting ||
      ConnectionStatus.reconnecting => colors.tertiary,
      ConnectionStatus.failed => colors.error,
      ConnectionStatus.disconnected => colors.outline,
    };
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _SessionStatusIcon extends StatelessWidget {
  const _SessionStatusIcon({required this.status});

  final SessionStatus status;

  @override
  Widget build(BuildContext context) {
    final (IconData, Color) appearance = switch (status) {
      SessionStatus.running => (
        Icons.autorenew,
        Theme.of(context).colorScheme.primary,
      ),
      SessionStatus.waitingPermission => (
        Icons.approval_outlined,
        Theme.of(context).colorScheme.tertiary,
      ),
      SessionStatus.error => (
        Icons.error_outline,
        Theme.of(context).colorScheme.error,
      ),
      SessionStatus.closed => (
        Icons.block,
        Theme.of(context).colorScheme.outline,
      ),
      SessionStatus.idle => (
        Icons.chat_bubble_outline,
        Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    };
    return Icon(appearance.$1, size: 19, color: appearance.$2);
  }
}

String _statusLabel(SessionStatus status) => switch (status) {
  SessionStatus.idle => 'Idle',
  SessionStatus.running => 'Running',
  SessionStatus.waitingPermission => 'Approval',
  SessionStatus.error => 'Error',
  SessionStatus.closed => 'Closed',
};
