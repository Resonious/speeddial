import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/replies_store.dart';

/// Opens the inline reply box beside a timeline selection. [anchors] are the
/// selection's context-menu anchors; the box sits below the selection, or
/// above it when the keyboard or the window edge leaves no room. Completes
/// with the trimmed reply, or null when dismissed.
Future<String?> showReplyPopover(
  BuildContext context, {
  required TextSelectionToolbarAnchors anchors,
  required String quote,
}) {
  final bool still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  return Navigator.of(
    context,
    rootNavigator: true,
  ).push<String>(_ReplyRoute(anchors: anchors, quote: quote, still: still));
}

class _ReplyRoute extends PopupRoute<String> {
  _ReplyRoute({
    required this.anchors,
    required this.quote,
    required this.still,
  });

  final TextSelectionToolbarAnchors anchors;
  final String quote;
  final bool still;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Dismiss reply';

  @override
  Duration get transitionDuration =>
      still ? Duration.zero : const Duration(milliseconds: 140);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return CustomSingleChildLayout(
      delegate: _PopoverLayout(
        anchors: anchors,
        bottomInset: MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: _ReplyPopover(quote: quote),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final Animation<double> eased = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
    );
    return FadeTransition(
      opacity: eased,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.96, end: 1).animate(eased),
        child: child,
      ),
    );
  }
}

class _PopoverLayout extends SingleChildLayoutDelegate {
  _PopoverLayout({required this.anchors, required this.bottomInset});

  static const double _margin = 8;
  static const double _gap = 10;

  final TextSelectionToolbarAnchors anchors;
  final double bottomInset;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: math.min(380, constraints.maxWidth - 2 * _margin),
        maxHeight: math.max(
          0,
          constraints.maxHeight - bottomInset - 2 * _margin,
        ),
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final Offset top = anchors.primaryAnchor;
    final Offset bottom = anchors.secondaryAnchor ?? top;
    final double floor = size.height - bottomInset - _margin;
    double y = bottom.dy + _gap;
    if (y + childSize.height > floor) y = top.dy - _gap - childSize.height;
    return Offset(
      (bottom.dx - childSize.width / 2).clamp(
        _margin,
        math.max(_margin, size.width - childSize.width - _margin),
      ),
      y.clamp(_margin, math.max(_margin, floor - childSize.height)),
    );
  }

  @override
  bool shouldRelayout(_PopoverLayout oldDelegate) =>
      anchors.primaryAnchor != oldDelegate.anchors.primaryAnchor ||
      anchors.secondaryAnchor != oldDelegate.anchors.secondaryAnchor ||
      bottomInset != oldDelegate.bottomInset;
}

class _ReplyPopover extends StatefulWidget {
  const _ReplyPopover({required this.quote});

  final String quote;

  @override
  State<_ReplyPopover> createState() => _ReplyPopoverState();
}

class _ReplyPopoverState extends State<_ReplyPopover> {
  final TextEditingController _controller = TextEditingController();
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final bool hasText = _controller.text.trim().isNotEmpty;
      if (hasText != _hasText) setState(() => _hasText = hasText);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final String reply = _controller.text.trim();
    if (reply.isEmpty) return;
    Navigator.of(context).pop(reply);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Material(
      key: const Key('reply-popover'),
      color: scheme.surfaceContainerHigh,
      elevation: 6,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ReplyQuote(text: widget.quote, maxLines: 3),
            ),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Expanded(
                  child: CallbackShortcuts(
                    bindings: <ShortcutActivator, VoidCallback>{
                      const SingleActivator(LogicalKeyboardKey.enter): _submit,
                      const SingleActivator(LogicalKeyboardKey.numpadEnter):
                          _submit,
                      const SingleActivator(
                        LogicalKeyboardKey.enter,
                        shift: true,
                      ): () =>
                          insertNewline(_controller),
                      const SingleActivator(LogicalKeyboardKey.escape): () =>
                          Navigator.of(context).pop(),
                    },
                    child: TextField(
                      key: const Key('reply-popover-field'),
                      controller: _controller,
                      autofocus: true,
                      minLines: 1,
                      maxLines: 6,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      style: theme.textTheme.bodyMedium,
                      decoration: const InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: 'Reply…',
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Add reply',
                  icon: const Icon(Icons.send, size: 18),
                  style: IconButton.styleFrom(
                    backgroundColor: scheme.primary,
                    foregroundColor: scheme.onPrimary,
                    disabledBackgroundColor: Colors.transparent,
                  ),
                  onPressed: _hasText ? _submit : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Inserts a newline at the cursor (Shift+Enter) without relying on the
/// platform IME, so behavior is identical on every platform and in tests.
void insertNewline(TextEditingController controller) {
  final TextEditingValue value = controller.value;
  final int offset = value.selection.isValid
      ? value.selection.baseOffset
      : value.text.length;
  final int clamped = offset.clamp(0, value.text.length);
  controller.value = TextEditingValue(
    text: value.text.replaceRange(clamped, clamped, '\n'),
    selection: TextSelection.collapsed(offset: clamped + 1),
  );
}

/// The passage a reply answers: muted text behind an ember bar.
class ReplyQuote extends StatelessWidget {
  const ReplyQuote({super.key, required this.text, this.maxLines, this.color});

  final String text;

  /// Clamps a preview; null shows it all (scrolling past a capped height).
  final int? maxLines;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Widget quote = Text(
      text,
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
      style: theme.textTheme.bodySmall?.copyWith(
        color: color ?? theme.colorScheme.onSurfaceVariant,
        fontStyle: FontStyle.italic,
      ),
    );
    return Container(
      padding: const EdgeInsets.only(left: 8),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: theme.colorScheme.primary, width: 3),
        ),
      ),
      child: maxLines != null
          ? quote
          : ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 120),
              child: SingleChildScrollView(child: quote),
            ),
    );
  }
}

