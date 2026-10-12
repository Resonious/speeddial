import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../../theme.dart';

/// Theme colors behind the explainer `var(--token)` palette.
class ExplainerPalette {
  ExplainerPalette.of(BuildContext context) : theme = Theme.of(context) {
    final ColorScheme scheme = theme.colorScheme;
    final SpeedDialColors colors = theme.speedDialColors;
    tokens = <String, Color>{
      'fg': scheme.onSurface,
      'muted': scheme.onSurfaceVariant,
      'bg': scheme.surfaceContainerLow,
      'surface': scheme.surfaceContainerHigh,
      'border': scheme.outline,
      'accent': scheme.primary,
      'success': colors.success,
      'warning': colors.waitingPermission,
      'danger': colors.error,
      'info': colors.running,
      'purple': colors.purple,
      'code': colors.codeBackground,
    };
    monoFamily = colors.mono.fontFamily ?? kMonoFamily;
    monoFallback = colors.mono.fontFamilyFallback;
  }

  final ThemeData theme;
  late final Map<String, Color> tokens;
  late final String monoFamily;
  late final List<String>? monoFallback;

  Color get background => tokens['bg']!;

  bool sameAs(ExplainerPalette other) => theme == other.theme;
}

/// One view of an explainer: a step plus the on/off state of each toggle.
class ExplainerState {
  ExplainerState(this.document, this.step, List<bool> toggles)
    : toggles = List<bool>.unmodifiable(toggles) {
    final ExplainerOverrides merged = <int, Map<SvgAttr, Object>>{
      ...document.steps[step].overrides,
    };
    for (int i = 0; i < toggles.length; i++) {
      if (!toggles[i]) continue;
      for (final MapEntry<int, Map<SvgAttr, Object>> entry
          in document.toggles[i].overrides.entries) {
        merged[entry.key] = <SvgAttr, Object>{
          ...?merged[entry.key],
          ...entry.value,
        };
      }
    }
    _overrides = merged;
  }

  final ExplainerDocument document;
  final int step;
  final List<bool> toggles;
  late final ExplainerOverrides _overrides;

  Object? value(int node, SvgAttr attr) =>
      _overrides[node]?[attr] ?? document.svg.nodes[node].props[attr];

  String get key => '$step:${toggles.map((bool on) => on ? 1 : 0).join()}';

  @override
  bool operator ==(Object other) =>
      other is ExplainerState &&
      identical(other.document, document) &&
      other.key == key;

  @override
  int get hashCode => Object.hash(document, key);
}

/// Attribute values the painter reads: a settled state, or a tween.
abstract class _Values {
  Object? get(int node, SvgAttr attr);
}

class _Settled implements _Values {
  const _Settled(this.state);
  final ExplainerState state;

  @override
  Object? get(int node, SvgAttr attr) => state.value(node, attr);
}

class _Tween implements _Values {
  const _Tween(this.from, this.to, this.t, this.palette);
  final ExplainerState from;
  final ExplainerState to;
  final double t;
  final ExplainerPalette palette;

  @override
  Object? get(int node, SvgAttr attr) {
    final Object? a = from.value(node, attr) ?? _defaultFor(attr);
    final Object? b = to.value(node, attr) ?? _defaultFor(attr);
    if (identical(a, b) || a == b) return b;
    return _lerp(attr, a, b, t, palette);
  }
}

/// Values that are well-defined when absent, so tweens can start from them.
Object? _defaultFor(SvgAttr attr) => switch (attr) {
  SvgAttr.opacity || SvgAttr.fillOpacity || SvgAttr.strokeOpacity => 1.0,
  SvgAttr.x ||
  SvgAttr.y ||
  SvgAttr.dx ||
  SvgAttr.dy ||
  SvgAttr.cx ||
  SvgAttr.cy ||
  SvgAttr.x1 ||
  SvgAttr.y1 ||
  SvgAttr.x2 ||
  SvgAttr.y2 => 0.0,
  SvgAttr.transform => const SvgTransform(<SvgTransformOp>[]),
  _ => null,
};

