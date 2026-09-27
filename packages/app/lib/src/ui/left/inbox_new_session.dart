import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../scope.dart';
import 'new_session_sheet.dart';

typedef _SessionLocation = ({String daemonId, String projectId});

/// Asks where to create an Inbox session, then opens the usual session form.
///
/// Resolve [AppData] before opening either route: their builder contexts sit
/// above [AppScope]. The selection changes only after a session is created.
Future<void> showInboxNewSession(
  BuildContext context, {
  VoidCallback? onSessionCreated,
}) async {
  final AppData data = AppScope.of(context);
  final _SessionLocation? location = await showDialog<_SessionLocation>(
    context: context,
    builder: (BuildContext context) => _SessionLocationDialog(data: data),
  );
  if (location == null || !context.mounted) return;

  bool created = false;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (BuildContext context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: NewSessionSheet(
        data: data,
        daemonId: location.daemonId,
        projectId: location.projectId,
        onCreated: () => created = true,
      ),
    ),
  );
  if (created && context.mounted) onSessionCreated?.call();
}

class _SessionLocationDialog extends StatefulWidget {
  const _SessionLocationDialog({required this.data});

  final AppData data;

  @override
  State<_SessionLocationDialog> createState() => _SessionLocationDialogState();
}

class _SessionLocationDialogState extends State<_SessionLocationDialog> {
  String? _daemonId;
  String? _projectId;
  Object? _projectError;

  @override
  void initState() {
    super.initState();
    final List<DaemonEndpoint> endpoints = widget.data.connections.endpoints;
    final String? selected = widget.data.selection.selectedDaemonId;
    _daemonId = endpoints.any((DaemonEndpoint e) => e.id == selected)
        ? selected
        : endpoints.firstOrNull?.id;
    final String? daemonId = _daemonId;
    if (daemonId != null) {
      // ProjectsStore.refresh notifies synchronously when loading begins.
      // Defer it until the dialog's first build has completed.
      scheduleMicrotask(() {
        if (mounted) unawaited(_refreshProjects(daemonId));
      });
    }
  }

  Future<void> _refreshProjects(String daemonId) async {
    await widget.data.projects.refresh(daemonId);
    if (!mounted || _daemonId != daemonId) return;
    final List<Project> projects = widget.data.projects.projectsFor(daemonId);
    setState(() {
      _projectError = widget.data.projects.lastError;
      if (!projects.any((Project project) => project.id == _projectId)) {
        _projectId = null;
      }
    });
  }

  void _selectDaemon(String? daemonId) {
    if (daemonId == null || daemonId == _daemonId) return;
    setState(() {
      _daemonId = daemonId;
      _projectId = null;
      _projectError = null;
    });
    unawaited(_refreshProjects(daemonId));
  }

  @override
  Widget build(BuildContext context) {
    final AppData data = widget.data;
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        data.connections,
        data.projects,
      ]),
      builder: (BuildContext context, Widget? _) {
        final List<DaemonEndpoint> endpoints = data.connections.endpoints;
        final String? daemonId =
            endpoints.any((DaemonEndpoint endpoint) => endpoint.id == _daemonId)
            ? _daemonId
            : null;
        final List<Project> projects = daemonId == null
            ? const <Project>[]
            : data.projects.projectsFor(daemonId);
        final bool loading =
            daemonId != null && data.projects.isLoading(daemonId);
        final String? projectId =
            projects.any((Project project) => project.id == _projectId)
            ? _projectId
            : null;
        final ThemeData theme = Theme.of(context);
        final double contentWidth = math.min(
          360,
          MediaQuery.sizeOf(context).width - 96,
        );

        return AlertDialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 24,
          ),
          title: const Text('New session'),
          content: SizedBox(
            width: contentWidth,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (endpoints.isEmpty)
                  const Text('Add a daemon to create a session.')
                else ...<Widget>[
                  DropdownButtonFormField<String>(
                    key: const Key('inbox-new-session-daemon'),
                    initialValue: daemonId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Daemon'),
                    items: <DropdownMenuItem<String>>[
                      for (final DaemonEndpoint endpoint in endpoints)
                        DropdownMenuItem<String>(
                          value: endpoint.id,
                          child: Text(
                            endpoint.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: _selectDaemon,
                  ),
                  const SizedBox(height: 12),
                  KeyedSubtree(
                    key: ValueKey<String>(
                      'project-${daemonId ?? "none"}-${projectId ?? "none"}',
                    ),
                    child: DropdownButtonFormField<String>(
                      key: const Key('inbox-new-session-project'),
                      initialValue: projectId,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Project'),
                      items: <DropdownMenuItem<String>>[
                        for (final Project project in projects)
                          DropdownMenuItem<String>(
                            value: project.id,
                            child: Text(
                              project.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: projects.isEmpty
                          ? null
                          : (String? value) =>
                                setState(() => _projectId = value),
                    ),
                  ),
                  if (loading) ...<Widget>[
                    const SizedBox(height: 12),
                    const LinearProgressIndicator(),
                  ] else if (projects.isEmpty) ...<Widget>[
                    const SizedBox(height: 12),
                    Text(
                      _projectError == null
                          ? 'No projects on this daemon'
                          : 'Could not load projects',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _projectError == null
                            ? theme.colorScheme.onSurfaceVariant
                            : theme.colorScheme.error,
                      ),
                    ),
                    if (_projectError != null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: daemonId == null
                              ? null
                              : () => unawaited(_refreshProjects(daemonId)),
                          child: const Text('Retry'),
                        ),
                      ),
                  ],
                ],
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('inbox-new-session-continue'),
              onPressed: daemonId == null || projectId == null || loading
                  ? null
                  : () =>
                        Navigator.of(context)
                            .pop((daemonId: daemonId, projectId: projectId)),
              child: const Text('Continue'),
            ),
          ],
        );
      },
    );
  }
}
