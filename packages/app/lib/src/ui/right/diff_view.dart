import 'package:flutter/material.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../theme.dart';

/// GitHub-style colors for unified diff lines.
const Color kDiffAdd = Color(0xFF3FB950);
const Color kDiffRemove = Color(0xFFF85149);
const Color kDiffHunk = Color(0xFF58A6FF);
const Color kDiffMeta = Color(0xFFE3B341);

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
              if (diff.isNew) _badge('new', kDiffAdd),
              if (diff.isDeleted) _badge('deleted', kDiffRemove),
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
                          colors.mono.copyWith(color: _lineColor(line, scheme)),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Color _lineColor(String line, ColorScheme scheme) {
    if (line.startsWith('---') || line.startsWith('+++') || line.startsWith('diff ')) {
      return kDiffMeta;
    }
    if (line.startsWith('@@')) return kDiffHunk;
    if (line.startsWith('+')) return kDiffAdd;
    if (line.startsWith('-')) return kDiffRemove;
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
