import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../../theme.dart';

/// Types an agent message out a character at a time behind a glowing ember,
/// however the provider happens to deliver it.
///
/// A message first seen while the agent is [writing] it types out: its text
/// shows in reading order at a steady pace that quickens to work off a
/// backlog, the message grows a line at a time, and sparks fly off the ember
/// at the typing point. The ember keeps glowing while [writing] (more may
/// come) and dies down once the typing is done. A message first seen
/// finished shows whole, as does everything under reduced motion.
///
/// Markdown still re-renders only when text arrives: typing is a clip and a
/// cursor over the laid-out child, so it repaints rather than rebuilds.
class TypewriterReveal extends StatefulWidget {
  const TypewriterReveal({
    super.key,
    required this.writing,
    required this.child,
  });

  /// Whether the agent is still writing the message.
  final bool writing;
  final Widget child;

  @override
  State<TypewriterReveal> createState() => _TypewriterRevealState();
}

class _TypewriterRevealState extends State<TypewriterReveal>
    with SingleTickerProviderStateMixin {
  final _Pace _pace = _Pace();
  late final Ticker _ticker = createTicker(_tick);
  bool _still = false;
  bool _started = false;

  /// Where typing progress is kept (see [_storageKeyFor]).
  PageStorageBucket? _bucket;
  Object? _storageKey;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _bucket = PageStorage.maybeOf(context);
    _storageKey = _storageKeyFor(context);
    if (!_started) {
      _started = true;
      final Object? key = _storageKey;
      final Object? typed = key == null
          ? null
          : _bucket?.readState(context, identifier: key);
      _pace.typed = typed is double
          ? typed
          : widget.writing
          ? 0
          : double.infinity;
    }
    _wake();
  }

  /// Typing progress is kept so that a message scrolled away and back is
  /// not typed out again: per message, under the nearest [PageStorageKey]
  /// (the timeline keys each row). An explicit identifier is shared across
  /// the whole bucket, and an implicit one with the scroll positions of
  /// code blocks inside the message.
  static Object? _storageKeyFor(BuildContext context) {
    Object? key;
    context.visitAncestorElements((Element element) {
      final Key? widgetKey = element.widget.key;
      if (widgetKey is PageStorageKey<Object?>) {
        key = ('typewriter', widgetKey.value);
        return false;
      }
      return element.widget is! PageStorage;
    });
    return key;
  }

  @override
  void didUpdateWidget(TypewriterReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    // More text, or the end of writing, may need a few more frames.
    _wake();
  }

  void _wake() {
    // A message shown whole for good has nothing to animate.
    if (_still || _ticker.isActive) return;
    if (widget.writing || _pace.typed.isFinite) _ticker.start();
  }

  void _tick(Duration _) {
    _pace.tick(
      SchedulerBinding.instance.currentFrameTimeStamp.inMicroseconds /
          Duration.microsecondsPerSecond,
    );
    // Kept as it goes: by the time a view is torn down it can no longer
    // reach the bucket.
    final Object? key = _storageKey;
    if (key != null) {
      _bucket?.writeState(context, _pace.typed, identifier: key);
    }
    if (!_pace.moving) _ticker.stop();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _pace.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SpeedDialColors colors = theme.speedDialColors;
    final bool dark = theme.brightness == Brightness.dark;
    return _Typewriter(
      key: const Key('typewriter'),
      pace: _pace,
      writing: widget.writing,
      still: _still,
      // White-hot vanishes on a light canvas; start amber there.
      hot: dark ? colors.flameCore : colors.flameTip,
      warm: dark ? colors.flameTip : theme.colorScheme.primary,
      ember: theme.colorScheme.primary,
      glowStrength: dark ? 1 : 0.7,
      // Typing repaints the clip and the ember, never the text itself.
      child: RepaintBoundary(child: widget.child),
    );
  }
}

/// Carries frame times from the widget's ticker to the render object, and
/// how far typing got back.
class _Pace extends ChangeNotifier {
  double now = 0;

  /// Characters shown so far; infinite once the whole message shows.
  double typed = 0;

  /// Whether the render object still has anything to animate.
  bool moving = true;

  void tick(double time) {
    now = time;
    notifyListeners();
  }
}

class _Typewriter extends SingleChildRenderObjectWidget {
  const _Typewriter({
    super.key,
    required this.pace,
    required this.writing,
    required this.still,
    required this.hot,
    required this.warm,
    required this.ember,
    required this.glowStrength,
    super.child,
  });

  final _Pace pace;
  final bool writing;
  final bool still;
  final Color hot;
  final Color warm;
  final Color ember;
  final double glowStrength;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderTypewriter(pace, writing, still, hot, warm, ember, glowStrength);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderTypewriter renderObject,
  ) {
    renderObject
      ..writing = writing
      ..still = still
      ..hot = hot
      ..warm = warm
      ..ember = ember
      ..glowStrength = glowStrength;
  }
}

