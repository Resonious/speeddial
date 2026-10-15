import 'package:flutter/material.dart';

/// Visible entry points for the same session operations as the slash menu.
class AnteControls extends StatelessWidget {
  const AnteControls({
    super.key,
    required this.enabled,
    required this.onProvider,
    required this.onRewind,
    required this.onFork,
  });

  final bool enabled;
  final VoidCallback onProvider;
  final VoidCallback onRewind;
  final VoidCallback onFork;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        tooltip: 'Switch provider',
        onPressed: enabled ? onProvider : null,
        icon: const Icon(Icons.swap_horiz, size: 18),
      ),
      IconButton(
        tooltip: 'Rewind last turn',
        onPressed: enabled ? onRewind : null,
        icon: const Icon(Icons.undo, size: 18),
      ),
      IconButton(
        tooltip: 'Fork conversation',
        onPressed: enabled ? onFork : null,
        icon: const Icon(Icons.fork_right, size: 18),
      ),
    ],
  );
}

class AnteProviderDialog extends StatefulWidget {
  const AnteProviderDialog({super.key, required this.providers});
  final List<String> providers;

  @override
  State<AnteProviderDialog> createState() => _AnteProviderDialogState();
}

class _AnteProviderDialogState extends State<AnteProviderDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _select(String value) {
    if (value.trim().isNotEmpty) Navigator.pop(context, value.trim());
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Switch provider'),
    content: SizedBox(
      width: 360,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Use the provider’s default model. You can choose another model afterward.',
            ),
            const SizedBox(height: 12),
            if (widget.providers.isNotEmpty)
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final provider in widget.providers)
                    ActionChip(
                      label: Text(provider),
                      onPressed: () => _select(provider),
                    ),
                ],
              ),
            TextField(
              controller: _controller,
              autofocus: widget.providers.isEmpty,
              decoration: const InputDecoration(
                labelText: 'Provider',
                hintText: 'e.g. openai',
              ),
              onSubmitted: _select,
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => _select(_controller.text),
        child: const Text('Switch'),
      ),
    ],
  );
}
