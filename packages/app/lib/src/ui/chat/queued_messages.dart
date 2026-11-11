import 'package:flutter/material.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

/// Messages sent while a turn runs wait above the composer as raw dough on
/// the counter: a still, pale version of the user's bubble that rises in
/// once. Each can be steered into the running turn (when the harness can),
/// sent now (when idle), taken back into the composer, or removed. A paused
/// queue cools to a neutral outline. Nothing loops while they wait.
class QueuedMessagesTray extends StatelessWidget {
  const QueuedMessagesTray({
    super.key,
    required this.queue,
    required this.running,
    required this.enabled,
    required this.busy,
    required this.onSend,
    required this.onEdit,
    required this.onRemove,
  });

  final SessionQueue queue;

  /// A turn is running: the primary action steers instead of sending.
  final bool running;

  /// False while the daemon is out of reach; actions are disabled.
  final bool enabled;

  /// Ids with a request in flight; their actions are disabled.
  final Set<String> busy;
  final ValueChanged<QueuedMessage> onSend;
  final ValueChanged<QueuedMessage> onEdit;
  final ValueChanged<QueuedMessage> onRemove;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool canSteer = running && queue.canSteer;
    final String label = queue.paused
        ? 'Queue paused · the last turn did not finish'
        : running
        ? canSteer
              ? 'Queued · sends after this turn, or steer it in now'
              : 'Queued · sends after this turn'
        : 'Queued · sending next';
    return Padding(
      key: const Key('queued-tray'),
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
            child: Text(
              label,
              key: const Key('queued-label'),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 176),
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: <Widget>[
                for (final QueuedMessage message in queue.messages)
                  _QueuedRow(
                    key: ValueKey<String>('queued-${message.id}'),
                    message: message,
                    paused: queue.paused,
                    action: !enabled || busy.contains(message.id)
                        ? null
                        : canSteer
                        ? _RowAction.steer
                        : running
                        ? null
                        : _RowAction.send,
                    enabled: enabled && !busy.contains(message.id),
                    onSend: () => onSend(message),
                    onEdit: () => onEdit(message),
                    onRemove: () => onRemove(message),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

enum _RowAction { steer, send }

class _QueuedRow extends StatefulWidget {
  const _QueuedRow({
    super.key,
    required this.message,
    required this.paused,
    required this.action,
    required this.enabled,
    required this.onSend,
    required this.onEdit,
    required this.onRemove,
  });

  final QueuedMessage message;
  final bool paused;
  final _RowAction? action;
  final bool enabled;
  final VoidCallback onSend;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  State<_QueuedRow> createState() => _QueuedRowState();
}

class _QueuedRowState extends State<_QueuedRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );
  late final Animation<double> _rise = CurvedAnimation(
    parent: _enter,
    curve: Curves.easeOutCubic,
  );
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.35),
    end: Offset.zero,
  ).animate(_rise);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _enter.value = 1;
    } else if (_enter.isDismissed) {
      _enter.forward();
    }
  }

  @override
  void dispose() {
    _enter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final QueuedMessage message = widget.message;
    // Raw dough: the user's bubble under a pale veil; cold when paused.
    final Color fill = widget.paused
        ? scheme.surfaceContainerHighest
        : Color.alphaBlend(
            scheme.surface.withValues(alpha: 0.5),
            scheme.primaryContainer,
          );
    final String preview = message.text.trim().isEmpty
        ? 'Attachment only'
        : message.text.trim();
    final int files = message.attachments.length;
    final Widget row = Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(14),
        border: widget.paused ? Border.all(color: scheme.outlineVariant) : null,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  preview,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: widget.paused
                        ? scheme.onSurfaceVariant
                        : scheme.onPrimaryContainer,
                  ),
                ),
                if (files > 0)
                  Text(
                    files == 1 ? '1 file' : '$files files',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          if (widget.action == _RowAction.steer)
            TextButton.icon(
              key: Key('queued-steer-${message.id}'),
              onPressed: widget.onSend,
              icon: const Icon(Icons.alt_route, size: 18),
              label: const Text('Steer'),
            )
          else if (widget.action == _RowAction.send)
            TextButton.icon(
              key: Key('queued-send-${message.id}'),
              onPressed: widget.onSend,
              icon: const Icon(Icons.send, size: 16),
              label: const Text('Send now'),
            ),
          IconButton(
            key: Key('queued-edit-${message.id}'),
            tooltip: 'Edit',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.edit_outlined, size: 18),
            onPressed: widget.enabled ? widget.onEdit : null,
          ),
          IconButton(
            key: Key('queued-remove-${message.id}'),
            tooltip: 'Remove from queue',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 18),
            onPressed: widget.enabled ? widget.onRemove : null,
          ),
        ],
      ),
    );
    return FadeTransition(
      opacity: _rise,
      child: SlideTransition(position: _slide, child: row),
    );
  }
}