Object? _lerp(
  SvgAttr attr,
  Object? a,
  Object? b,
  double t,
  ExplainerPalette palette,
) {
  Object? snap() => t < 0.5 ? a : b;
  if (a == null || b == null) return snap();
  switch (attr.kind) {
    case SvgValueKind.paint:
      Color? color(Object value) => switch (value) {
        final Color c => c,
        SvgColor(:final int argb) => Color(argb),
        SvgThemeColor(:final String token) => palette.tokens[token],
        _ => null,
      };
      if (a is SvgContextPaint || b is SvgContextPaint) return snap();
      Color? ca = color(a);
      Color? cb = color(b);
      if (ca == null && cb == null) return b;
      ca ??= cb!.withValues(alpha: 0);
      cb ??= ca.withValues(alpha: 0);
      return Color.lerp(ca, cb, t);
    case SvgValueKind.number:
    case SvgValueKind.opacity:
    case SvgValueKind.length:
      return ui.lerpDouble(a as double, b as double, t);
    case SvgValueKind.dashArray:
    case SvgValueKind.points:
      final List<double> la = a as List<double>;
      final List<double> lb = b as List<double>;
      if (la.length != lb.length) return snap();
      return <double>[
        for (int i = 0; i < la.length; i++) ui.lerpDouble(la[i], lb[i], t)!,
      ];
    case SvgValueKind.transform:
      final SvgTransform ta = a as SvgTransform;
      final SvgTransform tb = b as SvgTransform;
      if (ta.sameShape(tb)) {
        return SvgTransform(<SvgTransformOp>[
          for (int i = 0; i < ta.ops.length; i++)
            SvgTransformOp(ta.ops[i].kind, <double>[
              for (int k = 0; k < ta.ops[i].args.length; k++)
                ui.lerpDouble(ta.ops[i].args[k], tb.ops[i].args[k], t)!,
            ]),
        ]);
      }
      final SvgMatrix ma = ta.matrix;
      final SvgMatrix mb = tb.matrix;
      double l(double x, double y) => ui.lerpDouble(x, y, t)!;
      return SvgTransform(<SvgTransformOp>[
        SvgTransformOp(SvgTransformKind.matrix, <double>[
          l(ma.a, mb.a),
          l(ma.b, mb.b),
          l(ma.c, mb.c),
          l(ma.d, mb.d),
          l(ma.e, mb.e),
          l(ma.f, mb.f),
        ]),
      ]);
    case SvgValueKind.path:
      final SvgPathData pa = a as SvgPathData;
      final SvgPathData pb = b as SvgPathData;
      if (!pa.sameShape(pb)) return snap();
      return SvgPathData(<SvgPathCommand>[
        for (int i = 0; i < pa.commands.length; i++)
          SvgPathCommand(pa.commands[i].verb, <double>[
            for (int k = 0; k < pa.commands[i].args.length; k++)
              ui.lerpDouble(pa.commands[i].args[k], pb.commands[i].args[k], t)!,
          ]),
      ]);
    case SvgValueKind.keyword:
    case SvgValueKind.fontWeight:
    case SvgValueKind.string:
    case SvgValueKind.marker:
      return snap();
  }
}

/// Inherited properties while walking the tree.
class _Ctx {
  _Ctx({
    required this.fill,
    required this.fillOpacity,
    required this.stroke,
    required this.strokeOpacity,
    required this.strokeWidth,
    required this.dashes,
    required this.cap,
    required this.join,
    required this.fontSize,
    required this.fontWeight,
    required this.fontFamily,
    required this.fontStyle,
    required this.anchor,
    required this.baseline,
    required this.markerStart,
    required this.markerEnd,
    required this.visibility,
    required this.ctm,
    required this.title,
    this.contextFill,
    this.contextStroke,
  });

  static _Ctx root() => _Ctx(
    fill: const SvgThemeColor('fg'),
    fillOpacity: 1,
    stroke: const SvgNoPaint(),
    strokeOpacity: 1,
    strokeWidth: 1,
    dashes: const <double>[],
    cap: 'butt',
    join: 'miter',
    fontSize: 16,
    fontWeight: 400,
    fontFamily: null,
    fontStyle: 'normal',
    anchor: 'start',
    baseline: 'auto',
    markerStart: '',
    markerEnd: '',
    visibility: 'visible',
    ctm: Matrix4.identity(),
    title: null,
  );

