import 'package:flutter/material.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../scope.dart';
import '../../state/projects_store.dart';
import '../../theme.dart';
import 'new_session_sheet.dart';
import 'session_list.dart';

/// Daemon rail: configured endpoints, then the project/session tree of the
/// selected daemon, plus an "Add daemon" action. Rendered inside the
/// wide-layout rail slot or a drawer on narrow screens.
class LeftRail extends StatelessWidget {
  const LeftRail({super.key});

  @override
  Widget build(BuildContext context) {
    final AppData data = AppScope.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Material(
      color: scheme.surfaceContainer,
      child: ListenableBuilder(
        listenable: Listenable.merge(<Listenable>[data.connections, data.selection]),
        builder: (BuildContext context, Widget? _) {
          final List<DaemonEndpoint> endpoints = data.connections.endpoints;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'Daemons',
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              if (endpoints.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text(
                    'No daemons yet',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                )
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 232),
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    shrinkWrap: true,
                    itemCount: endpoints.length,
                    itemBuilder: (BuildContext context, int index) {
                      final DaemonEndpoint endpoint = endpoints[index];
                      return _EndpointTile(
                        endpoint: endpoint,
                        status: data.connections.statusOf(endpoint.id),
                        selected:
                            data.selection.selectedDaemonId == endpoint.id,
                        onTap: () => _selectDaemon(context, endpoint),
                        onRetry: () => data.reconnect(endpoint.id),
                        onEdit: () => _showDaemonDialog(context, endpoint),
                        onRemove: () => _removeDaemon(context, endpoint),
                      );
                    },
                  ),
                ),
              const Divider(height: 1),
              const Expanded(child: _ProjectTree()),
              Padding(
                // Keep the button above the system navigation area on
                // edge-to-edge Android; the rail surface extends behind it.
                padding: EdgeInsets.fromLTRB(
                    12, 12, 12, 12 + MediaQuery.viewPaddingOf(context).bottom),
                child: OutlinedButton.icon(
                  onPressed: () => _showAddDaemonDialog(context),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add daemon'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Selects [endpoint] and loads its projects/sessions. Failures surface
  /// through the stores (`ProjectsStore.lastError`); selection stays so the
  /// user can retry or switch away.
  static Future<void> _selectDaemon(
    BuildContext context,
    DaemonEndpoint endpoint,
  ) async {
    final AppData data = AppScope.of(context);
    data.selection.selectedDaemonId = endpoint.id;
    data.selection.selectedProjectId = null;
    data.selection.selectedSessionId = null;
    try {
      await data.projects.refresh(endpoint.id);
      await data.sessions.refresh(endpoint.id);
    } on Object catch (e) {
      // Unregistered daemons (e.g. freshly added, not yet wired up) surface
      // here; the stores keep their own errors, the rail stays usable.
      debugPrint('LeftRail: failed to load projects for ${endpoint.id}: $e');
    }
  }

  Future<void> _showAddDaemonDialog(BuildContext context) =>
      _showDaemonDialog(context, null);

  /// Shows the add/edit dialog; [existing] prefills the fields and switches
  /// the submit path to [ConnectionsStore.updateEndpoint].
  Future<void> _showDaemonDialog(BuildContext context,
      [DaemonEndpoint? existing]) {
    // Resolve the store graph on the rail's context; the dialog route's own
    // context sits above [AppScope], so AppScope.of must not run in it.
    final ConnectionsStore connections = AppScope.of(context).connections;
    return showDialog<void>(
      context: context,
      builder: (BuildContext context) =>
          _DaemonDialog(connections: connections, existing: existing),
    );
  }

  Future<void> _removeDaemon(
      BuildContext context, DaemonEndpoint endpoint) async {
    final AppData data = AppScope.of(context);
    final bool confirmed = await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('Remove daemon'),
            content: Text(
                'Remove "${endpoint.name}" (${endpoint.url})? Its sessions and '
                'projects stay on the daemon.'),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const Key('daemon-remove-confirm'),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Remove'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    // Clearing the selection first: the panes key off the selected daemon
    // id, which is about to lose its client.
    if (data.selection.selectedDaemonId == endpoint.id) {
      data.selection.selectedSessionId = null;
      data.selection.selectedProjectId = null;
      data.selection.selectedDaemonId = null;
    }
    await data.connections.removeEndpoint(endpoint.id);
  }
}

/// Projects and sessions of the selected daemon, or an empty-state hint.
///
/// Subscribes to selection, projects and sessions itself so it stays live
/// even though the rail constructs it `const`.
class _ProjectTree extends StatelessWidget {
  const _ProjectTree();

  @override
  Widget build(BuildContext context) {
    final AppData data = AppScope.of(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        data.selection,
        data.projects,
        data.sessions,
      ]),
      builder: (BuildContext context, Widget? _) {
        final String? daemonId = data.selection.selectedDaemonId;
        if (daemonId == null) {
          return Center(
            child: Text(
              'Add a daemon to begin',
              style:
                  textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          );
        }

        final List<Project> projects = data.projects.projectsFor(daemonId);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 4, top: 8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'Projects',
                      style: textTheme.labelMedium
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                  IconButton(
                    key: const Key('add-project'),
                    tooltip: 'Add project',
                    icon: const Icon(Icons.create_new_folder, size: 18),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _showAddProjectDialog(context, daemonId),
                  ),
                ],
              ),
            ),
            if (data.projects.isLoading(daemonId))
              const Expanded(
                child: Center(child: CircularProgressIndicator()),
              )
            else if (projects.isEmpty)
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (data.projects.lastError != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(24, 0, 24, 6),
                          child: Text(
                            _errorText(data.projects.lastError!),
                            textAlign: TextAlign.center,
                            style: textTheme.bodySmall
                                ?.copyWith(color: scheme.error),
                          ),
                        ),
                      Text(
                        'No projects yet',
                        style: textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              )
            else
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 8),
                  children: <Widget>[
                    for (final Project project in projects)
                      _ProjectTile(
                        key: ValueKey<String>('project-${project.id}'),
                        project: project,
                        daemonId: daemonId,
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

String _errorText(Object error) {
  if (error is DaemonError) return error.message;
  if (error is String) return error;
  return error.toString();
}

/// One expandable project row: name/path, new-session action, remove menu,
/// and the session list as its expanded children. Expands whenever the rail
/// selects this project (or the user expands it, which selects it).
///
/// Stateful (instead of forcing a remount via a selection-derived key) so
/// selecting a project expands in place without recreating the session rows.
class _ProjectTile extends StatefulWidget {
  const _ProjectTile({
    super.key,
    required this.project,
    required this.daemonId,
  });

  final Project project;
  final String daemonId;

  @override
  State<_ProjectTile> createState() => _ProjectTileState();
}

class _ProjectTileState extends State<_ProjectTile> {
  final ExpansibleController _controller = ExpansibleController();
  AppData? _data;

  Project get project => widget.project;
  String get daemonId => widget.daemonId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final AppData data = AppScope.of(context);
    if (!identical(_data, data)) {
      _data?.selection.removeListener(_onSelectionChanged);
      _data = data;
      // Selection is a plain store notification, not an inherited-widget
      // change, so react to it directly.
      data.selection.addListener(_onSelectionChanged);
    }
    _scheduleSelectionSync();
  }

  @override
  void dispose() {
    _data?.selection.removeListener(_onSelectionChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onSelectionChanged() => _scheduleSelectionSync();

  /// Mirrors the previous remount-per-selection semantics: the selected
  /// project is expanded, any other project is collapsed. Deferred past the
  /// build phase because [ExpansibleController.expand] may rebuild the tile.
  void _scheduleSelectionSync() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final AppData? data = _data;
      if (data == null) return;
      final String? selected = data.selection.selectedProjectId;
      if (selected == project.id) {
        if (!_controller.isExpanded) _controller.expand();
      } else if (selected != null && _controller.isExpanded) {
        _controller.collapse();
      }
    });
  }

  Future<void> _showNewSessionSheet(BuildContext context) async {
    // Resolve the store graph on the rail's context; the sheet route's own
    // context sits above [AppScope], so AppScope.of must not run in it.
    final AppData data = AppScope.of(context);
    // Captured for reporting a failed initial-prompt send after the sheet
    // route (and its context) is gone.
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (BuildContext context) => Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: NewSessionSheet(
          data: data,
          daemonId: daemonId,
          projectId: project.id,
          messenger: messenger,
        ),
      ),
    );
  }

  Future<void> _removeProject(BuildContext context) async {
    final AppData data = AppScope.of(context);
    final bool confirmed = await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('Remove project'),
            content: Text('Remove "${project.name}" from this daemon?'),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const Key('project-remove-confirm'),
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                ),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Remove'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    await data.projects.remove(daemonId, project.id);
    if (data.selection.selectedProjectId == project.id) {
      data.selection.selectedProjectId = null;
      data.selection.selectedSessionId = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppData data = AppScope.of(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<Session> sessions = data.sessions.sessionsFor(project.id);

    return ExpansionTile(
      key: ValueKey<String>('project-${project.id}'),
      controller: _controller,
      tilePadding: const EdgeInsets.only(left: 8, right: 4),
      childrenPadding: const EdgeInsets.only(bottom: 4),
      shape: const Border(),
      collapsedShape: const Border(),
      title: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              project.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            key: ValueKey<String>('new-session-${project.id}'),
            tooltip: 'New session',
            icon: const Icon(Icons.add_comment, size: 18),
            visualDensity: VisualDensity.compact,
            onPressed: () => _showNewSessionSheet(context),
          ),
          PopupMenuButton<_ProjectAction>(
            tooltip: 'Project actions',
            icon: const Icon(Icons.more_vert, size: 18),
            onSelected: (_ProjectAction action) {
              switch (action) {
                case _ProjectAction.remove:
                  _removeProject(context);
              }
            },
            itemBuilder: (BuildContext context) =>
                const <PopupMenuEntry<_ProjectAction>>[
              PopupMenuItem<_ProjectAction>(
                value: _ProjectAction.remove,
                child: Text('Remove'),
              ),
            ],
          ),
        ],
      ),
      subtitle: Text(
        project.path,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      ),
      onExpansionChanged: (bool expanded) {
        if (expanded) data.selection.selectedProjectId = project.id;
      },
      children: <Widget>[
        SessionList(
          sessions: sessions,
          daemonId: daemonId,
          projectId: project.id,
        ),
      ],
    );
  }
}