/// A staged reply in the composer's chip row: the quote's opening words,
/// highlighted while its editor is open, and a remove affordance. A reply
/// staged while the composer is showing lands with a small pop and an ember
/// halo (still under reduced motion).
class ReplyChip extends StatefulWidget {
  const ReplyChip({
    super.key,
    required this.reply,
    required this.open,
    required this.fresh,
    required this.onTap,
    required this.onRemove,
  });

  final ReplyDraft reply;
  final bool open;
  final bool fresh;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  State<ReplyChip> createState() => _ReplyChipState();
}

class _ReplyChipState extends State<ReplyChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _land = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
    value: 1,
  );

  bool _played = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_played) return;
    _played = true;
    if (widget.fresh &&
        !(MediaQuery.maybeDisableAnimationsOf(context) ?? false)) {
      _land.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _land.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Widget chip = Material(
      color: scheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: widget.open ? scheme.primary : Colors.transparent,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.only(left: 8, right: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.reply, size: 18, color: scheme.primary),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: Text(
                  '“${_preview(widget.reply.quote)}”',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium,
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: 'Remove reply',
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                icon: const Icon(Icons.close),
                onPressed: widget.onRemove,
              ),
            ],
          ),
        ),
      ),
    );
    return AnimatedBuilder(
      animation: _land,
      child: chip,
      builder: (BuildContext context, Widget? child) {
        final double t = _land.value;
        if (t == 1) return child!;
        // Overshoots, then settles; the halo fades as it cools.
        final double scale = Curves.elasticOut.transform(
          (t * 1.4).clamp(0.0, 1.0),
        );
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: scheme.primary.withValues(alpha: 0.45 * (1 - t)),
                blurRadius: 14,
                spreadRadius: 1,
              ),
            ],
          ),
          child: Transform.scale(scale: 0.6 + 0.4 * scale, child: child),
        );
      },
    );
  }
}

/// The open staged reply: what it answers, and the reply itself, editable.
class ReplyEditor extends StatefulWidget {
  const ReplyEditor({
    super.key,
    required this.reply,
    required this.onChanged,
    required this.onClose,
  });

  final ReplyDraft reply;
  final ValueChanged<String> onChanged;
  final VoidCallback onClose;

  @override
  State<ReplyEditor> createState() => _ReplyEditorState();
}

class _ReplyEditorState extends State<ReplyEditor> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.reply.reply,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Container(
      key: const Key('reply-editor'),
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 4, 4, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'Replying to',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Collapse reply',
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                icon: const Icon(Icons.expand_less),
                onPressed: widget.onClose,
              ),
            ],
          ),
          ReplyQuote(text: widget.reply.quote),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: TextField(
              key: const Key('reply-editor-field'),
              controller: _controller,
              minLines: 1,
              maxLines: 5,
              keyboardType: TextInputType.multiline,
              style: theme.textTheme.bodyMedium,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                hintText: 'Your reply',
              ),
              onChanged: widget.onChanged,
            ),
          ),
        ],
      ),
    );
  }
}

/// Replies carried by a sent message, shown as chips at the top of its
/// bubble; tapping one opens what it answered with the reply beneath. Which
/// one is open lives in [PageStorage] so it survives the row rebuilding.
class SentReplies extends StatefulWidget {
  const SentReplies({super.key, required this.replies});

  final List<SentReply> replies;

  @override
  State<SentReplies> createState() => _SentRepliesState();
}

class _SentRepliesState extends State<SentReplies> {
  static const String _storageId = 'sent-reply-open';
  int? _open;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _open ??= PageStorage.maybeOf(
      context,
    )?.readState(context, identifier: _storageId) as int?;
  }

  void _toggle(int index) {
    setState(() => _open = _open == index ? null : index);
    PageStorage.maybeOf(context)
        ?.writeState(context, _open, identifier: _storageId);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color ink = scheme.onPrimaryContainer;
    final int? open = _open != null && _open! < widget.replies.length
        ? _open
        : null;
    final bool still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final Widget detail = open == null
        ? const SizedBox.shrink()
        : Container(
            key: ValueKey<int>(open),
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: ink.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                ReplyQuote(
                  text: widget.replies[open].quote,
                  color: ink.withValues(alpha: 0.75),
                ),
                const SizedBox(height: 6),
                Text(
                  widget.replies[open].reply,
                  style: theme.textTheme.bodyMedium?.copyWith(color: ink),
                ),
              ],
            ),
          );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (int i = 0; i < widget.replies.length; i++)
              Material(
                color: ink.withValues(alpha: i == open ? 0.14 : 0.07),
                borderRadius: BorderRadius.circular(8),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => _toggle(i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(Icons.reply, size: 16, color: ink),
                        const SizedBox(width: 6),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 180),
                          child: Text(
                            '“${_preview(widget.replies[i].quote)}”',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: ink,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
        if (still)
          detail
        else
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: detail,
          ),
      ],
    );
  }
}

String _preview(String quote) => quote.trim().replaceAll(RegExp(r'\s+'), ' ');
