import 'package:flutter/material.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../theme.dart';

IconData _statusIcon(PlanEntryStatus status) => switch (status) {
      PlanEntryStatus.pending => Icons.circle_outlined,
      PlanEntryStatus.inProgress => Icons.play_circle_outline,
      PlanEntryStatus.completed => Icons.check_circle,
    };

Color _statusColor(BuildContext context, PlanEntryStatus status) {
  final SpeedDialColors c = context.speedDialColors;
  return switch (status) {
    PlanEntryStatus.pending => c.idle,
    PlanEntryStatus.inProgress => c.running,
    PlanEntryStatus.completed => c.success,
  };
}

/// Priority dot color: high = error red, medium = amber, low = grey.
Color _priorityColor(BuildContext context, PlanPriority priority) {
  final SpeedDialColors c = context.speedDialColors;
  return switch (priority) {
    PlanPriority.high => c.error,
    PlanPriority.medium => c.waitingPermission,
    PlanPriority.low => c.idle,
  };
}

/// A read-only checklist of the agent's current plan: one row per entry with
/// a status icon, a priority dot, and the step text.
class PlanPanel extends StatelessWidget {
  const PlanPanel({super.key, required this.entries});

  final List<PlanEntry> entries;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.speedDialColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.checklist, size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(
                'Plan',
                style: theme.textTheme.labelLarge
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final PlanEntry entry in entries) _PlanRow(entry: entry),
        ],
      ),
    );
  }
}

class _PlanRow extends StatelessWidget {
  const _PlanRow({required this.entry});

  final PlanEntry entry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            _statusIcon(entry.status),
            size: 16,
            color: _statusColor(context, entry.status),
          ),
          const SizedBox(width: 8),
          Container(
            margin: const EdgeInsets.only(top: 5),
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: _priorityColor(context, entry.priority),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              entry.content,
              style: theme.textTheme.bodySmall?.copyWith(
                decoration:
                    entry.status == PlanEntryStatus.completed
                        ? TextDecoration.lineThrough
                        : null,
                color: entry.status == PlanEntryStatus.completed
                    ? theme.colorScheme.onSurfaceVariant
                    : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
