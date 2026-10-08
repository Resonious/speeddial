import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Stops of a glint band: clear, bright in the middle, clear.
const List<double> _bandStops = <double>[0, 0.5, 1];

/// Sweeps a warm glint across its child, like haze over a hot oven.
///
/// With a [color], the child is recolored: it rests in [color] and the glint
/// passes through. Without one, the glint glazes over the child's own colors.
/// [strength] (full when omitted) fades the glint in and out; at zero the
/// child paints untouched, without a layer. Paints through a shader mask on
/// each tick of [animation] without rebuilding anything.
class HeatShimmer extends SingleChildRenderObjectWidget {
  const HeatShimmer({
    super.key,
    required this.animation,
    required this.glint,
    this.color,
    this.strength,
    super.child,
  });

  /// Where the glint is in its sweep; at 0 it rests just off the left edge.
  final Animation<double> animation;
  final Color glint;
  final Color? color;
  final Animation<double>? strength;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderHeatShimmer(animation, glint, color, strength);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderHeatShimmer renderObject,
  ) {
    renderObject
      ..animation = animation
      ..glint = glint
      ..color = color
      ..strength = strength;
  }
}

/// Paints [HeatShimmer].
class RenderHeatShimmer extends RenderProxyBox {
  RenderHeatShimmer(this._animation, this._glint, this._color, this._strength)
    : _glinting = (_strength?.value ?? 1) > 0;

  Animation<double> _animation;
  set animation(Animation<double> value) {
    if (identical(value, _animation)) return;
    if (attached) _animation.removeListener(markNeedsPaint);
    _animation = value;
    if (attached) _animation.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  Color _glint;
  set glint(Color value) {
    if (value == _glint) return;
    _glint = value;
    markNeedsPaint();
  }

  Color? _color;
  set color(Color? value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  Animation<double>? _strength;
  set strength(Animation<double>? value) {
    if (identical(value, _strength)) return;
    if (attached) _strength?.removeListener(_strengthChanged);
    _strength = value;
    if (attached) _strength?.addListener(_strengthChanged);
    _strengthChanged();
  }

  /// Whether the glint shows at all; only then is there a layer.
  bool _glinting;

  void _strengthChanged() {
    final bool glinting = (_strength?.value ?? 1) > 0;
    if (glinting != _glinting) {
      _glinting = glinting;
      markNeedsCompositingBitsUpdate();
    }
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _animation.addListener(markNeedsPaint);
    _strength?.addListener(_strengthChanged);
    _strengthChanged();
  }

  @override
  void detach() {
    _animation.removeListener(markNeedsPaint);
    _strength?.removeListener(_strengthChanged);
    super.detach();
  }

  @override
  bool get alwaysNeedsCompositing => child != null && _glinting;

  @override
  ShaderMaskLayer? get layer => super.layer as ShaderMaskLayer?;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null || !_glinting) {
      layer = null;
      super.paint(context, offset);
      return;
    }
    // Narrow enough on a long line to pass along it, not flood it.
    final double band = (size.width * 0.3).clamp(28, 64);
    // Rests just off the left edge between sweeps, and when motion is off.
    final double center = -band + (size.width + band * 2) * _animation.value;
    final double strength = (_strength?.value ?? 1).clamp(0.0, 1.0);
    final Color? color = _color;
    final Color clear = _glint.withValues(alpha: 0);
    layer ??= ShaderMaskLayer();
    layer!
      ..shader = ui.Gradient.linear(
        Offset(center - band, 0),
        Offset(center + band, 0),
        color == null
            ? <Color>[
                clear,
                _glint.withValues(alpha: _glint.a * strength),
                clear,
              ]
            : <Color>[color, Color.lerp(color, _glint, strength)!, color],
        _bandStops,
      )
      ..maskRect = offset & size
      ..blendMode = color == null ? BlendMode.srcATop : BlendMode.srcIn;
    context.pushLayer(layer!, super.paint, offset);
  }
}