  final Object fill;
  final double fillOpacity;
  final Object stroke;
  final double strokeOpacity;
  final double strokeWidth;
  final List<double> dashes;
  final String cap;
  final String join;
  final double fontSize;
  final double fontWeight;
  final String? fontFamily;
  final String fontStyle;
  final String anchor;
  final String baseline;
  final String markerStart;
  final String markerEnd;
  final String visibility;
  final Matrix4 ctm;
  final String? title;

  /// Paints of the element a marker is drawn on (`context-fill/stroke`).
  final Color? contextFill;
  final Color? contextStroke;

  _Ctx child(
    int node,
    _Values v,
    Matrix4 ctm,
    String? title, {
    Color? contextFill,
    Color? contextStroke,
  }) {
    T pick<T>(SvgAttr attr, T inherited) =>
        (v.get(node, attr) as T?) ?? inherited;
    return _Ctx(
      fill: pick<Object>(SvgAttr.fill, fill),
      fillOpacity: pick<double>(SvgAttr.fillOpacity, fillOpacity),
      stroke: pick<Object>(SvgAttr.stroke, stroke),
      strokeOpacity: pick<double>(SvgAttr.strokeOpacity, strokeOpacity),
      strokeWidth: pick<double>(SvgAttr.strokeWidth, strokeWidth),
      dashes: pick<List<double>>(SvgAttr.strokeDasharray, dashes),
      cap: pick<String>(SvgAttr.strokeLinecap, cap),
      join: pick<String>(SvgAttr.strokeLinejoin, join),
      fontSize: pick<double>(SvgAttr.fontSize, fontSize),
      fontWeight: pick<double>(SvgAttr.fontWeight, fontWeight),
      fontFamily: pick<String?>(SvgAttr.fontFamily, fontFamily),
      fontStyle: pick<String>(SvgAttr.fontStyle, fontStyle),
      anchor: pick<String>(SvgAttr.textAnchor, anchor),
      baseline: pick<String>(SvgAttr.dominantBaseline, baseline),
      markerStart: pick<String>(SvgAttr.markerStart, markerStart),
      markerEnd: pick<String>(SvgAttr.markerEnd, markerEnd),
      visibility: pick<String>(SvgAttr.visibility, visibility),
      ctm: ctm,
      title: title ?? this.title,
      contextFill: contextFill ?? this.contextFill,
      contextStroke: contextStroke ?? this.contextStroke,
    );
  }
}

/// A tooltip target recorded while painting a settled state, in viewBox
/// coordinates.
class _Region {
  const _Region(this.path, this.bounds, this.filled, this.title);
  final Path? path;
  final Rect bounds;
  final bool filled;
  final String title;

  bool contains(Offset point) {
    if (filled && path != null && path!.contains(point)) return true;
    return bounds.inflate(6).contains(point);
  }
}

class _Baked {
  _Baked(this.picture, this.regions);
  final ui.Picture picture;
  final List<_Region> regions;
}

/// Paints an [ExplainerDocument] in viewBox units. Settled states are
/// recorded once into a [ui.Picture]; only tweens repaint from the tree.
class ExplainerScene {
  ExplainerScene(this.document, this.palette);

  final ExplainerDocument document;
  final ExplainerPalette palette;

  SvgDocument get svg => document.svg;
  SvgViewBox get viewBox => svg.viewBox;
  Size get size => Size(viewBox.width, viewBox.height);

  final LinkedHashMap<String, _Baked> _baked = LinkedHashMap<String, _Baked>();

  void dispose() {
    for (final _Baked baked in _baked.values) {
      baked.picture.dispose();
    }
    _baked.clear();
  }

  _Baked _bake(ExplainerState state) {
    final _Baked? cached = _baked.remove(state.key);
    if (cached != null) {
      _baked[state.key] = cached;
      return cached;
    }
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    final List<_Region> regions = <_Region>[];
    _paintTree(canvas, _Settled(state), regions);
    final _Baked baked = _Baked(recorder.endRecording(), regions);
    _baked[state.key] = baked;
    if (_baked.length > 12) _baked.remove(_baked.keys.first)!.picture.dispose();
    return baked;
  }