enum _ProjectAction { remove }

/// Prompts for an absolute path and adds the project to the daemon.
Future<void> _showAddProjectDialog(BuildContext context, String daemonId) {
  // Resolve the store on the rail's context; the dialog route's own context
  // sits above [AppScope], so AppScope.of must not run in it.
  final ProjectsStore projects = AppScope.of(context).projects;
  return showDialog<void>(
    context: context,
    builder: (BuildContext context) =>
        _AddProjectDialog(projects: projects, daemonId: daemonId),
  );
}

class _AddProjectDialog extends StatefulWidget {
  const _AddProjectDialog({required this.projects, required this.daemonId});

  final ProjectsStore projects;
  final String daemonId;

  @override
  State<_AddProjectDialog> createState() => _AddProjectDialogState();
}

class _AddProjectDialogState extends State<_AddProjectDialog> {
  final TextEditingController _path = TextEditingController();

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final String path = _path.text.trim();
    if (path.isEmpty) return;
    await widget.projects.add(
          widget.daemonId,
          path,
        );
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add project'),
      content: TextField(
        key: const Key('add-project-path'),
        controller: _path,
        autofocus: true,
        onSubmitted: (String _) => _submit(),
        decoration: const InputDecoration(
          labelText: 'Absolute path',
          hintText: '/home/user/code/my-project',
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('add-project-submit'),
          onPressed: _submit,
          child: const Text('Add'),
        ),
      ],
    );
  }
}

