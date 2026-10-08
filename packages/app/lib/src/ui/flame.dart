import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme.dart';

/// How hard a [Flame] burns.
enum FlameIntensity {
  /// A full, licking flame: the agent is working.
  blaze,

  /// A low blue pilot light: the turn is paused on the user.
  pilot,
}

/// SpeedDial's "the oven is on" glyph: a hand-painted flame flickering
/// through a seamless loop while an agent turn is in progress.
///
/// Only repaints itself (never rebuilds) behind a [RepaintBoundary].
/// Changing [intensity] turns the flame up or down smoothly. Holds one still
/// frame when the platform asks for reduced motion, or when [dormant].
class Flame extends StatefulWidget {
  const Flame({
    super.key,
    this.size = 16,
    this.intensity = FlameIntensity.blaze,
    this.phase = 0,
    this.glow = false,
    this.dormant = false,
  });

  /// Height of the glyph; it is three quarters as wide.
  final double size;

  final FlameIntensity intensity;

  /// Offset into the flicker loop, in loops, so neighbouring flames do not
  /// flicker in lockstep.
  final double phase;

  /// Casts warm light around the flame and sends up the odd ember. Meant for
  /// larger flames; both spill outside the glyph's box.
  final bool glow;

  /// Grey and still: what the flame stands for cannot be vouched for right
  /// now (its daemon is out of reach). Fades in and out of grey.
  final bool dormant;

  @override
  State<Flame> createState() => _FlameState();
}

class _FlameState extends State<Flame> with TickerProviderStateMixin {
  late final AnimationController _flicker = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3200),
  );
  late final AnimationController _heat = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 450),
    value: _heatFor(widget.intensity),
  );
  late final Animation<double> _heatCurve = CurvedAnimation(
    parent: _heat,
    curve: Curves.easeInOut,
  );

  /// 1 when fully grey.
  late final AnimationController _dormancy = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
    value: widget.dormant ? 1 : 0,
  );
  bool _still = false;

  static double _heatFor(FlameIntensity intensity) =>
      intensity == FlameIntensity.blaze ? 1 : 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _syncFlicker();
  }

  @override
  void didUpdateWidget(Flame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.intensity != oldWidget.intensity) {
      final double target = _heatFor(widget.intensity);
      if (_still) {
        _heat.value = target;
      } else {
        _heat.animateTo(target);
      }
    }
    if (widget.dormant != oldWidget.dormant) {
      final double target = widget.dormant ? 1 : 0;
      if (_still) {
        _dormancy.value = target;
      } else {
        _dormancy.animateTo(target);
      }
      _syncFlicker();
    }
  }

  void _syncFlicker() {
    if (_still) {
      // Setting the value also stops a running loop.
      _flicker.value = 0.2;
    } else if (widget.dormant) {
      _flicker.stop();
    } else if (!_flicker.isAnimating) {
      _flicker.repeat();
    }
  }

  @override
  void dispose() {
    _flicker.dispose();
    _heat.dispose();
    _dormancy.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SpeedDialColors colors = theme.speedDialColors;
    return RepaintBoundary(
      child: CustomPaint(
        size: Size(widget.size * 0.75, widget.size),
        painter: _FlamePainter(
          flicker: _flicker,
          heat: _heatCurve,
          dormancy: _dormancy,
          phase: widget.phase,
          glow: widget.glow,
          glowStrength: theme.brightness == Brightness.dark ? 1 : 0.45,
          body: theme.colorScheme.primary,
          root: colors.flameRoot,
          tip: colors.flameTip,
          core: colors.flameCore,
          pilot: colors.running,
          // Greys on either side of the idle grey: toward the canvas at the
          // root, toward the ink in the core.
          ash: colors.idle,
          soot: Color.lerp(colors.idle, theme.colorScheme.surface, 0.35)!,
          cinder: Color.lerp(colors.idle, theme.colorScheme.onSurface, 0.45)!,
        ),
      ),
    );
  }
}

/// Paints the flame as a body with a side tongue around a teardrop core,
/// each licking independently. The flicker sums integer harmonics of the
/// loop, so it reads as irregular yet wraps without a seam.
///
/// Shapes are built in a normalized space (x in -1..1 across the flame,
/// y from 0 at the base to 1 at the tip) mapped onto the glyph by the
/// canvas transform, so the cached gradients always span the flame itself.
class _FlamePainter extends CustomPainter {
  _FlamePainter({
    required this.flicker,
    required this.heat,
    required this.dormancy,
    required this.phase,
    required this.glow,
    required this.glowStrength,
    required this.body,
    required this.root,
    required this.tip,
    required this.core,
    required this.pilot,
    required this.ash,
    required this.soot,
    required this.cinder,
  }) : super(repaint: Listenable.merge(<Listenable>[flicker, heat, dormancy]));

