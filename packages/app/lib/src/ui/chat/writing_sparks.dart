import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../../theme.dart';

/// A glowing ember at the end of text that is still being written, throwing
/// off a few sparks each time more of it appears.
///
/// Bump [writes] whenever [child] shows more text: once laid out, the end of
/// its last paragraph is found and lit. The ember stays lit while writes keep
/// coming and dies down shortly after they stop; nothing ticks in between,
/// and reduced motion turns it off.
class WritingSparks extends StatefulWidget {
  const WritingSparks({super.key, required this.writes, required this.child});

  final int writes;
  final Widget child;

  @override
  State<WritingSparks> createState() => _WritingSparksState();
}

class _WritingSparksState extends State<WritingSparks>
    with SingleTickerProviderStateMixin {
  final GlobalKey _content = GlobalKey();
  final _SparkField _field = _SparkField();
  final math.Random _random = math.Random(7);
  late final Ticker _ticker = createTicker(_tick);
  bool _still = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  }

  @override
  void didUpdateWidget(WritingSparks oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.writes == oldWidget.writes || _still) return;
    // The new end of the text is known once this frame has laid it out.
    SchedulerBinding.instance.addPostFrameCallback((_) => _write());
  }

  void _write() {
    if (!mounted) return;
    final Offset? end = _textEnd();
    if (end == null) return;
    _field.write(end, _seconds(), _random);
    if (!_ticker.isActive) _ticker.start();
  }

  void _tick(Duration _) {
    if (!_field.advance(_seconds())) _ticker.stop();
  }

  static double _seconds() =>
      SchedulerBinding.instance.currentFrameTimeStamp.inMicroseconds /
      Duration.microsecondsPerSecond;

  /// Middle of the line just past the last character, in this widget's
  /// coordinates.
  Offset? _textEnd() {
    final RenderObject? content = _content.currentContext?.findRenderObject();
    final RenderObject? self = context.findRenderObject();
    if (content == null || self is! RenderBox || !self.hasSize) return null;
    final RenderParagraph? last = _lastParagraph(content);
    if (last == null || !last.hasSize) return null;
    final TextPosition end = TextPosition(
      offset: last.text.toPlainText().length,
    );
    final Offset caret = last.getOffsetForCaret(end, Rect.zero);
    final double height = last.getFullHeightForCaret(end);
    return MatrixUtils.transformPoint(
      last.getTransformTo(self),
      caret + Offset(3, height * 0.55),
    );
  }

  /// Depth-first from the end, so only the path to the final paragraph is
  /// visited.
  static RenderParagraph? _lastParagraph(RenderObject node) {
    if (node is RenderParagraph) return node;
    final List<RenderObject> children = <RenderObject>[];
    node.visitChildren(children.add);
    for (int i = children.length - 1; i >= 0; i--) {
      final RenderParagraph? found = _lastParagraph(children[i]);
      if (found != null) return found;
    }
    return null;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SpeedDialColors colors = theme.speedDialColors;
    final bool dark = theme.brightness == Brightness.dark;
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        KeyedSubtree(key: _content, child: widget.child),
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: CustomPaint(
                key: const Key('writing-sparks'),
                painter: _WritingSparksPainter(
                  field: _field,
                  // White-hot vanishes on a light canvas; start amber there.
                  hot: dark ? colors.flameCore : colors.flameTip,
                  warm: dark ? colors.flameTip : theme.colorScheme.primary,
                  ember: theme.colorScheme.primary,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
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

/// The live sparks and the ember they fly from; times are frame-clock
/// seconds.
class _SparkField extends ChangeNotifier {
  final List<_Spark> sparks = <_Spark>[];
  Offset? ember;
  double fedAt = 0;
  double now = 0;

  static const int _maxSparks = 48;

  void write(Offset end, double time, math.Random random) {
    ember = end;
    fedAt = time;
    now = time;
    for (int i = 0; i < 3; i++) {
      final double angle = -math.pi / 2 + (random.nextDouble() - 0.25) * 1.6;
      final double speed = 60 + 120 * random.nextDouble();
      sparks.add(
        _Spark(
          origin: end,
          velocity: Offset(math.cos(angle), math.sin(angle)) * speed,
          born: time + i * 0.02,
          life: 0.28 + 0.3 * random.nextDouble(),
          size: 1 + 0.9 * random.nextDouble(),
        ),
      );
    }
    if (sparks.length > _maxSparks) {
      sparks.removeRange(0, sparks.length - _maxSparks);
    }
    notifyListeners();
  }

  /// Moves the clock to [time]; false once nothing is left to draw.
  bool advance(double time) {
    now = time;
    sparks.removeWhere((_Spark spark) => time - spark.born >= spark.life);
    notifyListeners();
    return sparks.isNotEmpty || glow > 0;
  }

  /// 1 while writes keep coming, dying down over a moment once they stop.
  double get glow {
    if (ember == null) return 0;
    final double idle = now - fedAt;
    if (idle < 0.25) return 1;
    return math.max(0, 1 - (idle - 0.25) / 0.6);
  }
}

class _WritingSparksPainter extends CustomPainter {
  _WritingSparksPainter({
    required this.field,
    required this.hot,
    required this.warm,
    required this.ember,
  }) : super(repaint: field);

  final _SparkField field;
  final Color hot;
  final Color warm;
  final Color ember;
  final Paint _paint = Paint()..strokeCap = StrokeCap.round;

  static const double _gravity = 520;

  @override
  void paint(Canvas canvas, Size size) {
    final double glow = field.glow;
    final Offset? at = field.ember;
    if (at != null && glow > 0) {
      final double flicker = 0.85 + 0.15 * math.sin(field.now * 31);
      _paint
        ..style = PaintingStyle.fill
        ..color = ember.withValues(alpha: 0.28 * glow)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
      canvas.drawCircle(at, 6 * flicker, _paint);
      _paint
        ..maskFilter = null
        ..color = Color.lerp(warm, hot, flicker)!.withValues(alpha: glow);
      canvas.drawCircle(at, 2.1 * flicker, _paint);
    }
    for (final _Spark spark in field.sparks) {
      final double age = field.now - spark.born;
      if (age <= 0) continue;
      final double cooled = age / spark.life;
      final Offset head = _at(spark, age);
      final Offset tail = _at(spark, math.max(0, age - 0.025));
      final Color color = cooled < 0.4
          ? Color.lerp(hot, warm, cooled / 0.4)!
          : Color.lerp(warm, ember, (cooled - 0.4) / 0.6)!;
      _paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = spark.size * (1 - 0.4 * cooled)
        ..color = color.withValues(alpha: 1 - cooled * cooled);
      canvas.drawLine(tail, head, _paint);
    }
  }

  static Offset _at(_Spark spark, double age) =>
      spark.origin +
      spark.velocity * age +
      Offset(0, 0.5 * _gravity * age * age);

  @override
  bool shouldRepaint(_WritingSparksPainter oldDelegate) =>
      oldDelegate.field != field ||
      oldDelegate.hot != hot ||
      oldDelegate.warm != warm ||
      oldDelegate.ember != ember;
}