  /// Paints [state] in viewBox coordinates.
  void paintState(Canvas canvas, ExplainerState state) {
    canvas.drawPicture(_bake(state).picture);
  }

  /// Paints the in-between of two states; [t] runs 0..1.
  void paintTween(
    Canvas canvas,
    ExplainerState from,
    ExplainerState to,
    double t,
  ) {
    _paintTree(canvas, _Tween(from, to, t, palette), null);
  }

  /// The tooltip under [point] (viewBox coordinates) in [state], if any.
  String? hitTest(ExplainerState state, Offset point) {
    final List<_Region> regions = _bake(state).regions;
    for (int i = regions.length - 1; i >= 0; i--) {
      if (regions[i].contains(point)) return regions[i].title;
    }
    return null;
  }

  void _paintTree(Canvas canvas, _Values v, List<_Region>? regions) {
    canvas.save();
    canvas.clipRect(
      Rect.fromLTWH(viewBox.x, viewBox.y, viewBox.width, viewBox.height),
    );
    _walk(canvas, v, 0, _Ctx.root(), regions);
    canvas.restore();
  }

  void _walk(
    Canvas canvas,
    _Values v,
    int index,
    _Ctx parent,
    List<_Region>? regions,
  ) {
    final SvgNode node = svg.nodes[index];
    if (node.tag == 'defs' || node.tag == 'marker' || node.tag == '#text') {
      return;
    }
    if (v.get(index, SvgAttr.display) == 'none') return;
    final double opacity = (v.get(index, SvgAttr.opacity) as double?) ?? 1;
    if (opacity <= 0.002) return;

    final SvgTransform? transform =
        v.get(index, SvgAttr.transform) as SvgTransform?;
    Matrix4 ctm = parent.ctm;
    canvas.save();
    if (transform != null && transform.ops.isNotEmpty) {
      final Matrix4 local = _matrix4(transform.matrix);
      canvas.transform(local.storage);
      ctm = parent.ctm.multiplied(local);
    }
    final _Ctx ctx = parent.child(index, v, ctm, node.title);
    final bool layer = opacity < 0.998;
    if (layer) {
      canvas.saveLayer(null, Paint()..color = Color.fromRGBO(0, 0, 0, opacity));
    }
    switch (node.tag) {
      case 'svg':
      case 'g':
        for (final int child in node.children) {
          _walk(canvas, v, child, ctx, regions);
        }
      case 'text':
        _drawText(canvas, v, index, ctx, regions);
      default:
        _drawShape(canvas, v, index, node.tag, ctx, regions);
    }
    if (layer) canvas.restore();
    canvas.restore();
  }

  Color? _paintColor(Object paint, double opacity, _Ctx ctx) {
    final Color? base = switch (paint) {
      final Color color => color,
      SvgNoPaint() => null,
      SvgColor(:final int argb) => Color(argb),
      SvgThemeColor(:final String token) =>
        palette.tokens[token] ?? palette.tokens['fg'],
      SvgContextPaint(:final bool stroke) =>
        stroke ? ctx.contextStroke : ctx.contextFill,
      _ => null,
    };
    if (base == null || opacity >= 1) return base;
    return base.withValues(alpha: base.a * opacity);
  }

