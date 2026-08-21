import 'package:flutter/material.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../theme.dart';

/// A single-file unified diff rendered line by line in monospace, colored by
/// line prefix. Each line is its own [Text] widget so per-line styling stays
/// trivially testable. Binary diffs render a placeholder instead.
class DiffView extends StatelessWidget {
  const DiffView({super.key, required this.diff});

  final GitDiff diff;

  @override
  Widget build(BuildContext context) {
    final SpeedDialColors colors = context.speedDialColors;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (diff.isBinary) {
      return Center(
        child: Text(
          'Binary file',
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      );
    }
    final List<String> lines =
        diff.patch.split('\n').where((String line) => line.isNotEmpty).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: <Widget>[
              Icon(
                diff.isDeleted
                    ? Icons.delete_outline
                    : (diff.isNew ? Icons.add_circle_outline : Icons.edit_outlined),
                size: 14,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  diff.path,
                  style: colors.mono.copyWith(color: scheme.onSurfaceVariant),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (diff.isNew) _badge('new', colors.success),
              if (diff.isDeleted) _badge('deleted', colors.diffRemove),
            ],
          ),
        ),
        const Divider(height: 1, thickness: 1),
        Expanded(
          child: SelectionArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (final String line in lines)
                    Text(
                      line,
                      style:
                          colors.mono.copyWith(color: _lineColor(line, colors, scheme)),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Color _lineColor(String line, SpeedDialColors colors, ColorScheme scheme) {
    if (line.startsWith('---') || line.startsWith('+++') || line.startsWith('diff ')) {
      return colors.waitingPermission;
    }
    if (line.startsWith('@@')) return colors.running;
    if (line.startsWith('+')) return colors.success;
    if (line.startsWith('-')) return colors.diffRemove;
    return scheme.onSurface;
  }

  Widget _badge(String label, Color color) {
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10, color: color),
      ),
    );
  }
}
