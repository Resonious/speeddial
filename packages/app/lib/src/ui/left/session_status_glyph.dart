import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../theme.dart';
import '../flame.dart';

/// Leading status mark of a session row: a live flame while the agent works,
/// an oven-timer ping while the turn waits on the user, otherwise a dot in
/// the status color. Ignites, rings and settles with a short transition.
class SessionStatusGlyph extends StatelessWidget {
  const SessionStatusGlyph({
    super.key,
    required this.status,
    required this.color,
    this.phase = 0,
    this.dormant = false,
  });

  final SessionStatus status;

  /// Dot color for the resting states (the row's status or done color).
  final Color color;

  /// Offsets the flame's flicker so neighbouring rows burn out of step.
  final double phase;

  /// The status is only the last one heard (the daemon is out of reach):
  /// the flame goes grey and still, and nothing pings.
  final bool dormant;

  @override
  Widget build(BuildContext context) {
    final SpeedDialColors colors = context.speedDialColors;
    final Widget glyph = switch (status) {
      SessionStatus.running => Flame(
        key: const ValueKey<String>('session-flame'),
        size: 16,
        phase: phase,
        dormant: dormant,
      ),
      SessionStatus.waitingPermission when dormant => _Dot(
        key: const ValueKey<String>('session-ping-dormant'),
        color: colors.idle,
      ),
      SessionStatus.waitingPermission => _TimerPing(
        key: const ValueKey<String>('session-ping'),
        color: colors.waitingPermission,
      ),
      _ => _Dot(key: ValueKey<Color>(color), color: color),
    };
    return SizedBox.square(
      dimension: 18,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 360),
        reverseDuration: const Duration(milliseconds: 240),
        transitionBuilder: _ignite,
        child: glyph,
      ),
    );
  }

  static final Animatable<double> _leap = CurveTween(curve: Curves.easeOutBack);

  /// Glyphs swell in past full size; outgoing ones puff and shrink away.
  static Widget _ignite(Widget child, Animation<double> animation) =>
      ScaleTransition(
        scale: animation.drive(_leap),
        child: FadeTransition(opacity: animation, child: child),
      );
}

class _Dot extends StatelessWidget {
  const _Dot({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    ),
  );
}

/// An amber dot whose ring keeps chiming outward, like an oven timer that
/// went off: the agent needs an answer.
class _TimerPing extends StatefulWidget {
  const _TimerPing({super.key, required this.color});

  final Color color;

  @override
  State<_TimerPing> createState() => _TimerPingState();
}

class _TimerPingState extends State<_TimerPing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ring = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _ring.value = 0.35;
    } else if (!_ring.isAnimating) {
      _ring.repeat();
    }
  }

  @override
  void dispose() {
    _ring.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      painter: _PingPainter(ring: _ring, color: widget.color),
      child: const SizedBox.expand(),
    ),
  );
}

class _PingPainter extends CustomPainter {
  _PingPainter({required this.ring, required this.color})
    : super(repaint: ring);

  final Animation<double> ring;
  final Color color;
  final Paint _dot = Paint();
  final Paint _wave = Paint()..style = PaintingStyle.stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = size.center(Offset.zero);
    final double t = ring.value;
    // The ring spends the last third of each cycle at rest, so the pings
    // read as distinct chimes rather than a steady throb.
    final double spread = math.min(1.0, t / 0.66);
    if (spread < 1) {
      _wave
        ..strokeWidth = 1.6 * (1 - spread) + 0.4
        ..color = color.withValues(alpha: 0.7 * (1 - spread));
      canvas.drawCircle(
        center,
        4 + 5 * Curves.easeOut.transform(spread),
        _wave,
      );
    }
    _dot.color = color;
    canvas.drawCircle(center, 4, _dot);
  }

  @override
  bool shouldRepaint(_PingPainter oldDelegate) =>
      oldDelegate.ring != ring || oldDelegate.color != color;
}