  void _drawShape(
    Canvas canvas,
    _Values v,
    int index,
    String tag,
    _Ctx ctx,
    List<_Region>? regions,
  ) {
    final Path? path = _geometry(v, index, tag);
    if (path == null) return;
    final bool open = tag == 'line' || tag == 'polyline';
    final Color? fill = tag == 'line'
        ? null
        : _paintColor(ctx.fill, ctx.fillOpacity, ctx);
    final Color? stroke = ctx.strokeWidth > 0
        ? _paintColor(ctx.stroke, ctx.strokeOpacity, ctx)
        : null;
    if (ctx.visibility == 'visible') {
      if (fill != null && fill.a > 0) {
        canvas.drawPath(path, Paint()..color = fill);
      }
      if (stroke != null && stroke.a > 0) {
        canvas.drawPath(
          ctx.dashes.isEmpty ? path : _dashed(path, ctx.dashes),
          Paint()
            ..style = PaintingStyle.stroke
            ..color = stroke
            ..strokeWidth = ctx.strokeWidth
            ..strokeCap = switch (ctx.cap) {
              'round' => StrokeCap.round,
              'square' => StrokeCap.square,
              _ => StrokeCap.butt,
            }
            ..strokeJoin = switch (ctx.join) {
              'round' => StrokeJoin.round,
              'bevel' => StrokeJoin.bevel,
              _ => StrokeJoin.miter,
            },
        );
      }
      if (ctx.markerStart.isNotEmpty || ctx.markerEnd.isNotEmpty) {
        _drawMarkers(canvas, v, path, ctx, fill, stroke);
      }
    }
    final String? title = ctx.title;
    if (regions != null && title != null) {
      final Path rooted = path.transform(ctx.ctm.storage);
      regions.add(
        _Region(rooted, rooted.getBounds(), !open && fill != null, title),
      );
    }
  }

  Path? _geometry(_Values v, int index, String tag) {
    double n(SvgAttr attr) => (v.get(index, attr) as double?) ?? 0;
    switch (tag) {
      case 'rect':
        final double w = n(SvgAttr.width);
        final double h = n(SvgAttr.height);
        if (w <= 0 || h <= 0) return null;
        final Rect rect = Rect.fromLTWH(n(SvgAttr.x), n(SvgAttr.y), w, h);
        double? rx = v.get(index, SvgAttr.rx) as double?;
        double? ry = v.get(index, SvgAttr.ry) as double?;
        rx ??= ry;
        ry ??= rx;
        if (rx == null || ry == null || (rx <= 0 && ry <= 0)) {
          return Path()..addRect(rect);
        }
        return Path()..addRRect(
          RRect.fromRectXY(rect, math.min(rx, w / 2), math.min(ry, h / 2)),
        );
      case 'circle':
        final double r = n(SvgAttr.r);
        if (r <= 0) return null;
        return Path()..addOval(
          Rect.fromCircle(
            center: Offset(n(SvgAttr.cx), n(SvgAttr.cy)),
            radius: r,
          ),
        );
      case 'ellipse':
        double? rx = v.get(index, SvgAttr.rx) as double?;
        double? ry = v.get(index, SvgAttr.ry) as double?;
        rx ??= ry;
        ry ??= rx;
        if (rx == null || ry == null || rx <= 0 || ry <= 0) return null;
        return Path()..addOval(
          Rect.fromCenter(
            center: Offset(n(SvgAttr.cx), n(SvgAttr.cy)),
            width: rx * 2,
            height: ry * 2,
          ),
        );
      case 'line':
        return Path()
          ..moveTo(n(SvgAttr.x1), n(SvgAttr.y1))
          ..lineTo(n(SvgAttr.x2), n(SvgAttr.y2));
      case 'polyline':
      case 'polygon':
        final List<double>? points =
            v.get(index, SvgAttr.points) as List<double>?;
        if (points == null || points.length < 4) return null;
        final Path path = Path()..moveTo(points[0], points[1]);
        for (int i = 2; i + 1 < points.length; i += 2) {
          path.lineTo(points[i], points[i + 1]);
        }
        if (tag == 'polygon') path.close();
        return path;
      case 'path':
        final SvgPathData? data = v.get(index, SvgAttr.d) as SvgPathData?;
        return data == null ? null : _pathFor(data);
    }
    return null;
  }

  final Expando<Path> _paths = Expando<Path>();

  Path _pathFor(SvgPathData data) {
    final Path? cached = _paths[data];
    if (cached != null) return cached;
    final Path path = Path();
    for (final SvgPathCommand c in data.commands) {
      final List<double> a = c.args;
      switch (c.verb) {
        case SvgPathVerb.moveTo:
          path.moveTo(a[0], a[1]);
        case SvgPathVerb.lineTo:
          path.lineTo(a[0], a[1]);
        case SvgPathVerb.cubicTo:
          path.cubicTo(a[0], a[1], a[2], a[3], a[4], a[5]);
        case SvgPathVerb.quadTo:
          path.quadraticBezierTo(a[0], a[1], a[2], a[3]);
        case SvgPathVerb.arcTo:
          if (a[0] == 0 || a[1] == 0) {
            path.lineTo(a[5], a[6]);
          } else {
            path.arcToPoint(
              Offset(a[5], a[6]),
              radius: Radius.elliptical(a[0], a[1]),
              rotation: a[2],
              largeArc: a[3] != 0,
              clockwise: a[4] != 0,
            );
          }
        case SvgPathVerb.close:
          path.close();
      }
    }
    _paths[data] = path;
    return path;
  }

