import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../toast.dart';
import 'copy_formats.dart';

/// Shared message/table menu. Clipboard conversion happens only on selection.
class CopyMenu extends StatefulWidget {
  const CopyMenu({super.key, required this.text, this.table = false});

  final String text;
  final bool table;

  @override
  State<CopyMenu> createState() => _CopyMenuState();
}

class _CopyMenuState extends State<CopyMenu> {
  Timer? _reset;
  bool _copied = false;

  @override
  void didUpdateWidget(CopyMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text != oldWidget.text) {
      _reset?.cancel();
      _copied = false;
    }
  }

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _copy(CopyFormat format) async {
    final String source = widget.text;
    try {
      await Clipboard.setData(ClipboardData(text: formatCopy(source, format)));
      if (!mounted || source != widget.text) return;
      _reset?.cancel();
      setState(() => _copied = true);
      _reset = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _copied = false);
      });
    } catch (_) {
      if (mounted) {
        showToast(
          context,
          'Could not copy to clipboard',
          tone: ToastTone.error,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => SelectionContainer.disabled(
    child: MenuAnchor(
      style: const MenuStyle(alignment: Alignment.bottomRight),
      menuChildren: <Widget>[
        for (final CopyFormat format in CopyFormat.values)
          if (widget.table || format != CopyFormat.csv)
            MenuItemButton(
              onPressed: () => _copy(format),
              child: Text(format.label),
            ),
      ],
      builder: (context, controller, child) {
        void toggle() =>
            controller.isOpen ? controller.close() : controller.open();
        final Icon icon = Icon(
          _copied ? Icons.check : Icons.content_copy,
          size: widget.table ? 14 : 18,
          color: _copied ? Theme.of(context).colorScheme.primary : null,
        );
        return widget.table
            ? TextButton.icon(
                onPressed: toggle,
                icon: icon,
                label: Text(_copied ? 'Copied' : 'Copy table'),
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context)
                      .colorScheme
                      .onSurfaceVariant,
                  textStyle: Theme.of(context).textTheme.labelSmall,
                  visualDensity: VisualDensity.compact,
                ),
              )
            : IconButton(
                onPressed: toggle,
                icon: icon,
                tooltip: _copied ? 'Copied' : 'Copy message',
                visualDensity: VisualDensity.compact,
                iconSize: 18,
              );
      },
    ),
  );
}
