import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../theme.dart';
import '../flame.dart';
import 'message_view.dart';

/// What the oven at the foot of the timeline is doing.
enum TurnHeat {
  /// Nothing is cooking.
  off,

  /// A message is on its way in, or the turn has started without output.
  preheating,

  /// The agent is producing output.
  cooking,

  /// The turn is paused on a permission request or question.
  keepingWarm,
}

const List<String> _cookingVerbs = <String>[
  'Baking',
  'Roasting',
  'Simmering',
  'Sizzling',
  'Toasting',
  'Braising',
  'Searing',
  'Broiling',
  'Glazing',
  'Caramelizing',
];

/// Status line for [heat]. [seed] (the turn's user message seq) picks the
/// verb a turn cooks with, so it stays put for the whole turn.
String turnHeatLabel(TurnHeat heat, int seed) => switch (heat) {
  TurnHeat.off => '',
  TurnHeat.preheating => 'Preheating…',
  TurnHeat.cooking => '${_cookingVerbs[seed.abs() % _cookingVerbs.length]}…',
  TurnHeat.keepingWarm => 'Keeping warm…',
};

bool _reduceMotion(BuildContext context) =>
    MediaQuery.maybeDisableAnimationsOf(context) ?? false;

/// Stops of a glint band: clear, bright in the middle, clear.
const List<double> _bandStops = <double>[0, 0.5, 1];

/// The agent's turn at the foot of the timeline: a flame that ignites when a
/// message goes in, burns while the agent works, turns down to a pilot light
/// while the turn waits on the user, and goes out in a puff of smoke.
///
/// Collapses to nothing (and unmounts its flame) while [heat] is off.
class TurnFlameRow extends StatefulWidget {
  const TurnFlameRow({
    super.key,
    required this.heat,
    this.seed = 0,
    this.unreachable,
  });

  final TurnHeat heat;

  /// See [turnHeatLabel].
  final int seed;

  /// While set, the daemon is out of reach and the turn's real state is
  /// unknown: the flame sits grey and still, and this replaces the status
  /// line.
  final String? unreachable;

  @override
  State<TurnFlameRow> createState() => _TurnFlameRowState();
}