  final Animation<double> flicker;

  /// 1 for a full blaze, 0 for the pilot light.
  final Animation<double> heat;

  /// 1 when the flame has gone fully grey.
  final Animation<double> dormancy;
  final double phase;
  final bool glow;

  /// Cast light reads as a stain on light surfaces; keep it fainter there.
  final double glowStrength;
  final Color body;
  final Color root;
  final Color tip;
  final Color core;
  final Color pilot;

  /// Greys a dormant flame takes on for its body, root and core.
  final Color ash;
  final Color soot;
  final Color cinder;

  final Path _body = Path();
  final Path _core = Path();
  final Paint _fill = Paint();
  final Paint _spot = Paint();

  // Gradients live in the normalized space and depend only on heat and
  // dormancy, so they survive the flicker (and any resize).
  double? _shadedHeat;
  double? _shadedDormancy;
  late ui.Shader _bodyShader;
  late ui.Shader _coreShader;
  late ui.Shader _glowShader;

  static const double _tau = 2 * math.pi;

  @override
  void paint(Canvas canvas, Size size) {
    final double heat = this.heat.value;
    final double w = size.width;
    final double h = size.height;
    final double a = _tau * (flicker.value + phase);
    // A pilot light burns low and steady; a blaze leaps.
    final double motion = ui.lerpDouble(0.3, 1, heat)!;
    final double sway =
        motion *
        (0.55 * math.sin(2 * a) +
            0.3 * math.sin(5 * a + 1.3) +
            0.15 * math.sin(11 * a + 0.4));
    final double lick =
        motion *
        (0.5 * math.sin(3 * a + 0.7) +
            0.3 * math.sin(7 * a + 2.1) +
            0.2 * math.sin(13 * a + 4));
    final double flutter =
        motion * (0.6 * math.sin(4 * a + 2.6) + 0.4 * math.sin(9 * a + 1.1));
    final double coreSway =
        motion * (0.6 * math.sin(3 * a + 2.2) + 0.4 * math.sin(8 * a + 0.9));

    final double dormancy = this.dormancy.value;
    _shade(heat, dormancy);

    final double halfWidth = w * 0.5 * ui.lerpDouble(0.62, 0.94, heat)!;
    final double height = h * ui.lerpDouble(0.55, 0.97, heat)!;
    final double tipY = 0.95 + 0.05 * lick;

    if (glow && dormancy < 1) {
      canvas
        ..save()
        ..translate(w / 2, h - height * 0.42)
        ..scale(height * (0.95 + 0.07 * lick));
      _fill.shader = _glowShader;
      canvas
        ..drawCircle(Offset.zero, 1, _fill)
        ..restore();
    }

    canvas
      ..save()
      ..translate(w / 2, h * 0.99)
      ..scale(halfWidth, -height);
    _outline(
      _body,
      tipX: 0.12 + 0.2 * sway,
      tipY: tipY,
      tongueX: -0.6 + 0.1 * flutter,
      tongueY: ui.lerpDouble(0.5, 0.74, heat)! + 0.08 * flutter,
    );
    _fill.shader = _bodyShader;
    canvas.drawPath(_body, _fill);
    _teardrop(_core, tipX: 0.04 + 0.16 * coreSway, tipY: 0.6 + 0.07 * lick);
    _fill.shader = _coreShader;
    canvas
      ..drawPath(_core, _fill)
      ..restore();

    if (glow && heat > 0.5 && dormancy < 0.5) {
      _paintEmbers(canvas, w, h, h * 0.99 - height * tipY, heat);
    }
  }

  /// Three sparks leave the tip and fade as they rise; each rises a whole
  /// number of times per loop so the loop stays seamless.
  void _paintEmbers(
    Canvas canvas,
    double w,
    double h,
    double tipY,
    double heat,
  ) {
    for (int i = 0; i < 3; i++) {
      final double rise = (flicker.value * (i + 2) + phase + i * 0.37) % 1;
      final double fade = math.sin(math.pi * rise) * (1 - rise);
      if (fade <= 0.01) continue;
      final double x =
          w / 2 +
          w * (i - 1) * 0.18 +
          w * 0.1 * math.sin(_tau * (rise * 1.5 + i * 0.3));
      final double y = tipY + h * 0.22 - rise * h * 0.62;
      _spot.color = tip.withValues(alpha: 0.9 * fade * (heat - 0.5) * 2);
      canvas.drawCircle(Offset(x, y), w * 0.055 * (1 - 0.5 * rise), _spot);
    }
  }