/// One laid-out line of the message's text, in its reading order.
class _Line {
  _Line({
    required this.paragraph,
    required this.origin,
    required this.paragraphStart,
    required this.start,
    required this.top,
    required this.bottom,
  });

  final RenderParagraph paragraph;

  /// Where [paragraph] sits in the typewriter's coordinates.
  final Offset origin;

  /// Offset of [paragraph]'s first character in the whole message.
  final int paragraphStart;

  /// The line's characters in the whole message: [start] to [end].
  final int start;
  int end = 0;
  final double top;
  final double bottom;
}

/// A paragraph's lines, in its own coordinates and character offsets.
class _Block {
  _Block(this.paragraph, this.origin, this.length)
    : starts = <int>[],
      tops = <double>[],
      bottoms = <double>[] {
    // Walk down the lines by caret: each starts at the first character
    // under the one above. Below the last line, that lands back on it.
    int start = 0;
    while (true) {
      final TextPosition at = TextPosition(offset: start);
      final double top = paragraph.getOffsetForCaret(at, Rect.zero).dy;
      final double bottom = top + paragraph.getFullHeightForCaret(at);
      starts.add(start);
      tops.add(top);
      bottoms.add(bottom);
      final int next = paragraph
          .getPositionForOffset(Offset(0, bottom + 1))
          .offset;
      if (next <= start || next > length) break;
      start = next;
    }
  }

  final RenderParagraph paragraph;
  final Offset origin;
  final int length;
  final List<int> starts;
  final List<double> tops;
  final List<double> bottoms;

  double get top => origin.dy + tops.first;
  double get lineHeight => bottoms.first - tops.first;
}

class _Spark {
  const _Spark({
    required this.origin,
    required this.velocity,
    required this.born,
    required this.life,
    required this.size,
  });

  final Offset origin;
  final Offset velocity;
  final double born;
  final double life;
  final double size;
}

class _RenderTypewriter extends RenderProxyBox {
  _RenderTypewriter(
    this._pace,
    this._writing,
    this._still,
    this._hot,
    this._warm,
    this._ember,
    this._glowStrength,
  ) : _shown = _still ? double.infinity : _pace.typed;

  final _Pace _pace;

  /// Characters showing; infinite once the whole message shows for good.
  double _shown;

  bool _writing;
  set writing(bool value) {
    if (value == _writing) return;
    _writing = value;
    markNeedsPaint();
  }

  bool _still;
  set still(bool value) {
    if (value == _still) return;
    _still = value;
    if (value) {
      _shown = double.infinity;
      _sparks.clear();
      _glow = 0;
      markNeedsLayout();
    }
  }

  Color _hot;
  set hot(Color value) {
    if (value == _hot) return;
    _hot = value;
    markNeedsPaint();
  }

  Color _warm;
  set warm(Color value) {
    if (value == _warm) return;
    _warm = value;
    markNeedsPaint();
  }

  Color _ember;
  set ember(Color value) {
    if (value == _ember) return;
    _ember = value;
    markNeedsPaint();
  }

  /// Light reads as a stain on light surfaces; keep it fainter there.
  double _glowStrength;
  set glowStrength(double value) {
    if (value == _glowStrength) return;
    _glowStrength = value;
    markNeedsPaint();
  }

  /// The slowest typing, in characters a second: about a line every
  /// quarter second.
  static const double _steadyRate = 220;

  /// How long typing takes to work off a backlog when text lands in bulk.
  static const double _catchUp = 0.4;

  static const double _gravity = 380;
  static const double _far = 1e5;

  List<_Line> _lines = const <_Line>[];
  int _total = 0;

  /// Whether [_lines] match the child as last laid out. Measuring reads
  /// paint geometry, so it happens in paint; layout goes by the last one,
  /// which streaming (appending text) leaves right for the typed part.
  bool _measured = false;
  bool _everMeasured = false;
  BoxConstraints? _measuredFor;

  /// A fresh measurement wants a different height than was laid out.
  bool _resizeDue = false;

  /// The line typing is on as of the last layout; -1 when everything shows.
  int _line = -1;

  final Path _clip = Path();
  final LayerHandle<ClipPathLayer> _clipLayer = LayerHandle<ClipPathLayer>();
  final Paint _paint = Paint()..strokeCap = StrokeCap.round;
  final List<_Spark> _sparks = <_Spark>[];
  final math.Random _random = math.Random(7);

  /// The typing point as last painted; sparks fly from here.
  Offset? _cursor;
  double _glow = 0;
  double _now = 0;
  double? _last;
  double _sparkDue = 0;
  double _nextTrickle = 0;

