import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../../theme.dart';

/// The background belongs behind the paragraph, never in its TextStyle:
/// span backgrounds paint over Flutter's selection highlight.
class InlineCodeBuilder extends MarkdownElementBuilder {
  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) => Text.rich(
    TextSpan(
      children: <InlineSpan>[
        // Return a text widget so Markdown merges this into the surrounding
        // paragraph instead of laying out the remainder as a separate Wrap child.
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: context.speedDialColors.codeBackground,
            ),
            child: Text(
              element.textContent,
              style: (parentStyle?.merge(preferredStyle) ?? preferredStyle)
                  ?.copyWith(backgroundColor: Colors.transparent),
            ),
          ),
        ),
      ],
    ),
  );
}

/// Reuses the markdown renderer on the quote's already parsed children, so
/// lists, links, nested quotes and code retain their normal presentation.
class QuoteBuilder extends MarkdownElementBuilder {
  QuoteBuilder({required this.builders, required this.styleSheet});

  final Map<String, MarkdownElementBuilder> builders;
  final MarkdownStyleSheet Function(BuildContext) styleSheet;

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final MarkdownStyleSheet styles = styleSheet(context);
    final List<Widget> children = MarkdownBuilder(
      delegate: _QuoteDelegate(context),
      selectable: false,
      styleSheet: styles.copyWith(p: styles.p?.merge(styles.blockquote)),
      imageDirectory: null,
      imageBuilder: null,
      checkboxBuilder: null,
      bulletBuilder: null,
      builders: builders,
      paddingBuilders: const <String, MarkdownPaddingBuilder>{},
      listItemCrossAxisAlignment: MarkdownListItemCrossAxisAlignment.baseline,
    ).build(element.children ?? <md.Node>[]);
    return CopyableMarkdownBlock(
      text: _plainText(element).trimRight(),
      label: 'Copy quote',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

class _QuoteDelegate implements MarkdownBuilderDelegate {
  _QuoteDelegate(this.context);

  @override
  final BuildContext context;

  @override
  GestureRecognizer createLink(String text, String? href, String title) =>
      throw StateError('Quote links must use the shared link builder');

  @override
  TextSpan formatText(MarkdownStyleSheet styleSheet, String code) =>
      TextSpan(text: code, style: styleSheet.code);
}

String _plainText(md.Node node) {
  if (node is md.Text) return node.text;
  if (node is! md.Element) return node.textContent;
  if (node.tag == 'br') return '\n';
  if (node.tag == 'pre') return '${node.textContent.trimRight()}\n\n';
  if (node.tag == 'ul' || node.tag == 'ol') {
    int index = int.tryParse(node.attributes['start'] ?? '') ?? 1;
    final StringBuffer result = StringBuffer();
    for (final md.Node item in node.children ?? <md.Node>[]) {
      final String marker = node.tag == 'ol' ? '${index++}. ' : '- ';
      final List<String> lines = _plainText(item).trimRight().split('\n');
      result.writeln('$marker${lines.first}');
      final String indent = ' ' * marker.length;
      for (final String line in lines.skip(1)) {
        result.writeln('$indent$line');
      }
    }
    return '$result\n';
  }
  final String text = (node.children ?? <md.Node>[]).map(_plainText).join();
  return switch (node.tag) {
    'p' || 'blockquote' => '${text.trimRight()}\n\n',
    'li' => '${text.trimRight()}\n',
    'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6' => '$text\n\n',
    _ => text,
  };
}

/// A separate header keeps the action accessible on touch and clear of text.
/// Its label is excluded from message selection and clipboard contents.
class CopyableMarkdownBlock extends StatefulWidget {
  const CopyableMarkdownBlock({
    super.key,
    required this.text,
    required this.label,
    required this.child,
  });

  final String text;
  final String label;
  final Widget child;

  @override
  State<CopyableMarkdownBlock> createState() => _CopyableMarkdownBlockState();
}

class _CopyableMarkdownBlockState extends State<CopyableMarkdownBlock> {
  Timer? _reset;
  bool _copied = false;

  @override
  void didUpdateWidget(CopyableMarkdownBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _reset?.cancel();
      _copied = false;
    }
  }

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    final String text = widget.text;
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted || widget.text != text) return;
      _reset?.cancel();
      setState(() => _copied = true);
      _reset = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _copied = false);
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Could not copy to clipboard')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      SelectionContainer.disabled(
        child: Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: _copy,
            icon: Icon(_copied ? Icons.check : Icons.copy_outlined, size: 14),
            label: Text(_copied ? 'Copied' : widget.label),
            style: TextButton.styleFrom(
              foregroundColor: _copied
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.onSurfaceVariant,
              textStyle: Theme.of(context).textTheme.labelSmall,
              visualDensity: VisualDensity.compact,
            ),
          ),
        ),
      ),
      widget.child,
    ],
  );
}
