import 'package:flutter/material.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../scope.dart';
import '../../theme.dart';

/// Palette color for a session lifecycle status.
Color sessionStatusColor(SpeedDialColors colors, SessionStatus status) {
  switch (status) {
    case SessionStatus.running:
      return colors.running;
    case SessionStatus.waitingPermission:
      return colors.waitingPermission;
    case SessionStatus.error:
      return colors.error;
    case SessionStatus.closed:
      return colors.closed;
    case SessionStatus.idle:
      return colors.idle;
  }
}

/// Small pill showing a session's lifecycle status, tinted with the status
/// color from the theme.
class SessionStatusChip extends StatelessWidget {
  const SessionStatusChip({super.key, required this.status, this.done = false});

  final SessionStatus status;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final SpeedDialColors colors = context.speedDialColors;
    final Color color = done
        ? colors.success
        : sessionStatusColor(colors, status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        done ? 'Done' : status.name,
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: color, fontSize: 10),
      ),
    );
  }
}

/// Small mono badge carrying a session's provider id.
class ProviderBadge extends StatelessWidget {
  const ProviderBadge({super.key, required this.providerId});

  final String providerId;

  @override
  Widget build(BuildContext context) {
    final SpeedDialColors colors = context.speedDialColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        providerId,
        style: colors.mono.copyWith(fontSize: 10),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// Git-state badges for a session row: "changes" (uncommitted work in the
/// session's cwd), "↑N" (N commits not yet in the base branch), "↓N" (N
/// commits on the base branch the session lacks — its base moved on), and
/// "merged" (all of the session branch's commits are in the base branch).
///
/// Subscribes to [GitStore] itself — summaries refresh on their own
/// schedule (project expansion, turn end, git mutations, the daemon's
/// `git.changed` notifications), so the strip rebuilds without remounting
/// the whole rail. Renders nothing until the first summary for the session
/// arrives, and nothing ever for a session whose git state is all-unknown.
class SessionGitBadges extends StatelessWidget {
  const SessionGitBadges({super.key, required this.session});

  final Session session;

  @override
  Widget build(BuildContext context) {
    final AppData data = AppScope.of(context);
    return ListenableBuilder(
      listenable: data.git,
      builder: (BuildContext context, Widget? _) {
        final SessionGitSummary? summary = data.git.sessionSummaryFor(
          session.id,
        );
        if (summary == null) return const SizedBox.shrink();
        final SpeedDialColors colors = context.speedDialColors;
        final ColorScheme scheme = Theme.of(context).colorScheme;
        final String base = session.baseBranch ?? 'base';
        final int ahead = summary.aheadOfBase ?? 0;
        final int behind = summary.behindBase ?? 0;
        return Wrap(
          spacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            if (summary.dirty ?? false)
              _GitBadge(
                color: colors.waitingPermission,
                label: 'changes',
                tooltip: 'Uncommitted changes',
              ),
            if (ahead > 0)
              _GitBadge(
                color: colors.running,
                label: '↑$ahead',
                tooltip:
                    '$ahead ${ahead == 1 ? 'commit' : 'commits'} '
                    'ahead of $base',
              ),
            if (behind > 0)
              _GitBadge(
                color: colors.waitingPermission,
                label: '↓$behind',
                tooltip:
                    '$behind ${behind == 1 ? 'commit' : 'commits'} '
                    'behind $base (the base moved on)',
              ),
            if (summary.mergedIntoBase ?? false)
              _GitBadge(
                color: scheme.tertiary,
                label: 'merged',
                tooltip: 'Merged into $base',
              ),
          ],
        );
      },
    );
  }
}

/// One tinted pill in the [SessionGitBadges] strip, styled like
/// [SessionStatusChip].
class _GitBadge extends StatelessWidget {
  const _GitBadge({
    required this.color,
    required this.label,
    required this.tooltip,
  });

  final Color color;
  final String label;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(color: color, fontSize: 10),
        ),
      ),
    );
  }
}

/// One session row inside an expanded project: status chip, provider badge,
/// title, and a rename/archive/delete menu. Tapping selects the session.
class SessionRow extends StatelessWidget {
  const SessionRow({
    super.key,
    required this.session,
    required this.selected,
    required this.daemonId,
    required this.projectId,
    this.projectName,
  });

  final Session session;
  final bool selected;
  final String daemonId;
  final String projectId;
  final String? projectName;

  Future<void> _rename(BuildContext context, AppData data) async {
    final String? title = await showDialog<String>(
      context: context,
      builder: (BuildContext context) =>
          _RenameSessionDialog(initialTitle: session.title),
    );
    if (title == null || title.isEmpty) return;
    await data.sessions.rename(daemonId, session.id, title);
  }

  Future<void> _archive(BuildContext context, AppData data) async {
    await data.sessions.archive(daemonId, session.id, true);
  }