/// Menu entries on a daemon endpoint tile.
enum _EndpointAction { retry, edit, remove }

class _EndpointTile extends StatelessWidget {
  const _EndpointTile({
    required this.endpoint,
    required this.status,
    required this.selected,
    required this.onTap,
    required this.onRetry,
    required this.onEdit,
    required this.onRemove,
  });

  final DaemonEndpoint endpoint;
  final ConnectionStatus status;
  final bool selected;
  final VoidCallback onTap;

  /// Resets the reconnect backoff and retries immediately ([AppData.reconnect]).
  final VoidCallback onRetry;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // Retry matters while the endpoint is down or mid-retry; a connected
    // endpoint has nothing to retry.
    final bool canRetry = status == ConnectionStatus.failed ||
        status == ConnectionStatus.reconnecting;
    return ListTile(
      dense: true,
      leading: SizedBox(
        width: 24,
        height: 24,
        child: _StatusDot(color: connectionStatusColor(context, status)),
      ),
      title: Text(
        endpoint.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: textTheme.bodyMedium,
      ),
      subtitle: Text(
        endpoint.url,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      ),
      trailing: PopupMenuButton<_EndpointAction>(
        key: Key('endpoint-actions-${endpoint.id}'),
        tooltip: 'Daemon actions',
        icon: const Icon(Icons.more_vert, size: 18),
        itemBuilder: (BuildContext context) => <PopupMenuEntry<_EndpointAction>>[
          if (canRetry)
            const PopupMenuItem<_EndpointAction>(
              key: Key('endpoint-action-retry'),
              value: _EndpointAction.retry,
              child: Text('Retry now'),
            ),
          const PopupMenuItem<_EndpointAction>(
            value: _EndpointAction.edit,
            child: Text('Edit'),
          ),
          const PopupMenuItem<_EndpointAction>(
            value: _EndpointAction.remove,
            child: Text('Remove'),
          ),
        ],
        onSelected: (_EndpointAction action) => switch (action) {
          _EndpointAction.retry => onRetry(),
          _EndpointAction.edit => onEdit(),
          _EndpointAction.remove => onRemove(),
        },
      ),
      selected: selected,
      selectedTileColor: scheme.surfaceContainerHighest,
      onTap: onTap,
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color),
      ),
    );
  }
}