class _TurnFlameRowState extends State<TurnFlameRow>
    with TickerProviderStateMixin {
  late final AnimationController _lit = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 560),
    reverseDuration: const Duration(milliseconds: 620),
    value: widget.heat == TurnHeat.off ? 0 : 1,
  )..addStatusListener(_onLitStatus);
  late final AnimationController _shimmer = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1900),
  );

  // Igniting: the row opens, then the flame leaps up past full size and the
  // label fades in. Going out: the flame sinks while smoke rises, then the
  // row closes.
  late final Animation<double> _open = CurvedAnimation(
    parent: _lit,
    curve: const Interval(0, 0.4, curve: Curves.easeOutCubic),
    reverseCurve: const Interval(0, 0.35, curve: Curves.easeInCubic),
  );
  late final Animation<double> _flame = CurvedAnimation(
    parent: _lit,
    curve: const Interval(0.2, 1, curve: Curves.easeOutBack),
    reverseCurve: const Interval(0.45, 1, curve: Curves.easeIn),
  );
  late final Animation<double> _label = CurvedAnimation(
    parent: _lit,
    curve: const Interval(0.35, 1, curve: Curves.easeOut),
    reverseCurve: const Interval(0.45, 0.9, curve: Curves.easeIn),
  );

  /// What is on screen; kept while the flame goes out after [heat] turns off.
  late TurnHeat _shown = widget.heat == TurnHeat.off
      ? TurnHeat.preheating
      : widget.heat;
  late int _shownSeed = widget.seed;
  bool _still = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = _reduceMotion(context);
    _syncShimmer();
  }

  @override
  void didUpdateWidget(TurnFlameRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.heat == TurnHeat.off) {
      if (oldWidget.heat == TurnHeat.off) return;
      if (_still) {
        _lit.value = 0;
      } else {
        _lit.reverse();
      }
      return;
    }
    _shown = widget.heat;
    _shownSeed = widget.seed;
    if (widget.unreachable != oldWidget.unreachable) _syncShimmer();
    if (_lit.isCompleted || _lit.status == AnimationStatus.forward) return;
    if (_still) {
      _lit.value = 1;
    } else {
      _lit.forward();
    }
  }

  void _onLitStatus(AnimationStatus status) {
    // The flame is mounted only while it shows: unmount it once it is out,
    // remount it when it reignites.
    if (status == AnimationStatus.dismissed ||
        status == AnimationStatus.forward ||
        status == AnimationStatus.completed) {
      setState(_syncShimmer);
    }
  }

  void _syncShimmer() {
    if (_lit.isDismissed || _still || widget.unreachable != null) {
      // Parks the glint off the label's edge (and stops the loop).
      _shimmer.value = 0;
    } else if (!_shimmer.isAnimating) {
      _shimmer.repeat();
    }
  }

  @override
  void dispose() {
    _lit.dispose();
    _shimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_lit.isDismissed) return const SizedBox.shrink();
    final ThemeData theme = Theme.of(context);
    final SpeedDialColors colors = theme.speedDialColors;
    final Color muted = theme.colorScheme.onSurfaceVariant;
    final String? unreachable = widget.unreachable;
    final String label = unreachable ?? turnHeatLabel(_shown, _shownSeed);
    return SizeTransition(
      key: const Key('turn-flame'),
      sizeFactor: _open,
      alignment: Alignment.topLeft,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 12, 8),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 22,
              height: 26,
              child: CustomPaint(
                foregroundPainter: _SmokePainter(lit: _lit, color: muted),
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: ScaleTransition(
                    scale: _flame,
                    alignment: Alignment.bottomCenter,
                    child: Flame(
                      size: 24,
                      glow: true,
                      phase: _shownSeed * 0.17,
                      intensity: _shown == TurnHeat.keepingWarm
                          ? FlameIntensity.pilot
                          : FlameIntensity.blaze,
                      dormant: unreachable != null,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: FadeTransition(
                opacity: _label,
                child: _HeatShimmer(
                  animation: _shimmer,
                  color: muted,
                  glint: _shown == TurnHeat.keepingWarm
                      ? colors.running
                      : colors.flameTip,
                  // The old label fades out before the new one fades in,
                  // so the two words never overprint.
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 320),
                    switchInCurve: const Interval(0.5, 1),
                    switchOutCurve: const Interval(0.5, 1),
                    layoutBuilder: _leftAligned,
                    child: Text(
                      label,
                      key: ValueKey<String>(label),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _leftAligned(Widget? current, List<Widget> previous) => Stack(
    alignment: Alignment.centerLeft,
    children: <Widget>[...previous, ?current],
  );
}

/// Two curls of smoke drifting up while the flame goes out.
class _SmokePainter extends CustomPainter {
  _SmokePainter({required this.lit, required this.color}) : super(repaint: lit);

  final AnimationController lit;
  final Color color;
  final Path _curl = Path();
  final Paint _paint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;

  @override
  void paint(Canvas canvas, Size size) {
    if (lit.status != AnimationStatus.reverse) return;
    final double rise = ((1 - lit.value) / 0.65).clamp(0.0, 1.0);
    if (rise <= 0 || rise >= 1) return;
    final double w = size.width;
    final double h = size.height;
    _paint
      ..strokeWidth = math.max(1.2, w * 0.07)
      ..color = color.withValues(alpha: 0.6 * math.sin(math.pi * rise));
    for (int i = 0; i < 2; i++) {
      final double x = w * (0.4 + 0.2 * i);
      final double y = h * (0.7 - 0.6 * rise) - h * 0.1 * i;
      final double drift = (i == 0 ? -1 : 1) * w * 0.16;
      _curl
        ..reset()
        ..moveTo(x, y)
        ..cubicTo(
          x + drift,
          y - h * 0.1,
          x - drift,
          y - h * 0.2,
          x,
          y - h * 0.3,
        );
      canvas.drawPath(_curl, _paint);
    }
  }

  @override
  bool shouldRepaint(_SmokePainter oldDelegate) =>
      oldDelegate.lit != lit || oldDelegate.color != color;
}

/// Sweeps a warm glint across its child, like haze over a hot oven.
///
/// Paints through a shader mask on each tick of [animation] without
/// rebuilding anything; [color] is the child's resting color.
class _HeatShimmer extends SingleChildRenderObjectWidget {
  const _HeatShimmer({
    required this.animation,
    required this.color,
    required this.glint,
    super.child,
  });

  final Animation<double> animation;
  final Color color;
  final Color glint;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderHeatShimmer(animation, color, glint);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderHeatShimmer renderObject,
  ) {
    renderObject
      ..animation = animation
      ..color = color
      ..glint = glint;
  }
}

class _RenderHeatShimmer extends RenderProxyBox {
  _RenderHeatShimmer(this._animation, this._color, this._glint);

  Animation<double> _animation;
  set animation(Animation<double> value) {
    if (identical(value, _animation)) return;
    if (attached) _animation.removeListener(markNeedsPaint);
    _animation = value;
    if (attached) _animation.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  Color _color;
  set color(Color value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  Color _glint;
  set glint(Color value) {
    if (value == _glint) return;
    _glint = value;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _animation.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _animation.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  bool get alwaysNeedsCompositing => child != null;

  @override
  ShaderMaskLayer? get layer => super.layer as ShaderMaskLayer?;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) {
      layer = null;
      return;
    }
    final double band = math.max(size.width * 0.3, 28);
    // Rests just off the left edge between sweeps, and when motion is off.
    final double center = -band + (size.width + band * 2) * _animation.value;
    layer ??= ShaderMaskLayer();
    layer!
      ..shader = ui.Gradient.linear(
        Offset(center - band, 0),
        Offset(center + band, 0),
        <Color>[_color, _glint, _color],
        _bandStops,
      )
      ..maskRect = offset & size
      ..blendMode = BlendMode.srcIn;
    context.pushLayer(layer!, super.paint, offset);
  }
}

/// Raw-dough look for a sent message the daemon has not echoed back yet: it
/// rises into place under a pale veil while a warm glint keeps sweeping
/// across it. Expects a [UserMessageBubble] child.
class BakingBubble extends StatefulWidget {
  const BakingBubble({super.key, required this.child});

  final Widget child;

  @override
  State<BakingBubble> createState() => _BakingBubbleState();
}

class _BakingBubbleState extends State<BakingBubble>
    with TickerProviderStateMixin {
  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );
  late final AnimationController _glint = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );
  late final Animation<double> _rise = CurvedAnimation(
    parent: _enter,
    curve: Curves.easeOutCubic,
  );
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.45),
    end: Offset.zero,
  ).animate(_rise);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reduceMotion(context)) {
      _enter.value = 1;
      // Parks the sheen off the bubble's edge (and stops the loop).
      _glint.value = 0;
      return;
    }
    if (_enter.isDismissed) _enter.forward();
    if (!_glint.isAnimating) _glint.repeat();
  }

  @override
  void dispose() {
    _enter.dispose();
    _glint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return FadeTransition(
      opacity: _rise,
      child: SlideTransition(
        position: _slide,
        child: CustomPaint(
          key: const Key('baking-bubble'),
          foregroundPainter: _BakingPainter(
            glint: _glint,
            veil: theme.colorScheme.surface.withValues(alpha: 0.45),
            sheen: theme.speedDialColors.flameTip.withValues(alpha: 0.3),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

class _BakingPainter extends CustomPainter {
  _BakingPainter({required this.glint, required this.veil, required this.sheen})
    : super(repaint: glint);

  final Animation<double> glint;
  final Color veil;
  final Color sheen;
  final Paint _paint = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    final Rect bubble = UserMessageBubble.margin.deflateRect(
      Offset.zero & size,
    );
    if (bubble.isEmpty) return;
    final RRect shape = UserMessageBubble.radius.toRRect(bubble);
    _paint
      ..shader = null
      ..color = veil;
    canvas.drawRRect(shape, _paint);
    final double band = math.max(bubble.width * 0.4, 48);
    final double x =
        bubble.left - band + (bubble.width + band * 2) * glint.value;
    _paint.shader = ui.Gradient.linear(
      Offset(x - band, bubble.top),
      Offset(x + band, bubble.bottom),
      <Color>[sheen.withValues(alpha: 0), sheen, sheen.withValues(alpha: 0)],
      _bandStops,
    );
    canvas.drawRRect(shape, _paint);
  }

  @override
  bool shouldRepaint(_BakingPainter oldDelegate) =>
      oldDelegate.glint != glint ||
      oldDelegate.veil != veil ||
      oldDelegate.sheen != sheen;
}

/// Celebrates a sent message the daemon just confirmed: it puffs up out of
/// the oven inside a warm glow and lets off a little steam.
///
/// Plays once when first built with [play]; rebuilds never restart it, so a
/// row scrolled away and back stays put. Expects a [UserMessageBubble] child.
class DeliveredPop extends StatefulWidget {
  const DeliveredPop({super.key, required this.play, required this.child});

  final bool play;
  final Widget child;

  @override
  State<DeliveredPop> createState() => _DeliveredPopState();
}

class _DeliveredPopState extends State<DeliveredPop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 950),
    value: widget.play ? 0 : 1,
  );
  late final Animation<double> _scale = _pop.drive(_bounce);

  static final Animatable<double> _bounce = TweenSequence<double>(
    <TweenSequenceItem<double>>[
      TweenSequenceItem<double>(
        tween: Tween<double>(
          begin: 0.95,
          end: 1.07,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 18,
      ),
      TweenSequenceItem<double>(
        tween: Tween<double>(
          begin: 1.07,
          end: 0.985,
        ).chain(CurveTween(curve: Curves.easeInOut)),
        weight: 22,
      ),
      TweenSequenceItem<double>(
        tween: Tween<double>(
          begin: 0.985,
          end: 1,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 20,
      ),
      TweenSequenceItem<double>(tween: ConstantTween<double>(1), weight: 40),
    ],
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_pop.isDismissed) return;
    if (_reduceMotion(context)) {
      _pop.value = 1;
    } else {
      _pop.forward();
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
    return CustomPaint(
      key: const Key('delivered-pop'),
      painter: _PopGlowPainter(pop: _pop, color: theme.colorScheme.primary),
      foregroundPainter: _SteamPainter(
        pop: _pop,
        color: theme.colorScheme.onSurfaceVariant,
      ),
      child: ScaleTransition(
        scale: _scale,
        alignment: Alignment.centerRight,
        child: widget.child,
      ),
    );
  }
}

/// A warm halo that blooms around the bubble and cools off.
class _PopGlowPainter extends CustomPainter {
  _PopGlowPainter({required this.pop, required this.color})
    : super(repaint: pop);

  final Animation<double> pop;
  final Color color;
  final Paint _paint = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    final double t = pop.value;
    if (t >= 1) return;
    final double heat = t < 0.16
        ? Curves.easeOut.transform(t / 0.16)
        : 1 - Curves.easeInOut.transform((t - 0.16) / 0.84);
    if (heat <= 0.01) return;
    final Rect bubble = UserMessageBubble.margin.deflateRect(
      Offset.zero & size,
    );
    _paint
      ..color = color.withValues(alpha: 0.6 * heat)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 3 + 7 * heat);
    canvas.drawRRect(
      UserMessageBubble.radius.toRRect(bubble).inflate(1 + 5 * heat),
      _paint,
    );
  }

  @override
  bool shouldRepaint(_PopGlowPainter oldDelegate) =>
      oldDelegate.pop != pop || oldDelegate.color != color;
}

/// Three wisps of steam curling up off a fresh bubble.
class _SteamPainter extends CustomPainter {
  _SteamPainter({required this.pop, required this.color}) : super(repaint: pop);

  final Animation<double> pop;
  final Color color;
  final Path _wisp = Path();
  final Paint _paint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeWidth = 1.8;

  @override
  void paint(Canvas canvas, Size size) {
    final double t = pop.value;
    if (t <= 0.1 || t >= 1) return;
    final Rect bubble = UserMessageBubble.margin.deflateRect(
      Offset.zero & size,
    );
    final double spacing = math.min(16, bubble.width / 4);
    for (int i = 0; i < 3; i++) {
      final double rise = ((t - 0.1 - i * 0.07) / 0.7).clamp(0.0, 1.0);
      if (rise <= 0 || rise >= 1) continue;
      final double x = bubble.right - spacing * (i + 1) - 4;
      final double y = bubble.top - 2 - rise * 18;
      final double sway = (i.isEven ? 1 : -1) * 4;
      _paint.color = color.withValues(alpha: 0.7 * math.sin(math.pi * rise));
      _wisp
        ..reset()
        ..moveTo(x, y)
        ..cubicTo(x + sway, y - 5, x - sway, y - 9, x, y - 14);
      canvas.drawPath(_wisp, _paint);
    }
  }

  @override
  bool shouldRepaint(_SteamPainter oldDelegate) =>
      oldDelegate.pop != pop || oldDelegate.color != color;
}
