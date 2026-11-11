import 'package:flutter/material.dart';

import '../../theme.dart';

/// Round checkbox for a note. Checking it off is a small oven moment: the
/// ring fills with ember, the check pops in with a springy overshoot, and a
/// warm halo blooms around it and cools. Unchecking, first builds and
/// reduced motion show the end state at once; nothing ticks once settled.
class NoteCheck extends StatefulWidget {
  const NoteCheck({
    super.key,
    required this.checked,
    required this.onChanged,
    this.size = 18,
  });

  final bool checked;
  final ValueChanged<bool>? onChanged;
  final double size;

  @override
  State<NoteCheck> createState() => _NoteCheckState();
}

class _NoteCheckState extends State<NoteCheck>
    with SingleTickerProviderStateMixin {
  static const Duration _duration = Duration(milliseconds: 650);

  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: _duration,
    value: 1,
  );

  @override
  void didUpdateWidget(NoteCheck oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.checked == oldWidget.checked) return;
    if (widget.checked && !MediaQuery.of(context).disableAnimations) {
      _pop.forward(from: 0);
    } else {
      _pop.value = 1;
    }
  }

  @override
  void dispose() {
    _pop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SpeedDialColors colors = context.speedDialColors;
    final bool dark = theme.brightness == Brightness.dark;
    return Semantics(
      checked: widget.checked,
      button: true,
      child: InkResponse(
        onTap: widget.onChanged == null
            ? null
            : () => widget.onChanged!(!widget.checked),
        radius: widget.size,
        child: SizedBox.square(
          dimension: widget.size + 8,
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _NoteCheckPainter(
                pop: _pop,
                checked: widget.checked,
                ember: theme.colorScheme.primary,
                halo: dark ? colors.flameTip : colors.flameRoot,
                ring: theme.colorScheme.onSurfaceVariant,
                tick: theme.colorScheme.onPrimary,
                glowStrength: dark ? 0.55 : 0.35,
                diameter: widget.size,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NoteCheckPainter extends CustomPainter {
  _NoteCheckPainter({
    required this.pop,
    required this.checked,
    required this.ember,
    required this.halo,
    required this.ring,
    required this.tick,
    required this.glowStrength,
    required this.diameter,
  }) : super(repaint: pop);

  final Animation<double> pop;
  final bool checked;
  final Color ember;
  final Color halo;
  final Color ring;
  final Color tick;
  final double glowStrength;
  final double diameter;

  final Paint _fill = Paint();
  final Paint _stroke = Paint()..style = PaintingStyle.stroke;
  final Paint _glow = Paint();
  final Path _tick = Path();

  static final Animatable<double> _tickScale = TweenSequence<double>(
    <TweenSequenceItem<double>>[
      TweenSequenceItem<double>(
        tween: Tween<double>(
          begin: 0.3,
          end: 1.25,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 30,
      ),
      TweenSequenceItem<double>(
        tween: Tween<double>(
          begin: 1.25,
          end: 0.95,
        ).chain(CurveTween(curve: Curves.easeInOut)),
        weight: 25,
      ),
      TweenSequenceItem<double>(
        tween: Tween<double>(
          begin: 0.95,
          end: 1,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 20,
      ),
      TweenSequenceItem<double>(tween: ConstantTween<double>(1), weight: 25),
    ],
  );

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = size.center(Offset.zero);
    final double radius = diameter / 2;
    final double t = pop.value;
    if (!checked) {
      _stroke
        ..color = ring.withValues(alpha: 0.7)
        ..strokeWidth = 1.5;
      canvas.drawCircle(center, radius - 0.75, _stroke);
      return;
    }
    // Halo: blooms quickly and cools over the rest of the pop.
    if (t < 1) {
      final double heat = t < 0.15
          ? Curves.easeOut.transform(t / 0.15)
          : 1 - Curves.easeInOut.transform((t - 0.15) / 0.85);
      if (heat > 0.01) {
        _glow
          ..color = halo.withValues(alpha: glowStrength * heat)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 2 + 4 * heat);
        canvas.drawCircle(center, radius + 1 + 3 * heat, _glow);
      }
    }
    final double fill = Curves.easeOut.transform((t / 0.3).clamp(0.0, 1.0));
    _fill.color = Color.lerp(ring.withValues(alpha: 0), ember, fill)!;
    canvas.drawCircle(center, radius, _fill);
    final double scale = _tickScale.transform(t);
    final double s = radius * 0.62 * scale;
    _tick
      ..reset()
      ..moveTo(center.dx - s * 0.85, center.dy + s * 0.02)
      ..lineTo(center.dx - s * 0.2, center.dy + s * 0.62)
      ..lineTo(center.dx + s * 0.9, center.dy - s * 0.55);
    _stroke
      ..color = tick
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(_tick, _stroke);
  }

  @override
  bool shouldRepaint(_NoteCheckPainter oldDelegate) =>
      oldDelegate.pop != pop ||
      oldDelegate.checked != checked ||
      oldDelegate.ember != ember ||
      oldDelegate.halo != halo ||
      oldDelegate.ring != ring ||
      oldDelegate.tick != tick ||
      oldDelegate.glowStrength != glowStrength ||
      oldDelegate.diameter != diameter;
}
