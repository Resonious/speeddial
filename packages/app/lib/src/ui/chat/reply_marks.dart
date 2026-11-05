import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../state/replies_store.dart';
import 'markdown_blocks.dart';
import 'timeline.dart';

/// Layout and list markers, which a selection's plain text and a message's
/// source disagree on: a selection runs paragraphs together, and the two
/// spell bullets differently. Quotes are compared without them.
bool _ignored(int unit) =>
    unit <= 0x20 ||
    unit == 0x2D || // -
    unit == 0xA0 ||
    unit == 0x2022 || // •
    unit == 0xFFFC; // Inline widget placeholder.

String _compact(String text) {
  final StringBuffer buffer = StringBuffer();
  for (final int unit in text.codeUnits) {
    if (!_ignored(unit)) buffer.writeCharCode(unit);
  }
  return buffer.toString();
}

/// Finds the message each reply answers. Replies record only their quote, so
/// this takes the nearest message before the reply holding that text: the one
/// the reader was most likely looking at. A quote found in no single message
/// (a selection across two, or in a tool card) gets no mark.
class ReplyMarkResolver {
  /// Compacted rendered text by markdown source. Only what the last pass
  /// visited is kept, so a streaming message's old text does not pile up.
  Map<String, String> _rendered = <String, String>{};

  /// The quotes to mark, by index into [items]. [pending] are quotes not yet
  /// in [items]: staged replies, and messages still waiting for their echo.
  Map<int, List<String>> resolve(
    List<TimelineItem> items,
    Iterable<String> pending,
  ) {
    final Map<String, String> visited = <String, String>{};
    final Map<int, List<String>> marks = <int, List<String>>{};

    String? searchable(TimelineItem item) => switch (item) {
      AgentMessageItem(:final String text) =>
        visited[text] ??= _rendered[text] ?? _compact(markdownPlainText(text)),
      UserMessageItem(:final String text) => _compact(parseReplies(text).body),
      _ => null,
    };

    void place(String quote, int before) {
      final String needle = _compact(quote);
      if (needle.isEmpty) return;
      for (int i = before - 1; i >= 0; i--) {
        if (searchable(items[i])?.contains(needle) != true) continue;
        final List<String> quotes = marks[i] ??= <String>[];
        if (!quotes.contains(quote)) quotes.add(quote);
        return;
      }
    }

    for (int i = 0; i < items.length; i++) {
      final TimelineItem item = items[i];
      if (item is! UserMessageItem || !item.text.startsWith('<reply>')) {
        continue;
      }
      for (final SentReply reply in parseReplies(item.text).replies) {
        place(reply.quote, i);
      }
    }
    for (final String quote in pending) {
      place(quote, items.length);
    }
    _rendered = visited;
    return marks;
  }
}

/// Marks the passages of [child] that have been replied to with an ember wash
/// and underline, drawn over the text so it also shows on code. A passage
/// that gains a reply while showing flares and cools; reduced motion just
/// shows the mark.
class ReplyMarks extends StatefulWidget {
  const ReplyMarks({
    super.key,
    required this.quotes,
    required this.child,
    this.color,
  });

  final List<String> quotes;
  final Widget child;

  /// Defaults to the theme's ember, for a surface it stands out on.
  final Color? color;

  @override
  State<ReplyMarks> createState() => _ReplyMarksState();
}

class _ReplyMarksState extends State<ReplyMarks>
    with SingleTickerProviderStateMixin {
  final GlobalKey _content = GlobalKey();

  /// Runs from flaring (0) to cooled (1).
  late final AnimationController _cooling = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
    value: 1,
  );

  /// Code blocks scroll in their own layer, without repainting this one.
  final ValueNotifier<int> _scrolls = ValueNotifier<int>(0);
  late final Listenable _repaint = Listenable.merge(<Listenable>[
    _cooling,
    _scrolls,
  ]);

  Set<String> _fresh = const <String>{};

  @override
  void didUpdateWidget(ReplyMarks oldWidget) {
    super.didUpdateWidget(oldWidget);
    final Set<String> added = widget.quotes.toSet().difference(
      oldWidget.quotes.toSet(),
    );
    if (added.isEmpty ||
        (MediaQuery.maybeDisableAnimationsOf(context) ?? false)) {
      return;
    }
    _fresh = added;
    _cooling.forward(from: 0);
  }

  @override
  void dispose() {
    _cooling.dispose();
    _scrolls.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (ScrollNotification _) {
        if (widget.quotes.isNotEmpty) _scrolls.value++;
        return false;
      },
      child: CustomPaint(
        foregroundPainter: widget.quotes.isEmpty
            ? null
            : _ReplyMarkPainter(
                content: _content,
                quotes: widget.quotes,
                fresh: _fresh,
                cooling: _cooling,
                color: widget.color ?? Theme.of(context).colorScheme.primary,
                repaint: _repaint,
              ),
        child: KeyedSubtree(key: _content, child: widget.child),
      ),
    );
  }
}