/// Add-or-edit daemon dialog: with [existing] set, the fields are prefilled
/// and submitting updates the endpoint in place.
class _DaemonDialog extends StatefulWidget {
  const _DaemonDialog({required this.connections, this.existing});

  final ConnectionsStore connections;

  /// The endpoint being edited; null for "add".
  final DaemonEndpoint? existing;

  @override
  State<_DaemonDialog> createState() => _DaemonDialogState();
}

class _DaemonDialogState extends State<_DaemonDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _url = TextEditingController();
  final TextEditingController _token = TextEditingController();
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    final DaemonEndpoint? existing = widget.existing;
    if (existing != null) {
      _name.text = existing.name;
      _url.text = existing.url;
      _token.text = existing.token;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final String url = _url.text.trim();
    final String name = _name.text.trim().isEmpty ? url : _name.text.trim();
    setState(() => _submitting = true);
    final DaemonEndpoint? existing = widget.existing;
    if (existing == null) {
      await widget.connections.addEndpoint(
        name: name,
        url: url,
        token: _token.text.trim(),
      );
    } else {
      await widget.connections.updateEndpoint(
        id: existing.id,
        name: name,
        url: url,
        token: _token.text.trim(),
      );
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final bool editing = widget.existing != null;
    return AlertDialog(
      title: Text(editing ? 'Edit daemon' : 'Add daemon'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextFormField(
              key: const Key('add-daemon-name'),
              controller: _name,
              autofocus: true,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('add-daemon-url'),
              controller: _url,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Host or URL',
                hintText: 'localhost:7331',
              ),
              validator: (String? value) =>
                  (value == null || value.trim().isEmpty)
                      ? 'Host or URL is required'
                      : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('add-daemon-token'),
              controller: _token,
              obscureText: true,
              onFieldSubmitted: (String _) => _submit(),
              decoration: const InputDecoration(labelText: 'Token (optional)'),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('add-daemon-submit'),
          onPressed: _submitting ? null : _submit,
          child: Text(editing ? 'Save' : 'Add'),
        ),
      ],
    );
  }
}