  void _drawMarkers(
    Canvas canvas,
    _Values v,
    Path path,
    _Ctx ctx,
    Color? fill,
    Color? stroke,
  ) {
    final List<ui.PathMetric> metrics = path.computeMetrics().toList();
    if (metrics.isEmpty) return;
    if (ctx.markerStart.isNotEmpty) {
      final ui.Tangent? tangent = metrics.first.getTangentForOffset(0);
      if (tangent != null) {
        _drawMarker(
          canvas,
          v,
          ctx.markerStart,
          tangent,
          true,
          ctx,
          fill,
          stroke,
        );
      }
    }
    if (ctx.markerEnd.isNotEmpty) {
      final ui.PathMetric last = metrics.last;
      final ui.Tangent? tangent = last.getTangentForOffset(last.length);
      if (tangent != null) {
        _drawMarker(
          canvas,
          v,
          ctx.markerEnd,
          tangent,
          false,
          ctx,
          fill,
          stroke,
        );
      }
    }
  }

  void _drawMarker(
    Canvas canvas,
    _Values v,
    String id,
    ui.Tangent tangent,
    bool start,
    _Ctx ctx,
    Color? fill,
    Color? stroke,
  ) {
    final int? index = svg.ids[id];
    if (index == null) return;
    final SvgNode node = svg.nodes[index];
    final SvgMarker? marker = node.marker;
    if (marker == null) return;
    double angle;
    final double? fixed = marker.orient;
    if (fixed != null) {
      angle = fixed * math.pi / 180;
    } else {
      angle = math.atan2(tangent.vector.dy, tangent.vector.dx);
      if (start && node.orientReverse) angle += math.pi;
    }
    canvas.save();
    canvas.translate(tangent.position.dx, tangent.position.dy);
    canvas.rotate(angle);
    if (marker.strokeWidthUnits) canvas.scale(ctx.strokeWidth);
    final SvgViewBox? box = marker.viewBox;
    if (box != null) {
      final double s = math.min(
        marker.markerWidth / box.width,
        marker.markerHeight / box.height,
      );
      canvas.scale(s);
    }
    canvas.translate(-marker.refX, -marker.refY);
    // Marker content inherits from the marker's own ancestors, not from the
    // element it decorates.
    _Ctx markerCtx = _Ctx.root();
    final List<int> chain = <int>[];
    for (int i = index; i >= 0; i = svg.nodes[i].parent) {
      chain.add(i);
    }
    for (final int i in chain.reversed) {
      markerCtx = markerCtx.child(
        i,
        v,
        markerCtx.ctm,
        null,
        contextFill: fill,
        contextStroke: stroke,
      );
    }
    for (final int child in node.children) {
      _walk(canvas, v, child, markerCtx, null);
    }
    canvas.restore();
  }