/// The selectable text under a render object in reading order, compacted,
/// with where each remaining code unit came from.
class _MarkableText {
  _MarkableText(RenderObject root) {
    _visit(root);
    text = _buffer.toString();
  }

  final StringBuffer _buffer = StringBuffer();
  final List<RenderParagraph> owners = <RenderParagraph>[];
  final List<int> offsets = <int>[];
  late final String text;

  void _visit(RenderObject node) {
    if (node is RenderParagraph) {
      _read(node);
    } else {
      node.visitChildren(_visit);
    }
  }

  void _read(RenderParagraph paragraph) {
    if (!paragraph.hasSize) return;
    final List<RenderObject> inline = <RenderObject>[];
    paragraph.visitChildren(inline.add);
    // Copy buttons and the like sit outside selection, so outside any quote.
    final bool selectable = paragraph.registrar != null;
    final String plain = paragraph.text.toPlainText(
      includeSemanticsLabels: false,
    );
    int placeholder = 0;
    for (int i = 0; i < plain.length; i++) {
      final int unit = plain.codeUnitAt(i);
      if (unit == 0xFFFC && placeholder < inline.length) {
        // Inline code is its own paragraph, read here in its place.
        _visit(inline[placeholder++]);
      } else if (selectable && !_ignored(unit)) {
        _buffer.writeCharCode(unit);
        owners.add(paragraph);
        offsets.add(i);
      }
    }
  }
}

class _ReplyMarkPainter extends CustomPainter {
  _ReplyMarkPainter({
    required this.content,
    required this.quotes,
    required this.fresh,
    required this.cooling,
    required this.color,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final GlobalKey content;
  final List<String> quotes;
  final Set<String> fresh;
  final Animation<double> cooling;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final RenderObject? root = content.currentContext?.findRenderObject();
    if (root == null) return;
    final _MarkableText markable = _MarkableText(root);
    for (final String quote in quotes) {
      final String needle = _compact(quote);
      if (needle.isEmpty) continue;
      final int start = markable.text.indexOf(needle);
      if (start < 0) continue;
      final double heat = fresh.contains(quote) ? 1 - cooling.value : 0;
      final int end = start + needle.length;
      int i = start;
      while (i < end) {
        final RenderParagraph paragraph = markable.owners[i];
        int last = i;
        while (last + 1 < end && markable.owners[last + 1] == paragraph) {
          last++;
        }
        _mark(
          canvas,
          root,
          paragraph,
          TextSelection(
            baseOffset: markable.offsets[i],
            extentOffset: markable.offsets[last] + 1,
          ),
          heat,
        );
        i = last + 1;
      }
    }
  }

  void _mark(
    Canvas canvas,
    RenderObject root,
    RenderParagraph paragraph,
    TextSelection range,
    double heat,
  ) {
    final Matrix4 transform = paragraph.getTransformTo(root);
    final Rect? clip = _clipOf(paragraph, root);
    final Paint wash = Paint()
      ..color = color.withValues(alpha: 0.16 + 0.2 * heat);
    final Paint underline = Paint()..color = color.withValues(alpha: 0.9);
    final Paint? glow = heat == 0
        ? null
        : (Paint()
            ..color = color.withValues(alpha: 0.5 * heat)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7));
    canvas.save();
    if (clip != null) canvas.clipRect(clip);
    for (final ui.TextBox box in paragraph.getBoxesForSelection(range)) {
      final Rect rect = MatrixUtils.transformRect(transform, box.toRect());
      if (glow != null) canvas.drawRect(rect, glow);
      canvas.drawRect(rect, wash);
      canvas.drawRect(
        Rect.fromLTRB(rect.left, rect.bottom - 1.5, rect.right, rect.bottom),
        underline,
      );
    }
    canvas.restore();
  }

  /// What the scrollers between [paragraph] and [root] leave showing, so a
  /// mark on code scrolled out of its block does not paint outside it.
  Rect? _clipOf(RenderObject paragraph, RenderObject root) {
    Rect? clip;
    RenderObject child = paragraph;
    while (child != root) {
      final RenderObject? parent = child.parent;
      if (parent == null) break;
      final Rect? local = parent.describeApproximatePaintClip(child);
      if (local != null) {
        final Rect rect = MatrixUtils.transformRect(
          parent.getTransformTo(root),
          local,
        );
        clip = clip?.intersect(rect) ?? rect;
      }
      child = parent;
    }
    return clip;
  }

  @override
  bool shouldRepaint(_ReplyMarkPainter oldDelegate) =>
      !listEquals(oldDelegate.quotes, quotes) ||
      !setEquals(oldDelegate.fresh, fresh) ||
      oldDelegate.color != color;
}