  bool get _typing => _shown < _total;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _pace.addListener(_advance);
  }

  @override
  void detach() {
    _pace.removeListener(_advance);
    super.detach();
  }

  @override
  void dispose() {
    _clipLayer.layer = null;
    super.dispose();
  }

  @override
  void markNeedsLayout() {
    // Something in the child changed: its lines need measuring again.
    _measured = false;
    super.markNeedsLayout();
  }

  void _advance() {
    final double now = _pace.now;
    final double step = _last == null
        ? 0
        : (now - _last!).clamp(0.0, 0.1).toDouble();
    _last = now;
    _now = now;
    if (_typing) {
      final double backlog = _total - _shown;
      final double typed = math.min(
        backlog,
        math.max(_steadyRate, backlog / _catchUp) * step,
      );
      _shown += typed;
      _sparkDue += typed / 9;
    }
    final Offset? at = _cursor;
    if (at != null && _sparkDue >= 1) {
      _spawn(at, now);
      _sparkDue = math.min(_sparkDue - 1, 1);
    }
    if (at != null && !_typing && _writing && now >= _nextTrickle) {
      _spawn(at, now);
      _nextTrickle = now + 0.18 + 0.22 * _random.nextDouble();
    }
    _sparks.removeWhere((_Spark spark) => now - spark.born >= spark.life);
    final bool lit = _typing || _writing;
    _glow = lit
        ? math.min(1, _glow + step / 0.15)
        : math.max(0, _glow - step / 0.6);
    if (!lit && _glow == 0 && _sparks.isEmpty && _shown.isFinite) {
      // Done for good: stop measuring, and let later text show at once.
      _shown = double.infinity;
    }
    _pace
      ..typed = _shown
      ..moving = lit || _glow > 0 || _sparks.isNotEmpty;
    if (_resizeDue || _lineFor(_shown) != _line) {
      // Only how much shows changed, not the child: no need to measure.
      _resizeDue = false;
      super.markNeedsLayout();
    } else {
      markNeedsPaint();
    }
  }

  void _spawn(Offset at, double now) {
    // Off the back of the moving tip, mostly up.
    final double angle =
        -math.pi / 2 - 0.25 + (_random.nextDouble() - 0.5) * 1.5;
    final double speed = 50 + 90 * _random.nextDouble();
    _sparks.add(
      _Spark(
        origin: at,
        velocity: Offset(math.cos(angle), math.sin(angle)) * speed,
        born: now,
        life: 0.3 + 0.3 * _random.nextDouble(),
        size: 1.1 + 0.9 * _random.nextDouble(),
      ),
    );
  }

  /// The line holding the typing point: the last one once typing has
  /// caught up. -1 when the whole message shows, or nothing is measured.
  int _lineFor(double shown) {
    if (!shown.isFinite || _lines.isEmpty) return -1;
    final int at = math.min(shown.floor(), _total);
    int low = 0;
    int high = _lines.length - 1;
    while (low < high) {
      final int middle = (low + high + 1) >> 1;
      if (_lines[middle].start <= at) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    return low;
  }

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    if (constraints != _measuredFor) _measured = false;
    _line = _lineFor(_shown);
    size = constraints.constrain(
      Size(child.size.width, _heightFor(_line, child.size)),
    );
  }

  /// Down to the bottom of [line], the line typing is on.
  double _heightFor(int line, Size child) {
    if (!_shown.isFinite) return child.height;
    // Before the first measurement, a fresh message has typed nothing; one
    // scrolled back into view had typed what there was.
    if (line < 0) return _everMeasured || _shown > 0 ? child.height : 0;
    return math.min(child.height, _lines[line].bottom);
  }

  /// Lines of every paragraph in the child, in reading order: rows top to
  /// bottom, and paragraphs sharing a row (a bullet and its item, table
  /// cells) left to right.
  void _measure() {
    final List<RenderParagraph> found = <RenderParagraph>[];
    _collect(child!, found);
    final List<_Block> blocks = <_Block>[];
    for (final RenderParagraph paragraph in found) {
      if (!paragraph.hasSize) continue;
      final int length = paragraph.text
          .toPlainText(includeSemanticsLabels: false)
          .length;
      if (length == 0) continue;
      blocks.add(
        _Block(
          paragraph,
          MatrixUtils.transformPoint(
            paragraph.getTransformTo(this),
            Offset.zero,
          ),
          length,
        ),
      );
    }
    blocks.sort((_Block a, _Block b) => a.top.compareTo(b.top));
    final List<_Block> ordered = <_Block>[];
    for (int i = 0; i < blocks.length;) {
      final double rowTop = blocks[i].top;
      final double tolerance = blocks[i].lineHeight / 2;
      int j = i + 1;
      while (j < blocks.length && blocks[j].top - rowTop < tolerance) {
        j++;
      }
      ordered.addAll(
        blocks.sublist(i, j)
          ..sort((_Block a, _Block b) => a.origin.dx.compareTo(b.origin.dx)),
      );
      i = j;
    }
    final List<_Line> lines = <_Line>[];
    int total = 0;
    for (final _Block block in ordered) {
      for (int i = 0; i < block.starts.length; i++) {
        lines.add(
          _Line(
            paragraph: block.paragraph,
            origin: block.origin,
            paragraphStart: total,
            start: total + block.starts[i],
            top: block.origin.dy + block.tops[i],
            bottom: block.origin.dy + block.bottoms[i],
          ),
        );
      }
      total += block.length;
    }
    for (int i = 0; i < lines.length; i++) {
      lines[i].end = i + 1 < lines.length ? lines[i + 1].start : total;
    }
    _lines = lines;
    _total = total;
    _measured = true;
    _everMeasured = true;
    _measuredFor = constraints;
  }

  static void _collect(RenderObject node, List<RenderParagraph> found) {
    if (node is RenderParagraph) {
      found.add(node);
      return;
    }
    node.visitChildren((RenderObject child) => _collect(child, found));
  }

  /// Where the caret sits at [shown] characters, in this box: between
  /// characters as typing passes them.
  double _caretX(_Line line, double shown) {
    final int at = shown.floor().clamp(line.start, line.end);
    final double x = _caretAt(line, at);
    if (at >= line.end) return x;
    return x + (_caretAt(line, at + 1) - x) * (shown - at);
  }

  double _caretAt(_Line line, int at) {
    final int local = at - line.paragraphStart;
    final Offset caret = line.paragraph.getOffsetForCaret(
      // A line's end is also the next line's start; keep it on this one.
      TextPosition(
        offset: local,
        affinity: at == line.end && at > line.start
            ? TextAffinity.upstream
            : TextAffinity.downstream,
      ),
      Rect.zero,
    );
    return line.origin.dx + caret.dx;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final RenderBox? child = this.child;
    if (child == null) return;
    if (_shown.isFinite && !_measured) {
      // The child's paint geometry is settled only now; if it calls for a
      // different height, layout catches up on the next frame.
      _measure();
      // Re-rendered markdown can come out shorter (closing `**` hides two).
      if (_shown > _total) _shown = _total.toDouble();
      if (_heightFor(_lineFor(_shown), child.size) != size.height) {
        _resizeDue = true;
      }
    }
    final int index = _lineFor(_shown);
    if (index < 0) {
      _clipLayer.layer = null;
      context.paintChild(child, offset);
    } else {
      final _Line line = _lines[index];
      final double x = _caretX(line, math.min(_shown, line.end.toDouble()));
      _cursor = Offset(x, (line.top + line.bottom) / 2);
      _clip
        ..reset()
        ..addRect(Rect.fromLTRB(-_far, -_far, _far, line.top))
        ..addRect(Rect.fromLTRB(-_far, line.top, x, line.bottom));
      _clipLayer.layer = context.pushClipPath(
        needsCompositing,
        offset,
        Offset.zero & size,
        _clip,
        super.paint,
        oldLayer: _clipLayer.layer,
      );
    }
    _paintEmber(context.canvas, offset);
  }

  void _paintEmber(Canvas canvas, Offset offset) {
    final Offset? cursor = _cursor;
    if (cursor == null) return;
    final double glow = _glow;
    if (glow > 0) {
      final Offset at = offset + cursor;
      final double flicker =
          0.86 + 0.09 * math.sin(_now * 23) + 0.05 * math.sin(_now * 57);
      _paint
        ..style = PaintingStyle.fill
        ..color = _ember.withValues(alpha: 0.4 * glow * _glowStrength)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
      canvas.drawCircle(at, 8 * flicker, _paint);
      _paint
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1)
        ..color = Color.lerp(_warm, _hot, flicker)!.withValues(alpha: glow);
      canvas.drawCircle(at, 2.5 * flicker, _paint);
      _paint.maskFilter = null;
    }
    for (final _Spark spark in _sparks) {
      final double age = _now - spark.born;
      if (age <= 0) continue;
      final double cooled = age / spark.life;
      final Offset head = offset + _sparkAt(spark, age);
      final Offset tail = offset + _sparkAt(spark, math.max(0, age - 0.035));
      final Color color = cooled < 0.4
          ? Color.lerp(_hot, _warm, cooled / 0.4)!
          : Color.lerp(_warm, _ember, (cooled - 0.4) / 0.6)!;
      _paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = spark.size * (1 - 0.4 * cooled)
        ..color = color.withValues(alpha: 1 - cooled * cooled);
      canvas.drawLine(tail, head, _paint);
    }
  }

  static Offset _sparkAt(_Spark spark, double age) =>
      spark.origin +
      spark.velocity * age +
      Offset(0, 0.5 * _gravity * age * age);
}