  void _shade(double heat, double dormancy) {
    if (heat == _shadedHeat && dormancy == _shadedDormancy) return;
    _shadedHeat = heat;
    _shadedDormancy = dormancy;
    final double cool = 1 - heat;
    Color grey(Color color, Color to) => Color.lerp(color, to, dormancy)!;
    final Color pilotCore = Color.lerp(pilot, const Color(0xFFFFFFFF), 0.6)!;
    _bodyShader = ui.Gradient.linear(
      Offset.zero,
      const Offset(0, 1),
      <Color>[
        grey(Color.lerp(root, pilot, cool)!, soot),
        grey(Color.lerp(body, pilot.withValues(alpha: 0.85), cool)!, ash),
        grey(
          Color.lerp(
            Color.lerp(body, tip, 0.3),
            pilot.withValues(alpha: 0.15),
            cool,
          )!,
          ash,
        ),
      ],
      const <double>[0, 0.5, 1],
    );
    _coreShader = ui.Gradient.linear(
      Offset.zero,
      const Offset(0, 0.66),
      <Color>[
        grey(Color.lerp(core, pilotCore, cool)!, cinder),
        grey(Color.lerp(tip, pilotCore.withValues(alpha: 0.5), cool)!, ash),
      ],
    );
    final Color light = Color.lerp(body, pilot, cool)!;
    _glowShader = ui.Gradient.radial(Offset.zero, 1, <Color>[
      light.withValues(
        alpha: glowStrength * (0.32 * heat + 0.14 * cool) * (1 - dormancy),
      ),
      light.withValues(alpha: 0),
    ]);
  }

  /// Flame body: a round base swelling up into a main tip at
  /// ([tipX], [tipY]), with a smaller tongue licking up on the left.
  static void _outline(
    Path path, {
    required double tipX,
    required double tipY,
    required double tongueX,
    required double tongueY,
  }) {
    path
      ..reset()
      ..moveTo(tipX, tipY)
      ..cubicTo(tipX + 0.1, tipY - 0.22, 0.86, 0.66, 0.86, 0.34)
      ..cubicTo(0.86, 0.13, 0.5, 0, 0, 0)
      ..cubicTo(-0.5, 0, -0.86, 0.13, -0.86, 0.34)
      ..cubicTo(-0.86, 0.5, tongueX - 0.1, tongueY - 0.22, tongueX, tongueY)
      ..cubicTo(
        tongueX + 0.06,
        tongueY - 0.14,
        -0.32,
        tongueY - 0.2,
        -0.2,
        tongueY - 0.16,
      )
      // Control points stay ordered left to right whichever way the tip
      // sways, so the notch never kinks.
      ..cubicTo(
        ui.lerpDouble(-0.2, tipX, 0.4)!,
        tongueY - 0.08,
        tipX - 0.03,
        tipY - 0.25,
        tipX,
        tipY,
      )
      ..close();
  }

  /// Inner core: a teardrop on the flame's base tapering to ([tipX], [tipY]).
  static void _teardrop(
    Path path, {
    required double tipX,
    required double tipY,
  }) {
    path
      ..reset()
      ..moveTo(tipX, tipY)
      ..cubicTo(tipX + 0.06, tipY - 0.14, 0.5, 0.42, 0.5, 0.25)
      ..cubicTo(0.5, 0.12, 0.28, 0.05, 0, 0.05)
      ..cubicTo(-0.28, 0.05, -0.5, 0.12, -0.5, 0.25)
      ..cubicTo(-0.5, 0.42, tipX - 0.06, tipY - 0.14, tipX, tipY)
      ..close();
  }

  @override
  bool shouldRepaint(_FlamePainter oldDelegate) =>
      oldDelegate.flicker != flicker ||
      oldDelegate.heat != heat ||
      oldDelegate.dormancy != dormancy ||
      oldDelegate.ash != ash ||
      oldDelegate.soot != soot ||
      oldDelegate.cinder != cinder ||
      oldDelegate.phase != phase ||
      oldDelegate.glow != glow ||
      oldDelegate.glowStrength != glowStrength ||
      oldDelegate.body != body ||
      oldDelegate.root != root ||
      oldDelegate.tip != tip ||
      oldDelegate.core != core ||
      oldDelegate.pilot != pilot;
}
