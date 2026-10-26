import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../theme.dart';
import '../flame.dart';
import 'idle_session_ember.dart';

/// Leading status mark of a session row: a live flame while the agent works,
/// an oven-timer ping while the turn waits on the user, a green dot once the
/// session is done, a cooling ember while it otherwise sits idle, else a dot
/// in the status color. Ignites, rings and settles with a short transition.
class SessionStatusGlyph extends StatelessWidget {
  const SessionStatusGlyph({
    super.key,
    required this.status,
    required this.color,
    this.lastActivityAt,
    this.done = false,
    this.phase = 0,
    this.dormant = false,
  });

  final SessionStatus status;

  /// Persisted activity time used to cool idle dots across app restarts.
  final DateTime? lastActivityAt;

  /// The session is marked done: a settled green dot instead of the ember.
  final bool done;

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
      SessionStatus.idle when done => _DoneDot(
        key: const ValueKey<String>('session-done'),
        color: colors.success,
      ),
      SessionStatus.idle when lastActivityAt != null => IdleSessionEmber(
        key: const ValueKey<String>('session-idle-ember'),
        lastActivityAt: lastActivityAt!,
        dormant: dormant,
      ),
      _ => _Dot(key: ValueKey<Color>(color), color: color),
    };
    return SizedBox.square(
      dimension: 18,
      child: AnimatedSwitcher(
        duration: (MediaQuery.maybeDisableAnimationsOf(context) ?? false)
            ? Duration.zero
            : const Duration(milliseconds: 360),
        reverseDuration: (MediaQuery.maybeDisableAnimationsOf(context) ?? false)
            ? Duration.zero
            : const Duration(milliseconds: 240),
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

/// A done session's dot: a touch larger than the rest, in a steady halo that
/// matches a hot ember's footprint so it never reads as the smaller mark.
class _DoneDot extends StatelessWidget {
  const _DoneDot({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: color.withValues(alpha: dark ? 0.55 : 0.35),
              blurRadius: 6,
              spreadRadius: 1.5,
            ),
          ],
        ),
      ),
    );
  }
}

/// An amber timer face that rattles and chimes twice outward, like an oven
/// timer that went off: the agent needs an answer.
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
    duration: const Duration(milliseconds: 1800),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _ring.value = 0.4;
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

  final Paint _bezel = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.8;

  /// Start of each chime within the cycle: a double "ding-ding".
  static const List<double> _chimes = <double>[0, 0.2];

  /// How much of the cycle one chime's wave takes to fade out.
  static const double _chimeLength = 0.5;

  /// The timer rattles while it rings, then sits still until the next chime.
  static const double _rattleLength = 0.36;

  @override
  void paint(Canvas canvas, Size size) {
    final double t = ring.value;
    // A ringed face with a centre pip, not a solid dot, so it can't be
    // mistaken for a warm idle ember even when the two colors are close.
    final double rattle = t < _rattleLength
        ? math.sin(t * math.pi * 2 * 9) * 0.9 * (1 - t / _rattleLength)
        : 0;
    final Offset center = size.center(Offset(rattle, 0));
    for (final double start in _chimes) {
      final double spread = (t - start) / _chimeLength;
      if (spread < 0 || spread >= 1) continue;
      _wave
        ..strokeWidth = 1.8 * (1 - spread) + 0.4
        ..color = color.withValues(alpha: 0.8 * (1 - spread));
      canvas.drawCircle(
        size.center(Offset.zero),
        5 + 4 * Curves.easeOut.transform(spread),
        _wave,
      );
    }
    _bezel.color = color;
    canvas.drawCircle(center, 4.6, _bezel);
    _dot.color = color;
    canvas.drawCircle(center, 1.9, _dot);
  }

  @override
  bool shouldRepaint(_PingPainter oldDelegate) =>
      oldDelegate.ring != ring || oldDelegate.color != color;
}
