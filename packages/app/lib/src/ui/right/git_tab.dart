import 'dart:async';

import 'package:flutter/material.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../scope.dart';
import '../../state/git_store.dart';
import '../../theme.dart';
import 'diff_view.dart';

/// Git workspace tab: branch picker with ahead/behind chips, staged and
/// unstaged change lists, a per-file unified diff view, and a commit field
/// with push / create-PR actions. Reads [GitStore] through [AppScope] and
/// rebuilds from store notifications only.
class GitTab extends StatelessWidget {
  const GitTab({super.key});

  @override
  Widget build(BuildContext context) {
    final AppData app = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[app.selection, app.git]),
      builder: (BuildContext context, _) {
        final String? daemonId = app.selection.selectedDaemonId;
        final String? projectId = app.selection.selectedProjectId;
        if (daemonId == null || projectId == null) {
          return const _EmptyHint(
            icon: Icons.account_tree_outlined,
            message: 'No project selected',
          );
        }
        return _GitPane(daemonId: daemonId, projectId: projectId);
      },
    );
  }
}

class _GitPane extends StatefulWidget {
  const _GitPane({required this.daemonId, required this.projectId});

  final String daemonId;
  final String projectId;

  @override
  State<_GitPane> createState() => _GitPaneState();
}

class _GitPaneState extends State<_GitPane> {
  final TextEditingController _commitController = TextEditingController();
  late AppData _app;
  String? _loadedKey;
  GitDiff? _openDiff;
  ({String path, bool staged})? _pendingDiff;

  @override
  void dispose() {
    _commitController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _app = AppScope.of(context);
    _ensureLoaded();
  }

