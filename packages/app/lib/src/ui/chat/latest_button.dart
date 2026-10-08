import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../flame.dart';

/// The jump-to-latest button, kept warm by what happens below it.
///
/// Each change of [activity] fans it like an ember: it flares up with a glow
/// and a few flames licking up from behind it, and cools off once things go
/// quiet. Steady streaming keeps it burning rather than strobing; the first
/// activity after a lull also bumps it down, toward the news. Holds still
/// when the platform asks for reduced motion.
class LatestButton extends StatefulWidget {
  const LatestButton({
    super.key,
    required this.activity,
    required this.onPressed,
  });

  /// Changes whenever content arrives at the timeline's live end.
  final int activity;
  final VoidCallback onPressed;

  @override
  State<LatestButton> createState() => _LatestButtonState();
}

class _LatestButtonState extends State<LatestButton>
    with TickerProviderStateMixin {
  /// 0 is cold; each activity stokes it toward 1, then it cools back down.
  late final AnimationController _heat = AnimationController(vsync: this);
  late final AnimationController _bump = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  late final Listenable _motion = Listenable.merge(<Listenable>[_heat, _bump]);
  bool _still = false;

  /// Distance the button drops when activity breaks a lull.
  static const double _drop = 5;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (_still) {
      _heat.value = 0;
      _bump.value = 0;
    }
  }

  @override
  void didUpdateWidget(LatestButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.activity != oldWidget.activity) _stoke();
  }

  void _stoke() {
    if (_still) return;
    final bool lull = _heat.value < 0.25;
    final double heat = math.min(1.0, _heat.value + 0.5);
    _heat
      ..value = heat
      // Holds its heat for a moment, then cools ever faster.
      ..animateTo(
        0,
        duration: Duration(milliseconds: (1400 * heat).round()),
        curve: Curves.easeInQuad,
      );
    if (lull && !_bump.isAnimating) _bump.forward(from: 0);
  }

  @override
  void dispose() {
    _heat.dispose();
    _bump.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color glow = Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: _motion,
      builder: (BuildContext context, Widget? button) {
        final double heat = _heat.value;
        return Transform.translate(
          offset: Offset(0, _drop * math.sin(math.pi * _bump.value)),
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: <Widget>[
              // Rising from just behind the button's top edge (it sits
              // centered here whatever its tap-target padding). Even a
              // single flare shows clear flames.
              if (heat > 0.02)
                Transform.translate(
                  offset: const Offset(0, -27),
                  child: IgnorePointer(
                    child: Opacity(
                      // Gutters out before it is unmounted.
                      opacity: math.min(1.0, heat * 4),
                      child: Transform.scale(
                        key: const Key('latest-flames'),
                        scale: 0.45 + 0.55 * heat,
                        alignment: Alignment.bottomCenter,
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: <Widget>[
                            Flame(size: 14, phase: 0.13),
                            Flame(size: 20, phase: 0.58),
                            Flame(size: 14, phase: 0.81),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              CustomPaint(
                painter: _GlowPainter(heat: heat, color: glow),
                child: button,
              ),
            ],
          ),
        );
      },
      child: FloatingActionButton.small(
        heroTag: null,
        tooltip: 'Jump to latest event',
        onPressed: widget.onPressed,
        child: const Icon(Icons.arrow_downward),
      ),
    );
  }
}

/// Warm light around the small button (40 px, rounded 12) while it is hot.
class _GlowPainter extends CustomPainter {
  _GlowPainter({required this.heat, required this.color});

  final double heat;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (heat <= 0.02) return;
    final RRect button = RRect.fromRectAndRadius(
      Rect.fromCenter(center: size.center(Offset.zero), width: 40, height: 40),
      const Radius.circular(12),
    );
    canvas.drawRRect(
      button.inflate(1 + 4 * heat),
      Paint()
        ..color = color.withValues(alpha: 0.55 * heat)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 3 + 7 * heat),
    );
  }

  @override
  bool shouldRepaint(_GlowPainter oldDelegate) =>
      oldDelegate.heat != heat || oldDelegate.color != color;
}
