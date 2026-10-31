import 'package:flutter/material.dart';

import 'catching_up.dart';

/// Keeps saved content readable while explicitly distinguishing offline,
/// refreshing, and failed refresh states. Offline notices never animate.
class HistoryNotice extends StatelessWidget {
  const HistoryNotice({
    super.key,
    required this.offline,
    required this.hasContent,
    required this.updating,
    required this.savedOnly,
    required this.savedComplete,
    required this.failed,
    required this.onRetry,
  });

  final bool offline;
  final bool hasContent;
  final bool updating;
  final bool savedOnly;
  final bool savedComplete;
  final bool failed;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (offline && hasContent) {
      return _Notice(
        icon: Icons.cloud_off_outlined,
        title: 'Offline · Viewing saved messages',
        detail: !savedComplete
            ? 'History may be incomplete. More will load on reconnect.'
            : 'Reconnect to check for newer messages and load details.',
      );
    }
    if (!updating && failed && hasContent) {
      return _Notice(
        icon: Icons.sync_problem_outlined,
        title: 'Could not update conversation',
        detail: 'Your saved messages are still available.',
        action: TextButton(onPressed: onRetry, child: const Text('Retry')),
      );
    }
    return CatchingUpStrip(
      active: updating && !offline,
      label: savedOnly ? 'Updating conversation…' : 'Catching up…',
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.title,
    required this.detail,
    this.action,
  });
  final IconData icon;
  final String title;
  final String detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.bodySmall),
                  Text(
                    detail,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            ?action,
          ],
        ),
      ),
    );
  }
}
