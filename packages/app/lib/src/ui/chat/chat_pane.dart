import 'package:flutter/material.dart';

/// Placeholder chat surface. Later phases render the session timeline,
/// composer and permission banner here.
class ChatPane extends StatelessWidget {
  const ChatPane({super.key});

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: Text(
        'Select or create a session',
        style: Theme.of(context)
            .textTheme
            .bodyMedium
            ?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }
}