  @override
  void didUpdateWidget(_GitPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.projectId != widget.projectId ||
        oldWidget.daemonId != widget.daemonId) {
      _loadedKey = null;
      _ensureLoaded();
    }
  }

  /// Kicks one `refresh` per daemon/project once the pane is shown.
  ///
  /// The refresh is scheduled (never run synchronously): it fires
  /// notifyListeners, and calling it from `didChangeDependencies`/
  /// `didUpdateWidget` (both inside the build phase) would mark the pane's
  /// own [ListenableBuilder] dirty mid-build (`!_dirty` assertion).
  void _ensureLoaded() {
    final String key = '${widget.daemonId}\u0000${widget.projectId}';
    if (_loadedKey == key) return;
    _loadedKey = key;
    _openDiff = null;
    _pendingDiff = null;
    scheduleMicrotask(() {
      if (!mounted) return;
      _app.git.refresh(widget.daemonId, widget.projectId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final GitStore git = _app.git;
    final GitStatus? status = git.statusFor(widget.projectId);
    final List<Branch>? branches = git.branchesFor(widget.projectId);
    final Object? error = git.errorFor(widget.projectId);
    final bool busy = git.isBusy(widget.projectId);

    final GitDiff? openDiff = _openDiff;
    final ({String path, bool staged})? pending = _pendingDiff;
    if (openDiff != null || pending != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              IconButton(
                icon: const Icon(Icons.arrow_back, size: 18),
                tooltip: 'Back to changes',
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() {
                  _openDiff = null;
                  _pendingDiff = null;
                }),
              ),
              Expanded(
                child: Text(
                  'Diff',
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
          const Divider(height: 1, thickness: 1),
          Expanded(
            child: pending != null
                ? const Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : DiffView(diff: openDiff!),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildHeader(status, branches, busy),
        Expanded(
          child: status == null
              ? const Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : _buildSections(status),
        ),
        const Divider(height: 1, thickness: 1),
        _buildFooter(error, busy),
      ],
    );
  }

  // --- Header: branch picker, refresh, ahead/behind chips. ----------------

  Widget _buildHeader(GitStatus? status, List<Branch>? branches, bool busy) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String? branch =
        status?.branch ?? _currentBranchName(branches);
    final Widget picker;
    if (branches == null || branches.isEmpty) {
      picker = Text(
        branch ?? '—',
        style: Theme.of(context)
            .speedDialColors
            .mono
            .copyWith(color: scheme.onSurfaceVariant),
        overflow: TextOverflow.ellipsis,
      );
    } else {
      final String value =
          (branch != null && branches.any((Branch b) => b.name == branch))
              ? branch
              : branches.first.name;
      picker = DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isDense: true,
          isExpanded: true,
          onChanged: busy
              ? null
              : (String? name) {
                  if (name != null && name != value) _checkout(name);
                },
          items: <DropdownMenuItem<String>>[
            for (final Branch b in branches)
              DropdownMenuItem<String>(
                value: b.name,
                child: Text(b.name, overflow: TextOverflow.ellipsis),
              ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
          child: Row(
            children: <Widget>[
              Expanded(child: picker),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: 'Refresh',
                visualDensity: VisualDensity.compact,
                onPressed: busy
                    ? null
                    : () => _app.git.refresh(widget.daemonId, widget.projectId),
              ),
            ],
          ),
        ),
        if (status != null && (status.ahead > 0 || status.behind > 0))
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Row(
              children: <Widget>[
                if (status.ahead > 0)
                  _Pill(
                    label: '↑ ${status.ahead}',
                    color: Theme.of(context).colorScheme.primary,
                  ),
                if (status.behind > 0)
                  _Pill(
                    label: '↓ ${status.behind}',
                    color: kDiffMeta,
                  ),
              ],
            ),
          ),
      ],
    );
  }

  static String? _currentBranchName(List<Branch>? branches) {
    if (branches == null) return null;
    for (final Branch b in branches) {
      if (b.isCurrent) return b.name;
    }
    return null;
  }

  // --- Change lists. -------------------------------------------------------

  Widget _buildSections(GitStatus status) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    if (status.files.isEmpty) {
      return Center(
        child: Text(
          'No changes',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      );
    }
    final List<GitStatusFile> staged = <GitStatusFile>[
      for (final GitStatusFile f in status.files)
        if (f.staged) f,
    ];
    final List<GitStatusFile> unstaged = <GitStatusFile>[
      for (final GitStatusFile f in status.files)
        if (!f.staged) f,
    ];
    return ListView(
      children: <Widget>[
        if (staged.isNotEmpty) _sectionHeader('Staged', scheme),
        for (final GitStatusFile f in staged) _fileRow(f),
        if (unstaged.isNotEmpty) _sectionHeader('Unstaged', scheme),
        for (final GitStatusFile f in unstaged) _fileRow(f),
      ],
    );
  }

  Widget _sectionHeader(String label, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Text(
        label,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }

  Widget _fileRow(GitStatusFile file) {
    final SpeedDialColors colors = context.speedDialColors;
    return InkWell(
      onTap: () => _openDiffFor(file),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        child: Row(
          children: <Widget>[
            _StatusBadge(file: file),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                file.path,
                style: colors.mono.copyWith(
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openDiffFor(GitStatusFile file) async {
    setState(() => _pendingDiff = (path: file.path, staged: file.staged));
    try {
      final List<GitDiff> diffs = await _app.git.diff(
        widget.daemonId,
        widget.projectId,
        path: file.path,
        staged: file.staged,
      );
      if (!mounted || _pendingDiff == null) return;
      setState(() {
        _openDiff = diffs.isEmpty ? null : diffs.first;
        _pendingDiff = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _pendingDiff = null);
    }
  }

  // --- Footer: error text, commit field, push / create PR. -----------------

  Widget _buildFooter(Object? error, bool busy) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                _errorText(error),
                style: TextStyle(color: scheme.error, fontSize: 12),
              ),
            ),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _commitController,
                  enabled: !busy,
                  decoration: const InputDecoration(hintText: 'Commit message'),
                  onSubmitted: (_) => _commit(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: busy ? null : _commit,
                child: const Text('Commit'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton(
                  onPressed: busy ? null : _push,
                  child: const Text('Push'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: busy ? null : _createPr,
                  child: const Text('Create PR'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _errorText(Object error) {
    if (error is DaemonError) return error.message;
    if (error is String) return error;
    return error.toString();
  }

  Future<void> _commit() async {
    final GitStore git = _app.git;
    final String message = _commitController.text;
    try {
      await git.commit(widget.daemonId, widget.projectId, message, stageAll: true);
    } catch (_) {
      // The store recorded the failure in errorFor; keep the message in the
      // field so the user can fix it.
      return;
    }
    if (git.errorFor(widget.projectId) != null) return;
    _commitController.clear();
    await git.refresh(widget.daemonId, widget.projectId);
  }

  Future<void> _push() async {
    try {
      await _app.git.push(widget.daemonId, widget.projectId);
      await _app.git.refresh(widget.daemonId, widget.projectId);
    } catch (_) {
      // Reflected through errorFor.
    }
  }

  Future<void> _checkout(String branch) async {
    try {
      await _app.git.checkout(widget.daemonId, widget.projectId, branch);
      await _app.git.refresh(widget.daemonId, widget.projectId);
    } catch (_) {
      // Reflected through errorFor.
    }
  }

  Future<void> _createPr() async {
    final _CreatePrRequest? request = await showDialog<_CreatePrRequest>(
      context: context,
      builder: (BuildContext _) => const _CreatePrDialog(),
    );
    if (request == null || !mounted) return;
    try {
      final String url = await _app.git.createPr(
        widget.daemonId,
        widget.projectId,
        title: request.title.isEmpty ? null : request.title,
        body: request.body.isEmpty ? null : request.body,
        base: request.base.isEmpty ? null : request.base,
        draft: request.draft,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(url), duration: const Duration(seconds: 5)),
      );
    } catch (_) {
      // Reflected through errorFor.
    }
  }
}

/// Letter + color for a file's porcelain status in the section it appears in.
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.file});

  final GitStatusFile file;

  @override
  Widget build(BuildContext context) {
    final String letter = _letter();
    final Color color = _color(letter, Theme.of(context).colorScheme);
    return Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        letter,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          fontFamily: 'monospace',
          color: color,
        ),
      ),
    );
  }

  /// The porcelain char that matters here: the index char for staged rows,
  /// the worktree char for unstaged ones.
  String _letter() {
    final String code = file.staged ? file.indexStatus : file.worktreeStatus;
    if (code.isEmpty || code == '.') return '?';
    final String c = code[0].toUpperCase();
    return 'MADRUCT?'.contains(c) ? c : '?';
  }

  Color _color(String letter, ColorScheme scheme) {
    switch (letter) {
      case 'A':
        return kDiffAdd;
      case 'D':
        return kDiffRemove;
      case 'M':
        return kDiffMeta;
      default:
        return scheme.onSurfaceVariant;
    }
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontFamily: 'monospace',
          color: color,
        ),
      ),
    );
  }
}

