import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../scope.dart';
import '../../state/git_store.dart';
import '../../theme.dart';
import 'diff_view.dart';

/// Git workspace tab: branch picker with ahead/behind chips, staged and
/// unstaged change lists, a per-file unified diff view, and push / merge /
/// rebase actions. Commit and create-PR never run git here: they send the
/// selected session a fixed instruction and let the agent do the work in
/// its own working tree. Reads [GitStore] through [AppScope] and rebuilds
/// from store notifications only.
///
/// The tab follows the selected session: when that session runs in a
/// worktree (created with a base branch), all git operations target the
/// session's working tree via the `sessionId` parameter, not the project
/// checkout. With no session selected the project checkout is shown.
class GitTab extends StatelessWidget {
  const GitTab({super.key});

  @override
  Widget build(BuildContext context) {
    final AppData app = AppScope.of(context);
    return ListenableBuilder(
      listenable:
          Listenable.merge(<Listenable>[app.selection, app.sessions, app.git]),
      builder: (BuildContext context, _) {
        final String? daemonId = app.selection.selectedDaemonId;
        final String? projectId = app.selection.selectedProjectId;
        if (daemonId == null || projectId == null) {
          return const _EmptyHint(
            icon: Icons.account_tree_outlined,
            message: 'No project selected',
          );
        }
        // Only a session of this project scopes the tab; a stale selection
        // pointing elsewhere falls back to the project checkout.
        final String? sessionId = app.selection.selectedSessionId;
        final Session? session =
            sessionId == null ? null : app.sessions.byId(sessionId);
        return _GitPane(
          daemonId: daemonId,
          projectId: projectId,
          sessionId:
              session != null && session.projectId == projectId
                  ? session.id
                  : null,
          sessionBaseBranch: session?.baseBranch,
        );
      },
    );
  }
}

class _GitPane extends StatefulWidget {
  const _GitPane({
    required this.daemonId,
    required this.projectId,
    required this.sessionId,
    required this.sessionBaseBranch,
  });

  final String daemonId;
  final String projectId;

  /// Selected session whose working tree the pane shows; null scopes every
  /// operation to the project checkout.
  final String? sessionId;

  /// Base branch the selected session's worktree was created from; enables
  /// the merge-back and rebase actions. Null without a worktree session.
  final String? sessionBaseBranch;

  @override
  State<_GitPane> createState() => _GitPaneState();
}

