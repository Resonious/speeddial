import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme.dart';

/// Height of one model row; shared by the list's `itemExtent` and the
/// keyboard-navigation scroll math.
const double _rowHeight = 44;

/// Compact model selector for the composer's controls row.
///
/// Renders like the row's other dropdowns (monospace 11px, chevron, no
/// underline) but opens a searchable picker dialog instead of a flat menu:
/// providers fronting openrouter advertise hundreds of ids, well past what a
/// plain `DropdownButton` can browse. Raw ids as labels: they are the agent's
/// config values, not display names.
class ModelPickerButton extends StatelessWidget {
  const ModelPickerButton({
    super.key,
    required this.models,
    required this.model,
    required this.onChanged,
  });

  /// Selectable model ids advertised by the agent (ACP config option).
  final List<String> models;

  /// Current model id; the button's label, and the picker's initial
  /// highlight when contained in [models].
  final String? model;

  /// Fires with the newly selected model id.
  final ValueChanged<String> onChanged;

  Future<void> _open(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => _ModelPickerDialog(
        models: models,
        model: model,
        onChanged: onChanged,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return TextButton(
      key: const Key('composer-model'),
      onPressed: () => _open(context),
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        minimumSize: const WidgetStatePropertyAll<Size>(Size.zero),
        padding: const WidgetStatePropertyAll<EdgeInsets>(
          EdgeInsets.symmetric(horizontal: 8),
        ),
        foregroundColor: WidgetStatePropertyAll<Color>(
          theme.colorScheme.onSurfaceVariant,
        ),
        textStyle: WidgetStatePropertyAll<TextStyle?>(
          context.speedDialColors.mono.copyWith(fontSize: 11),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Flexible(
            child: Text(
              model ?? 'Model',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const Icon(Icons.arrow_drop_down, size: 16),
        ],
      ),
    );
  }
}

/// Searchable model list. Typing filters (case-insensitive substring over the
/// advertised ids, advertised order preserved), arrow keys move the active
/// row, Enter picks it, Escape closes without a pick; the current model
/// starts active and carries the check mark.
class _ModelPickerDialog extends StatefulWidget {
  const _ModelPickerDialog({
    required this.models,
    required this.model,
    required this.onChanged,
  });

  final List<String> models;
  final String? model;
  final ValueChanged<String> onChanged;

  @override
  State<_ModelPickerDialog> createState() => _ModelPickerDialogState();
}

class _ModelPickerDialogState extends State<_ModelPickerDialog> {
  final TextEditingController _query = TextEditingController();

  /// Owns the search field's focus so arrow keys and Escape are intercepted
  /// at the primary focus node, before the text field's own editing
  /// shortcuts can claim them.
  late final FocusNode _queryFocus = FocusNode(onKeyEvent: _onKeyEvent);
  final ScrollController _scroll = ScrollController();
  late List<String> _matches;
  int _active = 0;

  @override
  void initState() {
    super.initState();
    _matches = widget.models;
    _active = _activeFor(widget.model);
    _query.addListener(_refilter);
  }

  @override
  void dispose() {
    _query.dispose();
    _queryFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Where [id] sits in the current matches — the row to highlight (or the
  /// top when absent, e.g. after a query narrowed the list).
  int _activeFor(String? id) {
    final int index = id == null ? -1 : _matches.indexOf(id);
    return index < 0 ? 0 : index;
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowUp:
        _move(-1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        _move(1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        Navigator.of(context).pop();
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  void _refilter() {
    final String needle = _query.text.toLowerCase().trim();
    setState(() {
      _matches = widget.models
          .where((String id) => id.toLowerCase().contains(needle))
          .toList(growable: false);
      _active = _activeFor(widget.model);
    });
  }

  void _move(int delta) {
    if (_matches.isEmpty) return;
    setState(() {
      _active = (_active + delta).clamp(0, _matches.length - 1);
    });
    // Keep the active row on screen. With the fixed row height the target
    // offset is direct arithmetic — no measuring needed.
    if (!_scroll.hasClients) return;
    final double target = _active * _rowHeight;
    final double lowestVisible =
        _scroll.offset + _scroll.position.viewportDimension - _rowHeight;
    if (target < _scroll.offset) {
      _scroll.jumpTo(target);
    } else if (target > lowestVisible) {
      _scroll.jumpTo(target - _scroll.position.viewportDimension + _rowHeight);
    }
  }

  void _select(String id) {
    Navigator.of(context).pop();
    widget.onChanged(id);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Dialog(
      child: SizedBox(
        width: 480,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: TextField(
                  key: const Key('model-picker-query'),
                  controller: _query,
                  focusNode: _queryFocus,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: 'Search models',
                    prefixIcon: Icon(Icons.search, size: 18),
                    prefixIconConstraints: BoxConstraints(minWidth: 36),
                  ),
                  onSubmitted: (String _) {
                    if (_matches.isNotEmpty) _select(_matches[_active]);
                  },
                ),
              ),
              Flexible(
                child: _matches.isEmpty
                    ? const SizedBox(
                        height: 88,
                        child: Center(child: Text('No matching models')),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        itemExtent: _rowHeight,
                        itemCount: _matches.length,
                        padding: const EdgeInsets.only(bottom: 8),
                        itemBuilder: (BuildContext context, int index) =>
                            _row(theme, index),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// One model row: check mark on the session's current model, highlight on
  /// the active (keyboard/hover) row.
  Widget _row(ThemeData theme, int index) {
    final String id = _matches[index];
    final bool active = index == _active;
    return InkWell(
      onTap: () => _select(id),
      onHover: (bool hovered) {
        if (hovered && !active) setState(() => _active = index);
      },
      child: ColoredBox(
        color: active ? theme.hoverColor : Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 20,
                  child: id == widget.model
                      ? Icon(
                          Icons.check,
                          size: 16,
                          color: theme.colorScheme.onSurface,
                        )
                      : null,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    id,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.speedDialColors.mono.copyWith(
                      fontSize: 13,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
