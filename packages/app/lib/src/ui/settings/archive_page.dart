import 'package:flutter/material.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../scope.dart';
import '../../state/sessions_store.dart';

/// Daemon-scoped archive storage preview and explicit destructive cleanup.
class ArchivePage extends StatefulWidget {
  const ArchivePage({
    super.key,
    required this.daemonId,
    required this.daemonName,
  });

  final String daemonId;
  final String daemonName;

  @override
  State<ArchivePage> createState() => _ArchivePageState();
}

class _ArchivePageState extends State<ArchivePage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    try {
      await AppScope.of(context).sessions.refreshArchive(widget.daemonId);
    } catch (error) {
      if (mounted) _showMessage(_errorMessage(error));
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _clear(ArchivePreview preview) async {
    final AppData data = AppScope.of(context);
    final List<String> ids = List<String>.of(preview.sessionIds);
    final bool confirmed =
        await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('Clear archive permanently?'),
            scrollable: true,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Delete ${ids.length} archived ${ids.length == 1 ? 'session' : 'sessions'} on ${widget.daemonName}, '
                  'their transcripts and attachments, and ${preview.worktreeCount} ${preview.worktreeCount == 1 ? 'worktree' : 'worktrees'}?',
                ),
                const SizedBox(height: 12),
                const Text(
                  'This includes uncommitted files in those worktrees and cannot be undone.',
                ),
                if (preview.retainedWorktreeCount > 0) ...<Widget>[
                  const SizedBox(height: 12),
                  const Text('Shared and external worktrees will be kept.'),
                ],
              ],
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const Key('clear-archive-confirm'),
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                ),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Delete permanently'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    try {
      final ClearArchiveResult result = await data.sessions.clearArchive(
        widget.daemonId,
        ids,
      );
      if (mounted) {
        _showMessage(
          'Deleted ${result.deletedSessionIds.length} archived sessions and ${result.removedWorktreeCount} worktrees.',
        );
      }
    } catch (error) {
      if (mounted) _showMessage(_errorMessage(error));
    } finally {
      final String? selected = data.selection.selectedSessionId;
      if (data.selection.selectedDaemonId == widget.daemonId &&
          selected != null &&
          data.sessions.sessionOnDaemon(widget.daemonId, selected) == null) {
        data.selection.selectedSessionId = null;
      }
      if (mounted) await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final SessionsStore store = AppScope.of(context).sessions;
    return ListenableBuilder(
      listenable: store,
      builder: (BuildContext context, Widget? child) {
        final ArchivePreview? preview = store.archivePreviewFor(
          widget.daemonId,
        );
        final bool loading = store.isLoadingArchive(widget.daemonId);
        final bool clearing = store.isClearingArchive(widget.daemonId);
        final Object? error = store.archiveErrorFor(widget.daemonId);
        return Scaffold(
          appBar: AppBar(
            title: Text('${widget.daemonName} Archive'),
            actions: <Widget>[
              IconButton(
                key: const Key('archive-refresh'),
                tooltip: 'Refresh storage',
                onPressed: loading || clearing ? null : _refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              Text(
                'Archived sessions',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              const Text(
                'Review stored data on this daemon before clearing the archive.',
              ),
              const SizedBox(height: 20),
              if (loading)
                const Center(
                  child: Column(
                    children: <Widget>[
                      CircularProgressIndicator(),
                      SizedBox(height: 12),
                      Text('Calculating archive storage…'),
                    ],
                  ),
                ),
              if (!loading && error != null && preview == null)
                Text('Could not load archive: ${_errorMessage(error)}'),
              if (!loading && preview != null) ...<Widget>[
                ArchiveUsageCard(preview: preview),
                const SizedBox(height: 16),
                if (preview.sessionIds.isEmpty &&
                    preview.blockedSessions.isEmpty)
                  const Text('The archive is empty.')
                else ...<Widget>[
                  const Text(
                    'Deletion is permanent, including uncommitted worktree files.',
                  ),
                  if (preview.retainedWorktreeCount > 0)
                    Text(
                      '${preview.retainedWorktreeCount} shared or external worktrees will be kept.',
                    ),
                  for (final ArchiveFailure failure in preview.blockedSessions)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Kept ${failure.sessionId}: ${failure.message}',
                      ),
                    ),
                  const SizedBox(height: 20),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      key: const Key('clear-archive'),
                      style: FilledButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.error,
                      ),
                      onPressed: clearing || preview.sessionIds.isEmpty
                          ? null
                          : () => _clear(preview),
                      icon: clearing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.delete_forever_outlined),
                      label: Text(
                        clearing ? 'Clearing archive…' : 'Clear archive',
                      ),
                    ),
                  ),
                ],
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Pure presentation, also usable in the Flutter widget previewer.
class ArchiveUsageCard extends StatelessWidget {
  const ArchiveUsageCard({super.key, required this.preview});
  final ArchivePreview preview;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '${preview.sessionIds.length} ${preview.sessionIds.length == 1 ? 'session' : 'sessions'} ready to delete',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          Text(
            'Estimated storage: ${_formatBytes(preview.totalBytes)}',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 16),
          Text(
            'Worktrees (${preview.worktreeCount}): ${_formatBytes(preview.worktreeBytes)}',
          ),
          Text('Transcripts: ${_formatBytes(preview.transcriptBytes)}'),
          Text('Attachments: ${_formatBytes(preview.attachmentBytes)}'),
          const SizedBox(height: 12),
          Text(
            'Sizes are estimates. Git history is kept. Transcript deletion frees reusable database space; the database file may not shrink.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
  );
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const List<String> units = <String>['KiB', 'MiB', 'GiB', 'TiB'];
  double size = bytes / 1024;
  int unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  return '${size.toStringAsFixed(1)} ${units[unit]}';
}

String _errorMessage(Object error) => switch (error) {
  StateError error => error.message,
  DaemonError error => error.message,
  _ => error.toString(),
};
