import 'package:flutter/material.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../scope.dart';
import 'file_viewer.dart';

/// Files workspace tab: a lazy, expandable tree rooted at the project root
/// plus a syntax-highlighted viewer for the file opened below it. Reads
/// [FilesStore] through [AppScope]; the tree triggers one `loadDir` per
/// directory on first show and rebuilds from store notifications.
class FilesTab extends StatelessWidget {
  const FilesTab({super.key});

  @override
  Widget build(BuildContext context) {
    final AppData app = AppScope.of(context);
    return ListenableBuilder(
      listenable: app.selection,
      builder: (BuildContext context, _) {
        final String? daemonId = app.selection.selectedDaemonId;
        final String? projectId = app.selection.selectedProjectId;
        if (daemonId == null || projectId == null) {
          return const _EmptyHint(
            icon: Icons.folder_outlined,
            message: 'No project selected',
          );
        }
        return _FilesPane(daemonId: daemonId, projectId: projectId);
      },
    );
  }
}

/// Split pane: file tree on top, the opened file's viewer below it.
class _FilesPane extends StatefulWidget {
  const _FilesPane({required this.daemonId, required this.projectId});

  final String daemonId;
  final String projectId;

  @override
  State<_FilesPane> createState() => _FilesPaneState();
}

class _FilesPaneState extends State<_FilesPane> {
  FileEntry? _openFile;

  @override
  void didUpdateWidget(_FilesPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.projectId != widget.projectId ||
        oldWidget.daemonId != widget.daemonId) {
      _openFile = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final FileEntry? open = _openFile;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          flex: 3,
          child: _FileTree(
            daemonId: widget.daemonId,
            projectId: widget.projectId,
            onFileTap: (FileEntry file) => setState(() => _openFile = file),
          ),
        ),
        if (open != null) const Divider(height: 1, thickness: 1),
        if (open != null)
          Expanded(
            flex: 4,
            child: FileViewer(
              daemonId: widget.daemonId,
              projectId: widget.projectId,
              file: open,
              onClose: () => setState(() => _openFile = null),
            ),
          ),
      ],
    );
  }
}

/// Scrollable lazy tree; the root level lives at path '.'.
class _FileTree extends StatelessWidget {
  const _FileTree({
    required this.daemonId,
    required this.projectId,
    required this.onFileTap,
  });

  final String daemonId;
  final String projectId;
  final ValueChanged<FileEntry> onFileTap;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: _DirList(
        daemonId: daemonId,
        projectId: projectId,
        path: '.',
        depth: 0,
        onFileTap: onFileTap,
      ),
    );
  }
}

/// One directory level of the lazy tree. Requests its listing from the
/// [FilesStore] on first build (or when the project/daemon changes) and
/// shows an inline spinner until `entriesFor` returns data.
class _DirList extends StatefulWidget {
  const _DirList({
    required this.daemonId,
    required this.projectId,
    required this.path,
    required this.depth,
    required this.onFileTap,
  });

  final String daemonId;
  final String projectId;
  final String path;
  final int depth;
  final ValueChanged<FileEntry> onFileTap;

  @override
  State<_DirList> createState() => _DirListState();
}

