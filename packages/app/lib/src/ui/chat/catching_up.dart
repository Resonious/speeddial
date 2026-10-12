import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../theme.dart';
import '../flame.dart';
import 'heat_shimmer.dart';

/// Shown while a reconnected daemon's missed events are refetched, which
/// leaves the timeline above stale: a strip rises from the composer with a
/// small flame and a shimmering "Catching up…", and a haze warms the bottom
/// of the timeline as if reheating it. When the catch-up lands the haze
/// blooms and the strip folds away.
///
/// A catch-up quicker than a blink never shows. Reduced motion shows and
/// hides it at once, still.
class CatchingUpStrip extends StatefulWidget {
  const CatchingUpStrip({super.key, required this.active});

  final bool active;

  /// How long a catch-up may take before the strip shows at all.
  static const Duration patience = Duration(milliseconds: 150);

  @override
  State<CatchingUpStrip> createState() => _CatchingUpStripState();
}

class _CatchingUpStripState extends State<CatchingUpStrip>
    with TickerProviderStateMixin {
  late final AnimationController _shown = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
    reverseDuration: const Duration(milliseconds: 200),
  )..addStatusListener(_onStatus);
  late final Animation<double> _size = CurvedAnimation(
    parent: _shown,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  /// Sweeps the label's glint and lets the haze breathe.
  late final AnimationController _glint = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  /// The haze's warm swell as the catch-up lands.
  late final AnimationController _bloom = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  )..addStatusListener(_onStatus);

  Timer? _wait;
  bool _still = false;

  bool get _visible => !_shown.isDismissed || _bloom.isAnimating;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _sync();
  }

  @override
  void didUpdateWidget(CatchingUpStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active != oldWidget.active) _sync();
  }

  void _sync() {
    if (widget.active) {
      if (_still) {
        _wait?.cancel();
        _wait = null;
        _glint.value = 0;
        _shown.value = 1;
      } else if (_shown.status == AnimationStatus.reverse) {
        // Back before it had folded away.
        _shown.forward();
      } else if (_shown.isDismissed && _wait == null) {
        _wait = Timer(CatchingUpStrip.patience, () {
          _wait = null;
          if (mounted && widget.active) _shown.forward();
        });
      }
      if (!_still && !_shown.isDismissed && !_glint.isAnimating) {
        _glint.repeat();
      }
      return;
    }
    _wait?.cancel();
    _wait = null;
    // Gone, or already going.
    if (_shown.isDismissed || _shown.status == AnimationStatus.reverse) return;
    if (_still) {
      _shown.value = 0;
    } else {
      _bloom.forward(from: 0);
      _shown.reverse();
    }
  }

  void _onStatus(AnimationStatus status) {
    if (!mounted) return;
    if (_shown.status == AnimationStatus.forward && !_glint.isAnimating) {
      _glint.repeat();
    }
    if (!_visible) _glint.stop();
    // Mounts the strip as it starts to show, and clears it once gone.
    setState(() {});
  }

  @override
  void dispose() {
    _wait?.cancel();
    _shown.dispose();
    _glint.dispose();
    _bloom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    final ThemeData theme = Theme.of(context);
    final SpeedDialColors colors = theme.speedDialColors;
    final bool dark = theme.brightness == Brightness.dark;
    return CustomPaint(
      key: const Key('catching-up'),
      painter: _HazePainter(
        shown: _shown,
        breath: _glint,
        bloom: _bloom,
        color: colors.flameTip,
        strength: dark ? 1 : 0.55,
      ),
      child: SizeTransition(
        sizeFactor: _size,
        // Rises from the composer: its bottom edge shows first.
        alignment: Alignment.bottomCenter,
        child: FadeTransition(
          opacity: _size,
          child: Material(
            color: theme.colorScheme.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                children: <Widget>[
                  const Flame(size: 14),
                  const SizedBox(width: 8),
                  Flexible(
                    child: HeatShimmer(
                      animation: _glint,
                      glint: colors.flameTip,
                      color: theme.colorScheme.onSurfaceVariant,
                      child: Text(
                        'Catching up…',
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Warm haze rising off the strip over the bottom of the timeline: it
/// breathes while the catch-up runs and swells once as it lands.
class _HazePainter extends CustomPainter {
  _HazePainter({
    required this.shown,
    required this.breath,
    required this.bloom,
    required this.color,
    required this.strength,
  }) : super(repaint: Listenable.merge(<Listenable>[shown, breath, bloom]));

  final Animation<double> shown;
  final Animation<double> breath;
  final Animation<double> bloom;
  final Color color;

  /// Light reads as a stain on light surfaces; keep it fainter there.
  final double strength;

  /// How far above the strip the haze reaches.
  static const double reach = 80;

  final Paint _paint = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    final double breathing = 0.8 + 0.2 * math.sin(2 * math.pi * breath.value);
    final double heat =
        0.16 *
        strength *
        (shown.value * breathing + 0.55 * math.sin(math.pi * bloom.value));
    if (heat <= 0.004) return;
    _paint.shader = ui.Gradient.linear(
      const Offset(0, -reach),
      Offset.zero,
      <Color>[color.withValues(alpha: 0), color.withValues(alpha: heat)],
    );
    canvas.drawRect(Rect.fromLTRB(0, -reach, size.width, 0), _paint);
  }

  @override
  bool shouldRepaint(_HazePainter oldDelegate) =>
      oldDelegate.shown != shown ||
      oldDelegate.breath != breath ||
      oldDelegate.bloom != bloom ||
      oldDelegate.color != color ||
      oldDelegate.strength != strength;
}

/// A row that came in with a catch-up, rising into place: after [delay] it
/// fades in from a little below. A row built without a delay shows as it
/// is, and rebuilds never restart it, so a row scrolled away and back
/// stays put. Reduced motion shows it at once.
class ArrivalRise extends StatefulWidget {
  const ArrivalRise({super.key, required this.delay, required this.child});

  final Duration? delay;
  final Widget child;

  /// How long one row takes to rise, once its turn comes.
  static const Duration rise = Duration(milliseconds: 360);

  @override
  State<ArrivalRise> createState() => _ArrivalRiseState();
}

class _ArrivalRiseState extends State<ArrivalRise>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  Animation<double>? _rise;

  @override
  void initState() {
    super.initState();
    final Duration? delay = widget.delay;
    if (delay == null) return;
    // The wait is the start of one animation, so nothing is left pending.
    final Duration total = delay + ArrivalRise.rise;
    final AnimationController controller = AnimationController(
      vsync: this,
      duration: total,
    );
    _controller = controller;
    _rise = CurvedAnimation(
      parent: controller,
      curve: Interval(
        delay.inMicroseconds / total.inMicroseconds,
        1,
        curve: Curves.easeOutCubic,
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final AnimationController? controller = _controller;
    if (controller == null || !controller.isDismissed) return;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      controller.value = 1;
    } else {
      controller.forward();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Animation<double>? rise = _rise;
    if (rise == null) return widget.child;
    return FadeTransition(
      key: const Key('arrival-rise'),
      opacity: rise,
      child: AnimatedBuilder(
        animation: rise,
        builder: (BuildContext context, Widget? child) => Transform.translate(
          offset: Offset(0, 16 * (1 - rise.value)),
          child: child,
        ),
        child: widget.child,
      ),
    );
  }
}
