import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// The end of a growing text, on one line: new words come in at the right
/// while the start falls away off the left edge behind a fade into
/// [background], so a stream can be read as it arrives.
///
/// When [live] as it first shows, the text runs on from its start at the
/// pace agent messages type at, quickening to keep up with a burst;
/// otherwise it shows as it is. Line breaks and markdown markers fold into
/// plain spaced text.
class TailText extends StatefulWidget {
  const TailText(
    this.text, {
    super.key,
    required this.background,
    this.style,
    this.live = false,
  });

  final String text;
  final Color background;
  final TextStyle? style;
  final bool live;

  /// The slowest pace, in characters a second, and how long a burst takes
  /// to be caught up with (as for agent messages).
  static const double steadyRate = 220;
  static const Duration catchUp = Duration(milliseconds: 400);

  @override
  State<TailText> createState() => _TailTextState();
}

class _TailTextState extends State<TailText>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  late double _shown = widget.live ? 0 : widget.text.length.toDouble();
  Duration? _last;
  bool _still = false;

  /// More than any line holds; the rest is never laid out.
  static const int _window = 240;
  static final RegExp _markup = RegExp(r'\*\*|__|`');
  static final RegExp _space = RegExp(r'\s+');

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _sync();
  }

  @override
  void didUpdateWidget(TailText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_shown > widget.text.length) _shown = widget.text.length.toDouble();
    _sync();
  }

  void _sync() {
    if (_still) {
      _ticker.stop();
      _shown = widget.text.length.toDouble();
      return;
    }
    if (_shown < widget.text.length && !_ticker.isActive) {
      _last = null;
      _ticker.start();
    }
  }

  void _tick(Duration elapsed) {
    final Duration? last = _last;
    _last = elapsed;
    if (last == null) return;
    final double step =
        (elapsed - last).inMicroseconds / Duration.microsecondsPerSecond;
    final int before = _shown.floor();
    final double backlog = widget.text.length - _shown;
    final double rate = math.max(
      TailText.steadyRate,
      backlog *
          Duration.millisecondsPerSecond /
          TailText.catchUp.inMilliseconds,
    );
    _shown = math.min(widget.text.length.toDouble(), _shown + rate * step);
    if (_shown >= widget.text.length) _ticker.stop();
    if (_shown.floor() != before) setState(() {});
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final int end = _shown.floor().clamp(0, widget.text.length);
    final String tail = widget.text
        .substring(math.max(0, end - _window), end)
        .replaceAll(_markup, '')
        .replaceAll(_space, ' ')
        .trimLeft();
    return _TailClip(
      background: widget.background,
      child: Text(tail, maxLines: 1, softWrap: false, style: widget.style),
    );
  }
}

/// Lays its child out as wide as it likes, then shows its start when it
/// fits and its end when it does not, fading the cut-off start.
class _TailClip extends SingleChildRenderObjectWidget {
  const _TailClip({required this.background, super.child});

  final Color background;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderTailClip(background);

  @override
  void updateRenderObject(BuildContext context, _RenderTailClip renderObject) {
    renderObject.background = background;
  }
}

class _RenderTailClip extends RenderShiftedBox {
  _RenderTailClip(this._background) : super(null);

  Color _background;
  set background(Color value) {
    if (value == _background) return;
    _background = value;
    markNeedsPaint();
  }

  static const double _fade = 28;
  double _overflow = 0;
  final Paint _paint = Paint();
  final LayerHandle<ClipRectLayer> _clip = LayerHandle<ClipRectLayer>();

  @override
  void dispose() {
    _clip.layer = null;
    super.dispose();
  }

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(
      BoxConstraints(maxHeight: constraints.maxHeight),
      parentUsesSize: true,
    );
    size = constraints.constrain(
      Size(
        constraints.hasBoundedWidth ? constraints.maxWidth : child.size.width,
        child.size.height,
      ),
    );
    _overflow = math.max(0, child.size.width - size.width);
    (child.parentData! as BoxParentData).offset = Offset(-_overflow, 0);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;
    if (_overflow <= 0) {
      _clip.layer = null;
      super.paint(context, offset);
      return;
    }
    _clip.layer = context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      _paintFaded,
      oldLayer: _clip.layer,
    );
  }

  void _paintFaded(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    _paint.shader = ui.Gradient.linear(
      offset,
      offset + const Offset(_fade, 0),
      <Color>[_background, _background.withValues(alpha: 0)],
    );
    context.canvas.drawRect(offset & Size(_fade, size.height), _paint);
  }
}
