import 'package:flutter/material.dart';

/// Less frequent conversation actions stay out of the model controls.
class AnteControls extends StatelessWidget {
  const AnteControls({
    super.key,
    required this.enabled,
    required this.onRewind,
    required this.onFork,
  });
  final bool enabled;
  final VoidCallback onRewind;
  final VoidCallback onFork;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 32,
    child: PopupMenuButton<String>(
      tooltip: 'Conversation actions',
      enabled: enabled,
      padding: EdgeInsets.zero,
      icon: Icon(
        Icons.more_horiz,
        size: 18,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      onSelected: (value) => value == 'rewind' ? onRewind() : onFork(),
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: 'rewind',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.undo, size: 18),
            title: Text('Rewind last turn'),
          ),
        ),
        PopupMenuItem(
          value: 'fork',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.fork_right, size: 18),
            title: Text('Fork conversation'),
          ),
        ),
      ],
    ),
  );
}
