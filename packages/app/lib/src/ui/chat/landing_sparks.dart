import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../theme.dart';

/// Embers kicked up along the bottom edge when the timeline jumps to its
/// latest event: the conversation lands on the hearth. Every increment of
/// [landings] sets off one burst; nothing paints or ticks in between, and
/// reduced motion skips the bursts entirely.
class LandingSparks extends StatefulWidget {
  const LandingSparks({super.key, required this.landings});

  final ValueListenable<int> landings;

  @override
  State<LandingSparks> createState() => _LandingSparksState();
}

class _LandingSparksState extends State<LandingSparks>
    with SingleTickerProviderStateMixin {
  late final AnimationController _burst = AnimationController(
    vsync: this,
    duration: _SparksPainter.span,
    value: 1,
  );
  List<_Spark> _sparks = const <_Spark>[];
  bool _still = false;

  @override
  void initState() {
    super.initState();
    widget.landings.addListener(_land);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  }

  @override
  void didUpdateWidget(LandingSparks oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.landings, widget.landings)) return;
    oldWidget.landings.removeListener(_land);
    widget.landings.addListener(_land);
  }

  @override
  void dispose() {
    widget.landings.removeListener(_land);
    _burst.dispose();
    super.dispose();
  }

  void _land() {
    if (_still) return;
    setState(() => _sparks = _Spark.burst(math.Random(widget.landings.value)));
    _burst.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SpeedDialColors colors = theme.speedDialColors;
    // White-hot sparks vanish against a light canvas; start them amber.
    final bool dark = theme.brightness == Brightness.dark;
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          key: const Key('landing-sparks'),
          size: Size.infinite,
          painter: _SparksPainter(
            burst: _burst,
            sparks: _sparks,
            hot: dark ? colors.flameCore : colors.flameTip,
            warm: dark ? colors.flameTip : theme.colorScheme.primary,
            ember: dark ? theme.colorScheme.primary : colors.flameRoot,
            glow: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

/// One ember: where along the edge it leaves, how hard it is thrown, and how
/// long it glows.
class _Spark {
  const _Spark({
    required this.x,
    required this.vx,
    required this.vy,
    required this.delay,
    required this.life,
    required this.width,
  });

  /// Launch point as a fraction of the edge's width.
  final double x;

  /// Launch velocity in logical pixels per second (negative is up).
  final double vx;
  final double vy;

  /// Seconds after landing before it leaves, and how long it then glows.
  final double delay;
  final double life;
  final double width;

  /// Enough embers for the widest timeline; narrow ones use a prefix. Each
  /// is thrown up to 70° off vertical, so the edge sprays like hot metal
  /// striking the hearth rather than drizzling straight up.
  static List<_Spark> burst(math.Random random) =>
      List<_Spark>.generate(32, (int _) {
        final double angle = (random.nextDouble() * 2 - 1) * 1.22;
        final double speed = 220 + 400 * random.nextDouble();
        return _Spark(
          x: 0.03 + 0.94 * random.nextDouble(),
          vx: speed * math.sin(angle),
          vy: -speed * math.cos(angle),
          delay: 0.06 * random.nextDouble(),
          life: 0.45 + 0.4 * random.nextDouble(),
          width: 1.4 + 1.2 * random.nextDouble(),
        );
      });
}

/// Throws each ember on a ballistic arc from the bottom edge, drawn as a
/// glowing head with a motion streak that cools from [hot] through [warm] to
/// [ember], over a brief [glow] where the conversation landed.
class _SparksPainter extends CustomPainter {
  _SparksPainter({
    required this.burst,
    required this.sparks,
    required this.hot,
    required this.warm,
    required this.ember,
    required this.glow,
  }) : super(repaint: burst);

  static const Duration span = Duration(milliseconds: 1000);
  static const double _gravity = 1400;
  static const double _streak = 0.035;

  final Animation<double> burst;
  final List<_Spark> sparks;
  final Color hot;
  final Color warm;
  final Color ember;
  final Color glow;
  final Paint _band = Paint();
  final Paint _line = Paint()..strokeCap = StrokeCap.round;
  final Paint _head = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    final double t = burst.value;
    if (t <= 0 || t >= 1 || sparks.isEmpty) return;
    final double seconds =
        t * span.inMicroseconds / Duration.microsecondsPerSecond;
    canvas.clipRect(Offset.zero & size);

    final double flash = 1 - math.min(1.0, seconds / 0.4);
    if (flash > 0) {
      final double top = size.height - 32;
      _band.shader = ui.Gradient.linear(
        Offset(0, top),
        Offset(0, size.height),
        <Color>[
          glow.withValues(alpha: 0),
          glow.withValues(alpha: 0.4 * flash * flash),
        ],
      );
      canvas.drawRect(Rect.fromLTRB(0, top, size.width, size.height), _band);
    }

    final int count = (size.width / 26).round().clamp(10, sparks.length);
    for (int i = 0; i < count; i++) {
      final _Spark spark = sparks[i];
      final double age = seconds - spark.delay;
      if (age <= 0 || age >= spark.life) continue;
      final Offset head = _at(spark, age, size);
      // Embers falling back below the edge drop out of sight.
      if (head.dy > size.height) continue;
      final Offset tail = _at(spark, math.max(0, age - _streak), size);
      final double cooled = age / spark.life;
      final Color color = cooled < 0.3
          ? Color.lerp(hot, warm, cooled / 0.3)!
          : Color.lerp(warm, ember, (cooled - 0.3) / 0.7)!;
      // Burns bright for most of its flight, then winks out.
      final double alpha = 1 - cooled * cooled;
      final double width = spark.width * (1 - 0.45 * cooled);
      // A faint wide pass under the streak reads as the ember's own glow.
      _line
        ..color = color.withValues(alpha: 0.2 * alpha)
        ..strokeWidth = width * 3.4;
      canvas.drawLine(tail, head, _line);
      _line
        ..color = color.withValues(alpha: 0.85 * alpha)
        ..strokeWidth = width;
      canvas.drawLine(tail, head, _line);
      _head.color = Color.lerp(hot, color, 0.4)!.withValues(alpha: alpha);
      canvas.drawCircle(head, width * 0.75, _head);
    }
  }

  static Offset _at(_Spark spark, double age, Size size) => Offset(
    spark.x * size.width + spark.vx * age,
    size.height + spark.vy * age + 0.5 * _gravity * age * age,
  );

  @override
  bool shouldRepaint(_SparksPainter oldDelegate) =>
      oldDelegate.burst != burst ||
      !identical(oldDelegate.sparks, sparks) ||
      oldDelegate.hot != hot ||
      oldDelegate.warm != warm ||
      oldDelegate.ember != ember ||
      oldDelegate.glow != glow;
}