  void _drawText(
    Canvas canvas,
    _Values v,
    int index,
    _Ctx ctx,
    List<_Region>? regions,
  ) {
    double n(int node, SvgAttr attr) => (v.get(node, attr) as double?) ?? 0;
    double penX = n(index, SvgAttr.x) + n(index, SvgAttr.dx);
    double penY = n(index, SvgAttr.y) + n(index, SvgAttr.dy);
    double chunkX = penX;
    double chunkY = penY;
    _Ctx chunkCtx = ctx;
    final List<InlineSpan> spans = <InlineSpan>[];
    Rect? bounds;

    void flush() {
      if (spans.isEmpty) return;
      final TextPainter painter = TextPainter(
        text: TextSpan(children: List<InlineSpan>.of(spans)),
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.noScaling,
      )..layout();
      spans.clear();
      final double width = painter.width;
      final double left = switch (chunkCtx.anchor) {
        'middle' => chunkX - width / 2,
        'end' => chunkX - width,
        _ => chunkX,
      };
      final double baseline = painter.computeDistanceToActualBaseline(
        TextBaseline.alphabetic,
      );
      final double top = switch (chunkCtx.baseline) {
        'middle' || 'central' => chunkY - painter.height / 2,
        'hanging' || 'text-top' || 'text-before-edge' => chunkY,
        'text-bottom' ||
        'text-after-edge' ||
        'ideographic' => chunkY - painter.height,
        _ => chunkY - baseline,
      };
      painter.paint(canvas, Offset(left, top));
      final Rect rect = Rect.fromLTWH(left, top, width, painter.height);
      bounds = bounds?.expandToInclude(rect) ?? rect;
      penX = left + width;
      painter.dispose();
    }

    void addText(String text, _Ctx style) {
      if (text.isEmpty) return;
      final Color? color = style.visibility == 'visible'
          ? _paintColor(style.fill, style.fillOpacity, style)
          : null;
      final String family = (style.fontFamily ?? '').toLowerCase();
      final bool mono =
          family.contains('mono') ||
          family.contains('courier') ||
          family.contains('consol') ||
          family.contains('menlo') ||
          family.contains('code');
      spans.add(
        TextSpan(
          text: text,
          style: TextStyle(
            color: color ?? const Color(0x00000000),
            fontSize: style.fontSize,
            fontWeight: FontWeight
                .values[((style.fontWeight / 100).round() - 1).clamp(0, 8)],
            fontStyle: style.fontStyle == 'normal'
                ? FontStyle.normal
                : FontStyle.italic,
            fontFamily: mono ? palette.monoFamily : kSansFamily,
            fontFamilyFallback: mono ? palette.monoFallback : null,
          ),
        ),
      );
    }

    void addContent(int node, _Ctx style) {
      final Object? replaced = v.get(node, SvgAttr.text);
      if (replaced is String) {
        addText(replaced, style);
        return;
      }
      for (final int child in svg.nodes[node].children) {
        final SvgNode c = svg.nodes[child];
        if (c.tag == '#text') {
          addText(c.props[SvgAttr.text]! as String, style);
          continue;
        }
        if (v.get(child, SvgAttr.display) == 'none') continue;
        final _Ctx childCtx = style.child(child, v, style.ctm, c.title);
        final double? x = v.get(child, SvgAttr.x) as double?;
        final double? y = v.get(child, SvgAttr.y) as double?;
        final double dx = n(child, SvgAttr.dx);
        final double dy = n(child, SvgAttr.dy);
        if (x != null || y != null || dx != 0 || dy != 0) {
          flush();
          chunkX = (x ?? penX) + dx;
          chunkY = (y ?? penY) + dy;
          penX = chunkX;
          penY = chunkY;
          chunkCtx = childCtx;
        }
        addContent(child, childCtx);
      }
    }

    addContent(index, ctx);
    flush();
    final String? title = ctx.title;
    final Rect? textBounds = bounds;
    if (regions != null && title != null && textBounds != null) {
      regions.add(
        _Region(
          null,
          MatrixUtils.transformRect(ctx.ctm, textBounds),
          false,
          title,
        ),
      );
    }
  }
}

Matrix4 _matrix4(SvgMatrix m) => Matrix4(
  m.a,
  m.b,
  0,
  0, //
  m.c,
  m.d,
  0,
  0, //
  0,
  0,
  1,
  0, //
  m.e,
  m.f,
  0,
  1,
);

Path _dashed(Path source, List<double> pattern) {
  final Path dashed = Path();
  final double total = pattern.fold<double>(0, (double a, double b) => a + b);
  if (total <= 0) return source;
  for (final ui.PathMetric metric in source.computeMetrics()) {
    double distance = 0;
    int i = 0;
    while (distance < metric.length) {
      final double length = pattern[i % pattern.length];
      if (i.isEven) {
        dashed.addPath(
          metric.extractPath(distance, distance + length),
          Offset.zero,
        );
      }
      distance += length;
      i++;
    }
  }
  return dashed;
}
