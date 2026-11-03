import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

/// Keeps the selected branch separate from the picker's fresh search query.
class BranchPicker extends StatelessWidget {
  const BranchPicker({
    super.key,
    required this.branches,
    required this.value,
    required this.onChanged,
  });

  final List<Branch> branches;
  final String? value;
  final ValueChanged<String>? onChanged;

  Future<void> _open(BuildContext context) async {
    final String? selected = await showDialog<String>(
      context: context,
      animationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : null,
      builder: (_) => _BranchPickerDialog(branches: branches, selected: value),
    );
    if (context.mounted && selected != null) onChanged?.call(selected);
  }

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: onChanged == null ? null : () => _open(context),
    style: TextButton.styleFrom(
      padding: EdgeInsets.zero,
      foregroundColor: Theme.of(context).colorScheme.onSurface,
      textStyle: Theme.of(context).textTheme.bodyMedium,
    ),
    child: InputDecorator(
      decoration: InputDecoration(
        labelText: 'Base branch',
        enabled: onChanged != null,
      ),
      isEmpty: value == null,
      child: Row(
        children: <Widget>[
          Expanded(child: Text(value ?? '', overflow: TextOverflow.ellipsis)),
          const Icon(Icons.arrow_drop_down),
        ],
      ),
    ),
  );
}

class _BranchPickerDialog extends StatefulWidget {
  const _BranchPickerDialog({required this.branches, required this.selected});

  final List<Branch> branches;
  final String? selected;

  @override
  State<_BranchPickerDialog> createState() => _BranchPickerDialogState();
}

class _BranchPickerDialogState extends State<_BranchPickerDialog> {
  double get _rowHeight => 56 * MediaQuery.textScalerOf(context).scale(14) / 14;
  final TextEditingController _query = TextEditingController();
  final ScrollController _scroll = ScrollController();
  late final FocusNode _focus = FocusNode(onKeyEvent: _onKeyEvent);
  late List<Branch> _matches = widget.branches;
  int _active = 0;

  @override
  void initState() {
    super.initState();
    _query.addListener(_filter);
  }

  @override
  void dispose() {
    _query.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _filter() {
    final String query = _query.text.trim().toLowerCase();
    setState(() {
      _matches = widget.branches
          .where((Branch branch) => branch.name.toLowerCase().contains(query))
          .toList(growable: false);
      _active = 0;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.escape:
        Navigator.of(context).pop();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        _move(1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _move(-1);
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  void _move(int delta) {
    if (_matches.isEmpty) return;
    setState(() => _active = (_active + delta).clamp(0, _matches.length - 1));
    if (!_scroll.hasClients) return;
    final double top = _active * _rowHeight;
    final double bottom = top + _rowHeight;
    final double viewport = _scroll.position.viewportDimension;
    if (top < _scroll.offset) {
      _scroll.jumpTo(top);
    } else if (bottom > _scroll.offset + viewport) {
      _scroll.jumpTo(bottom - viewport);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      insetAnimationDuration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 100),
      child: SizedBox(
        width: 480,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'Base branch',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close branch picker',
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: TextField(
                key: const Key('branch-picker-query'),
                controller: _query,
                focusNode: _focus,
                autofocus: true,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Search branches',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _query.text.isEmpty
                      ? const SizedBox(width: 48, height: 48)
                      : IconButton(
                          tooltip: 'Clear search',
                          onPressed: () {
                            _query.clear();
                            _focus.requestFocus();
                          },
                          icon: const Icon(Icons.close, size: 18),
                        ),
                ),
                onSubmitted: (_) {
                  if (_matches.isNotEmpty) {
                    Navigator.of(context).pop(_matches[_active].name);
                  }
                },
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _matches.isEmpty
                  ? const Center(child: Text('No matching branches'))
                  : ListView.builder(
                      controller: _scroll,
                      itemExtent: _rowHeight,
                      itemCount: _matches.length,
                      itemBuilder: (BuildContext context, int index) {
                        final String name = _matches[index].name;
                        final bool selected = name == widget.selected;
                        return Semantics(
                          selected: selected,
                          child: Tooltip(
                            message: name,
                            child: ListTile(
                              selected: selected,
                              tileColor: index == _active
                                  ? theme.hoverColor
                                  : null,
                              title: Text(
                                name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: selected
                                  ? Icon(
                                      Icons.check,
                                      color: theme.colorScheme.primary,
                                      semanticLabel: 'Selected branch',
                                    )
                                  : null,
                              onTap: () => Navigator.of(context).pop(name),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