  Future<void> _delete(BuildContext context, AppData data) async {
    final bool confirmed =
        await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('Delete session'),
            content: Text('Delete "${session.title}"? This cannot be undone.'),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const Key('session-delete-confirm'),
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                ),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    await data.sessions.delete(daemonId, session.id);
    if (data.selection.selectedSessionId == session.id) {
      // Unpin the chat pane from the dead session (same pattern as the
      // project-removal clearing in left_rail).
      data.selection.selectedSessionId = null;
    }
  }

  String _statusTooltip(BuildContext context, bool done) {
    final String label = done ? 'Done' : session.status.name;
    if (session.status != SessionStatus.idle) return label;

    final DateTime lastActivity = session.lastActivityAt.toLocal();
    final MaterialLocalizations localizations = MaterialLocalizations.of(
      context,
    );
    final String date = localizations.formatFullDate(lastActivity);
    final String time = localizations.formatTimeOfDay(
      TimeOfDay.fromDateTime(lastActivity),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    return '$label\nLast activity: $date at $time';
  }

  @override
  Widget build(BuildContext context) {
    final AppData data = AppScope.of(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool done = data.sessions.isDone(daemonId, session.id);

    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 24, right: 4),
      selected: selected,
      selectedTileColor: scheme.surfaceContainerHighest,
      leading: Tooltip(
        message: _statusTooltip(context, done),
        child: SizedBox(
          width: 22,
          child: Center(
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: done
                    ? context.speedDialColors.success
                    : sessionStatusColor(
                        context.speedDialColors,
                        session.status,
                      ),
              ),
            ),
          ),
        ),
      ),
      title: Text(
        session.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: textTheme.bodySmall?.copyWith(
          color: selected ? scheme.primary : null,
        ),
      ),
      subtitle: Wrap(
        spacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          if (projectName != null)
            Text(
              projectName!,
              style: textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
                fontSize: 10,
              ),
            ),
          ProviderBadge(providerId: session.providerId),
          Text(
            session.mode.name,
            style: textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontSize: 10,
            ),
          ),
          SessionStatusChip(status: session.status, done: done),
          SessionGitBadges(session: session),
        ],
      ),
      trailing: PopupMenuButton<_SessionAction>(
        tooltip: 'Session actions',
        icon: const Icon(Icons.more_vert, size: 18),
        onSelected: (_SessionAction action) {
          switch (action) {
            case _SessionAction.rename:
              _rename(context, data);
            case _SessionAction.archive:
              _archive(context, data);
            case _SessionAction.delete:
              _delete(context, data);
          }
        },
        itemBuilder: (BuildContext context) =>
            const <PopupMenuEntry<_SessionAction>>[
              PopupMenuItem<_SessionAction>(
                value: _SessionAction.rename,
                child: Text('Rename'),
              ),
              PopupMenuItem<_SessionAction>(
                value: _SessionAction.archive,
                child: Text('Archive'),
              ),
              PopupMenuItem<_SessionAction>(
                value: _SessionAction.delete,
                child: Text('Delete'),
              ),
            ],
      ),
      onTap: () {
        data.selection.selectedProjectId = projectId;
        data.selection.selectedSessionId = session.id;
        // On narrow layouts the rail lives in a drawer; selecting a session
        // should dismiss it so the chat is immediately visible. The wide
        // layout has no open drawer, so this is a no-op there.
        final ScaffoldState? scaffold = Scaffold.maybeOf(context);
        if (scaffold != null && scaffold.isDrawerOpen) {
          Navigator.of(context).pop();
        }
      },
    );
  }
}

enum _SessionAction { rename, archive, delete }

/// Pre-filled single-field dialog renaming a session title. Pops with the
/// trimmed new title, or null when cancelled / left empty.
class _RenameSessionDialog extends StatefulWidget {
  const _RenameSessionDialog({required this.initialTitle});

  final String initialTitle;

  @override
  State<_RenameSessionDialog> createState() => _RenameSessionDialogState();
}

class _RenameSessionDialogState extends State<_RenameSessionDialog> {
  late final TextEditingController _title = TextEditingController(
    text: widget.initialTitle,
  );

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _submit() {
    final String title = _title.text.trim();
    if (title.isEmpty) return;
    Navigator.of(context).pop(title);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename session'),
      content: TextField(
        key: const Key('session-rename-field'),
        controller: _title,
        autofocus: true,
        onSubmitted: (String _) => _submit(),
        decoration: const InputDecoration(labelText: 'Title'),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('session-rename-submit'),
          onPressed: _submit,
          child: const Text('Rename'),
        ),
      ],
    );
  }
}

/// Session rows for one project or the rail's cross-project view. When
/// [projectId] is omitted, each row selects its session's own project and
/// [projectNames] can label the rows.
class SessionList extends StatelessWidget {
  const SessionList({
    super.key,
    required this.sessions,
    required this.daemonId,
    this.projectId,
    this.projectNames = const <String, String>{},
    this.now,
  });

  final List<Session> sessions;
  final String daemonId;
  final String? projectId;
  final Map<String, String> projectNames;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final AppData data = AppScope.of(context);
    if (sessions.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 4, 8, 12),
        child: Text(
          'No sessions',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );
    }
    final DateTime localNow = (now ?? DateTime.now()).toLocal();
    final DateTime startOfToday = DateTime(
      localNow.year,
      localNow.month,
      localNow.day,
    );
    final int firstPreviousDay = sessions.indexWhere(
      (Session session) =>
          session.lastActivityAt.toLocal().isBefore(startOfToday),
    );
    final bool showPreviousDaysDivider = firstPreviousDay > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int index = 0; index < sessions.length; index++) ...<Widget>[
          if (showPreviousDaysDivider && index == firstPreviousDay)
            const _SessionDateDivider(label: 'Previous days'),
          SessionRow(
            key: ValueKey<String>('session-${sessions[index].id}'),
            session: sessions[index],
            selected: data.selection.selectedSessionId == sessions[index].id,
            daemonId: daemonId,
            projectId: projectId ?? sessions[index].projectId,
            projectName: projectNames[sessions[index].projectId],
          ),
        ],
      ],
    );
  }
}

class _SessionDateDivider extends StatelessWidget {
  const _SessionDateDivider({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 8, 4),
      child: Row(
        children: <Widget>[
          Expanded(child: Divider(color: scheme.outlineVariant)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(child: Divider(color: scheme.outlineVariant)),
        ],
      ),
    );
  }
}