class _GitPaneState extends State<_GitPane> {
  late AppData _app;
  String? _loadedKey;
  GitDiff? _openDiff;
  ({String path, bool staged})? _pendingDiff;

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
        oldWidget.daemonId != widget.daemonId ||
        oldWidget.sessionId != widget.sessionId) {
      _loadedKey = null;
      _ensureLoaded();
    }
  }

  /// Kicks one `refresh` per daemon/project/session once the pane is shown.
  ///
  /// The refresh is scheduled (never run synchronously): it fires
  /// notifyListeners, and calling it from `didChangeDependencies`/
  /// `didUpdateWidget` (both inside the build phase) would mark the pane's
  /// own [ListenableBuilder] dirty mid-build (`!_dirty` assertion).
  void _ensureLoaded() {
    final String key =
        '${widget.daemonId}\x00${widget.projectId}\x00${widget.sessionId}';
    if (_loadedKey == key) return;
    _loadedKey = key;
    _openDiff = null;
    _pendingDiff = null;
    scheduleMicrotask(() {
      if (!mounted) return;
      _app.git
          .refresh(widget.daemonId, widget.projectId, sessionId: widget.sessionId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final GitStore git = _app.git;
    final GitStatus? status =
        git.statusFor(widget.projectId, sessionId: widget.sessionId);
    final List<Branch>? branches =
        git.branchesFor(widget.projectId, sessionId: widget.sessionId);
    final Object? error =
        git.errorFor(widget.projectId, sessionId: widget.sessionId);
    final bool busy =
        git.isBusy(widget.projectId, sessionId: widget.sessionId);

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
                icon: const Icon(Icons.copy, size: 16),
                tooltip: 'Copy branch name',
                visualDensity: VisualDensity.compact,
                onPressed: branch == null
                    ? null
                    : () => _copyBranchName(context, branch),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: 'Refresh',
                visualDensity: VisualDensity.compact,
                onPressed: busy
                    ? null
                    : () => _app.git.refresh(widget.daemonId, widget.projectId,
                        sessionId: widget.sessionId),
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
                    color: context.speedDialColors.waitingPermission,
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

  /// Copies [branch] to the clipboard and confirms with a brief SnackBar.
  static void _copyBranchName(BuildContext context, String branch) {
    Clipboard.setData(ClipboardData(text: branch));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied "$branch"'),
        duration: const Duration(seconds: 1),
      ),
    );
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
        sessionId: widget.sessionId,
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

  // --- Footer: error text, commit / push / create-PR actions. -------------

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
          FilledButton(
            onPressed: widget.sessionId == null ? null : _commit,
            child: const Text('Commit'),
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
                  onPressed: widget.sessionId == null ||
                          widget.sessionBaseBranch == null
                      ? null
                      : _createPr,
                  child: const Text('Create PR'),
                ),
              ),
            ],
          ),
          if (widget.sessionId != null && widget.sessionBaseBranch != null) ...[
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: busy ? null : _merge,
                    icon: const Icon(Icons.merge, size: 18),
                    label: Text('Merge into ${widget.sessionBaseBranch}'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: busy ? null : _rebase,
                    icon: const Icon(Icons.linear_scale, size: 18),
                    label: Text('Rebase onto ${widget.sessionBaseBranch}'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static String _errorText(Object error) {
    if (error is DaemonError) return error.message;
    if (error is String) return error;
    return error.toString();
  }

  /// Asks the session's agent to commit its changes: the button sends a
  /// fixed user message instead of running git locally, so the agent writes
  /// the message and stages the files itself.
  Future<void> _commit() => _sendToSession('Please commit your changes');

  /// Sends [text] to the selected session as a user message. Failures
  /// surface in a SnackBar: the git store's `errorFor` only covers
  /// store-run operations, and this bypasses it.
  Future<void> _sendToSession(String text) async {
    final String? sessionId = widget.sessionId;
    if (sessionId == null) return;
    try {
      await _app.chat.send(widget.daemonId, sessionId, text);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_errorText(error)),
          duration: const Duration(seconds: 4),
        ),
      );
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Sent to session: $text'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _push() async {
    try {
      await _app.git
          .push(widget.daemonId, widget.projectId, sessionId: widget.sessionId);
      await _app.git.refresh(widget.daemonId, widget.projectId,
          sessionId: widget.sessionId);
    } catch (_) {
      // Reflected through errorFor.
    }
  }

  Future<void> _merge() async {
    try {
      final MergeResult m = await _app.git.mergeToBase(
          widget.daemonId, widget.projectId, sessionId: widget.sessionId!);
      if (!mounted) return;
      final String text;
      if (m.alreadyUpToDate) {
        text = '${m.baseBranch} is already up to date';
      } else {
        text = 'Merged ${m.sessionBranch} into ${m.baseBranch} '
            '(${m.fastForward ? 'fast-forward' : 'merge commit'})'
            '${m.baseFastForwarded ? ' — ${m.baseBranch} fast-forwarded to origin/${m.baseBranch} first' : ''}';
      }
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(text), duration: const Duration(seconds: 5)));
      await _app.git.refresh(widget.daemonId, widget.projectId,
          sessionId: widget.sessionId);
      // The merge landed on the base branch in the project checkout.
      await _app.git.refresh(widget.daemonId, widget.projectId);
      // The rail badges (ahead → merged) just moved.
      await _app.git.refreshSessionSummaries(widget.daemonId, widget.projectId);
    } catch (_) {
      // Reflected through errorFor.
    }
  }

  Future<void> _rebase() async {
    try {
      final RebaseResult r = await _app.git.rebaseOntoBase(
          widget.daemonId, widget.projectId, sessionId: widget.sessionId!);
      if (!mounted) return;
      final String text;
      if (r.alreadyUpToDate) {
        text = '${r.sessionBranch} is already up to date with ${r.baseBranch}';
      } else {
        text = 'Rebased ${r.sessionBranch} onto ${r.baseBranch}'
            '${r.baseFastForwarded ? ' — ${r.baseBranch} fast-forwarded to origin/${r.baseBranch} first' : ''}';
      }
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(text), duration: const Duration(seconds: 5)));
      await _app.git.refresh(widget.daemonId, widget.projectId,
          sessionId: widget.sessionId);
      if (r.baseFastForwarded) {
        // The base branch moved in the project checkout too — every other
        // worktree on that base is now behind it.
        await _app.git.refresh(widget.daemonId, widget.projectId);
        await _app.git
            .refreshSessionSummaries(widget.daemonId, widget.projectId);
      }
    } catch (_) {
      // Reflected through errorFor.
    }
  }

  Future<void> _checkout(String branch) async {
    try {
      await _app.git.checkout(widget.daemonId, widget.projectId, branch,
          sessionId: widget.sessionId);
      await _app.git.refresh(widget.daemonId, widget.projectId,
          sessionId: widget.sessionId);
      await _app.git
          .refreshSessionSummaries(widget.daemonId, widget.projectId);
    } catch (_) {
      // Reflected through errorFor.
    }
  }

  /// Asks the session's agent to open the PR, naming the worktree's base
  /// branch so the agent targets the right upstream.
  Future<void> _createPr() => _sendToSession(
      'Please create a PR based on ${widget.sessionBaseBranch}');
}

/// Letter + color for a file's porcelain status in the section it appears in.
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.file});

  final GitStatusFile file;

  @override
  Widget build(BuildContext context) {
    final String letter = _letter();
    final Color color = _color(
      letter,
      context.speedDialColors,
      Theme.of(context).colorScheme,
    );
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

  Color _color(String letter, SpeedDialColors colors, ColorScheme scheme) {
    switch (letter) {
      case 'A':
        return colors.success;
      case 'D':
        return colors.diffRemove;
      case 'M':
        return colors.waitingPermission;
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