class _CreatePrRequest {
  const _CreatePrRequest({
    required this.title,
    required this.body,
    required this.base,
    required this.draft,
  });

  final String title;
  final String body;
  final String base;
  final bool draft;
}

/// Form dialog for creating a pull request: title/body/base plus a draft
/// toggle. Popped with the entered values; the caller performs the actual
/// `createPr` call (threading `draft` through to the daemon).
class _CreatePrDialog extends StatefulWidget {
  const _CreatePrDialog();

  @override
  State<_CreatePrDialog> createState() => _CreatePrDialogState();
}

class _CreatePrDialogState extends State<_CreatePrDialog> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _body = TextEditingController();
  final TextEditingController _base = TextEditingController();
  bool _draft = false;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    _base.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create Pull Request'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextFormField(
                controller: _title,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Title'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _body,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(labelText: 'Body'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _base,
                decoration: const InputDecoration(labelText: 'Base branch'),
              ),
              const SizedBox(height: 4),
              CheckboxListTile(
                value: _draft,
                onChanged: (bool? value) => setState(() => _draft = value ?? false),
                title: const Text('Draft'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            _CreatePrRequest(
              title: _title.text,
              body: _body.text,
              base: _base.text,
              draft: _draft,
            ),
          ),
          child: const Text('Create'),
        ),
      ],
    );
  }
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