class _DirListState extends State<_DirList> {
  late AppData _app;
  String? _loadedKey;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _app = AppScope.of(context);
    _ensureLoaded();
  }

  @override
  void didUpdateWidget(_DirList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.projectId != widget.projectId ||
        oldWidget.daemonId != widget.daemonId) {
      _loadedKey = null;
      _ensureLoaded();
    }
  }

  void _ensureLoaded() {
    final String key =
        '${widget.daemonId}\u0000${widget.projectId}\u0000${widget.path}';
    if (_loadedKey == key) return;
    _loadedKey = key;
    if (_app.files.entriesFor(widget.projectId, widget.path) == null) {
      _app.files.loadDir(widget.daemonId, widget.projectId, widget.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _app.files,
      builder: (BuildContext context, _) {
        final List<FileEntry>? entries =
            _app.files.entriesFor(widget.projectId, widget.path);
        final Object? dirError =
            _app.files.dirErrorFor(widget.projectId, widget.path);
        if (entries == null && dirError != null) {
          return _DirErrorRow(
            message: _errorText(dirError),
            onRetry: () => _app.files
                .loadDir(widget.daemonId, widget.projectId, widget.path),
          );
        }
        if (entries == null) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        if (entries.isEmpty) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(28, 8, 12, 8),
            child: Text(
              'Empty folder',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final FileEntry entry in entries)
              _FileRow(
                key: ValueKey<String>('${widget.path}/${entry.path}'),
                daemonId: widget.daemonId,
                projectId: widget.projectId,
                entry: entry,
                depth: widget.depth,
                onFileTap: widget.onFileTap,
              ),
          ],
        );
      },
    );
  }
}

/// One row of the tree: a file opens the viewer, a directory toggles its
/// (lazily loaded) children.
class _FileRow extends StatefulWidget {
  const _FileRow({
    super.key,
    required this.daemonId,
    required this.projectId,
    required this.entry,
    required this.depth,
    required this.onFileTap,
  });

  final String daemonId;
  final String projectId;
  final FileEntry entry;
  final int depth;
  final ValueChanged<FileEntry> onFileTap;

  @override
  State<_FileRow> createState() => _FileRowState();
}

class _FileRowState extends State<_FileRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final FileEntry entry = widget.entry;
    final TextTheme textTheme = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    final Widget leading = Icon(
      entry.isDir ? Icons.folder_outlined : Icons.insert_drive_file_outlined,
      size: 16,
      color: entry.isDir ? scheme.primary : scheme.onSurfaceVariant,
    );
    final Widget title = Text(
      entry.name,
      style: textTheme.bodySmall?.copyWith(color: scheme.onSurface),
      overflow: TextOverflow.ellipsis,
    );
    final Widget? sizeLabel = entry.isDir
        ? null
        : Text(
            _humanizeBytes(entry.size),
            style:
                textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          );
    final EdgeInsets padding = EdgeInsets.only(
      left: 8.0 + widget.depth * 16,
      right: 8,
      top: 4,
      bottom: 4,
    );

    if (!entry.isDir) {
      return InkWell(
        onTap: () => widget.onFileTap(entry),
        child: Padding(
          padding: padding,
          child: Row(
            children: <Widget>[
              leading,
              const SizedBox(width: 8),
              Expanded(child: title),
              ?sizeLabel,
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: padding,
            child: Row(
              children: <Widget>[
                leading,
                const SizedBox(width: 8),
                Expanded(child: title),
                Icon(
                  _expanded ? Icons.expand_more : Icons.chevron_right,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          _DirList(
            daemonId: widget.daemonId,
            projectId: widget.projectId,
            path: entry.path,
            depth: widget.depth + 1,
            onFileTap: widget.onFileTap,
          ),
      ],
    );
  }
}

String _errorText(Object error) {
  if (error is DaemonError) return error.message;
  if (error is String) return error;
  return error.toString();
}

/// Inline row shown when a directory listing failed: the error message plus
/// a retry button (the store keeps no success entry on failure, so without
/// this the tree would spin forever).
class _DirErrorRow extends StatelessWidget {
  const _DirErrorRow({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 8, 12, 8),
      child: Row(
        children: <Widget>[
          Icon(Icons.error_outline, size: 14, color: scheme.error),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.error),
            ),
          ),
          TextButton(
            key: const Key('files-dir-retry'),
            onPressed: onRetry,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

String _humanizeBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const List<String> units = <String>['KB', 'MB', 'GB', 'TB'];
  double value = bytes.toDouble();
  int unit = -1;
  do {
    value /= 1024;
    unit += 1;
  } while (value >= 1024 && unit < units.length - 1);
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 32, color: scheme.onSurfaceVariant),
          const SizedBox(height: 8),
          Text(
            message,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
