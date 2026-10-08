import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme.dart';

/// The heat of something in progress, for the widgets showing it: [level]
/// rises while it is active and cools after, and [sweep] runs while it is
/// hot (flickering icons, sweeping glints). The animations are made the
/// first time it is active; [onCooled] fires once it has cooled right down.
class Heat {
  Heat(this._vsync, {required this.onCooled});

  final TickerProvider _vsync;
  final VoidCallback onCooled;
  AnimationController? _level;
  AnimationController? _sweep;

  /// 1 while active, cooling to 0 after.
  Animation<double> get level => _level ?? kAlwaysDismissedAnimation;

  /// Runs from 0 to 1 over and over while hot; still at 0 otherwise.
  Animation<double> get sweep => _sweep ?? kAlwaysDismissedAnimation;

  /// Whether there is any heat to show.
  bool get hot => _level?.isDismissed == false;

  void sync({required bool active, required bool still}) {
    if (active) {
      final AnimationController level = _level ??= AnimationController(
        vsync: _vsync,
        duration: const Duration(milliseconds: 240),
        reverseDuration: const Duration(milliseconds: 900),
      )..addStatusListener(_onStatus);
      final AnimationController sweep = _sweep ??= AnimationController(
        vsync: _vsync,
        duration: const Duration(milliseconds: 1700),
      );
      if (still) {
        level.value = 1;
        sweep.value = 0;
      } else {
        level.forward();
        if (!sweep.isAnimating) sweep.repeat();
      }
      return;
    }
    final AnimationController? level = _level;
    if (level == null) return;
    if (still) {
      level.value = 0;
    } else {
      level.reverse();
    }
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed) return;
    // Setting the value stops the sweep.
    _sweep?.value = 0;
    onCooled();
  }

  void dispose() {
    _level?.dispose();
    _sweep?.dispose();
  }
}

/// A kind icon that heats up while [active] and cools back to [color] after
/// (see [HotToolIcon]).
class HeatedIcon extends StatefulWidget {
  const HeatedIcon({
    super.key,
    required this.icon,
    required this.color,
    required this.active,
    this.size = 16,
  });

  final IconData icon;
  final Color color;
  final bool active;
  final double size;

  @override
  State<HeatedIcon> createState() => _HeatedIconState();
}

class _HeatedIconState extends State<HeatedIcon> with TickerProviderStateMixin {
  late final Heat _heat = Heat(this, onCooled: _cooled);
  bool _still = false;

  void _cooled() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _heat.sync(active: widget.active, still: _still);
  }

  @override
  void didUpdateWidget(HeatedIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active != oldWidget.active) {
      _heat.sync(active: widget.active, still: _still);
    }
  }

  @override
  void dispose() {
    _heat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_heat.hot) {
      return Icon(widget.icon, size: widget.size, color: widget.color);
    }
    return HotToolIcon(
      icon: widget.icon,
      color: widget.color,
      heat: _heat.level,
      flicker: _heat.sweep,
      size: widget.size,
    );
  }
}

/// A tool's kind icon while its call is on the heat: it glows hot over
/// [color], flickering with [flicker]'s sweep, and cools back to [color] as
/// [heat] falls. Animates by repainting alone.
class HotToolIcon extends StatelessWidget {
  const HotToolIcon({
    super.key,
    required this.icon,
    required this.color,
    required this.heat,
    required this.flicker,
    this.size = 16,
  });

  final IconData icon;

  /// The icon's resting color.
  final Color color;
  final Animation<double> heat;
  final Animation<double> flicker;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SpeedDialColors colors = theme.speedDialColors;
    final bool dark = theme.brightness == Brightness.dark;
    final Animation<double> glow = _Flicker(heat, flicker);
    return RepaintBoundary(
      child: CustomPaint(
        painter: _HaloPainter(
          glow: glow,
          color: colors.flameRoot,
          // Light reads as a stain on light surfaces; keep it fainter there.
          strength: dark ? 0.5 : 0.3,
        ),
        child: Stack(
          children: <Widget>[
            Icon(icon, size: size, color: color),
            FadeTransition(
              opacity: glow,
              child: Icon(
                icon,
                size: size,
                // Amber is lost on a light surface; burn deeper there.
                color: dark ? colors.flameTip : colors.flameRoot,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// [first] (the heat) with a flicker riding on it, read off [next]'s
/// repeating sweep. Whole-number frequencies keep it seamless as the sweep
/// wraps around.
class _Flicker extends CompoundAnimation<double> {
  _Flicker(Animation<double> heat, Animation<double> flicker)
    : super(first: heat, next: flicker);

  @override
  double get value {
    final double t = next.value * 2 * math.pi;
    return first.value *
        (0.82 + 0.1 * math.sin(3 * t) + 0.08 * math.sin(7 * t));
  }
}

class _HaloPainter extends CustomPainter {
  _HaloPainter({
    required this.glow,
    required this.color,
    required this.strength,
  }) : super(repaint: glow);

  final Animation<double> glow;
  final Color color;
  final double strength;
  final Paint _paint = Paint()
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);

  @override
  void paint(Canvas canvas, Size size) {
    final double amount = glow.value;
    if (amount <= 0) return;
    _paint.color = color.withValues(alpha: strength * amount);
    canvas.drawCircle(
      size.center(Offset.zero),
      size.shortestSide * 0.6,
      _paint,
    );
  }

  @override
  bool shouldRepaint(_HaloPainter oldDelegate) =>
      oldDelegate.glow != glow ||
      oldDelegate.color != color ||
      oldDelegate.strength != strength;
}

/// "4s", "1m 05s", "1h 02m".
String formatElapsed(Duration elapsed) {
  final int seconds = elapsed.inSeconds;
  if (seconds < 60) return '${seconds}s';
  final int minutes = elapsed.inMinutes;
  if (minutes < 60) {
    return '${minutes}m ${(seconds % 60).toString().padLeft(2, '0')}s';
  }
  return '${elapsed.inHours}h ${(minutes % 60).toString().padLeft(2, '0')}m';
}

/// How long a call has been going (see [formatElapsed]), shown once it
/// passes a second. Counts up while [running] and holds still after.
class ElapsedTime extends StatefulWidget {
  const ElapsedTime({
    super.key,
    required this.since,
    required this.running,
    this.style,
  });

  /// When the call started, by the daemon's clock; counts from now when
  /// unknown.
  final DateTime? since;
  final bool running;
  final TextStyle? style;

  @override
  State<ElapsedTime> createState() => _ElapsedTimeState();
}

class _ElapsedTimeState extends State<ElapsedTime> {
  late Duration _elapsed = _sinceStart();
  Timer? _timer;

  Duration _sinceStart() {
    final DateTime? since = widget.since;
    if (since == null) return Duration.zero;
    final Duration elapsed = DateTime.now().difference(since);
    // A client clock behind the daemon's would count from below zero.
    return elapsed.isNegative ? Duration.zero : elapsed;
  }

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(ElapsedTime oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.since != oldWidget.since) _elapsed = _sinceStart();
    _sync();
  }

  void _sync() {
    if (!widget.running) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _elapsed += const Duration(seconds: 1));
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_elapsed < const Duration(seconds: 1)) return const SizedBox.shrink();
    return Text(formatElapsed(_elapsed), style: widget.style);
  }
}
