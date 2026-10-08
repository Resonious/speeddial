import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../theme.dart';
import 'mermaid_layout.dart';
import 'mermaid_parser.dart';

final LinkedHashMap<String, FlowGraph?> _graphCache =
    LinkedHashMap<String, FlowGraph?>();

/// Parses [source] once; message rebuilds during streaming hit the cache.
/// Unsupported sources are cached too (as null).
FlowGraph? cachedMermaidGraph(String source) {
  if (_graphCache.containsKey(source)) {
    final FlowGraph? graph = _graphCache.remove(source);
    _graphCache[source] = graph;
    return graph;
  }
  final FlowGraph? graph = parseMermaidFlowchart(source);
  _graphCache[source] = graph;
  if (_graphCache.length > 32) _graphCache.remove(_graphCache.keys.first);
  return graph;
}

/// Colors and text style a scene is drawn with.
class MermaidStyle {
  MermaidStyle.of(BuildContext context)
    : textScaler = MediaQuery.textScalerOf(context),
      theme = Theme.of(context) {
    final ColorScheme scheme = theme.colorScheme;
    final SpeedDialColors colors = theme.speedDialColors;
    text = (theme.textTheme.bodySmall ?? const TextStyle()).copyWith(
      fontSize: 13,
      height: 1.3,
      color: scheme.onSurface,
    );
    edgeText = text.copyWith(fontSize: 12, color: scheme.onSurfaceVariant);
    titleText = text.copyWith(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: scheme.onSurfaceVariant,
    );
    nodeFill = scheme.surface;
    nodeStroke = Color.lerp(scheme.primary, scheme.outline, 0.35)!;
    edge = scheme.onSurfaceVariant;
    labelFill = colors.codeBackground;
    subgraphFill = scheme.primary.withValues(alpha: 0.05);
    subgraphStroke = colors.border;
  }

  final ThemeData theme;
  final TextScaler textScaler;
  late final TextStyle text;
  late final TextStyle edgeText;
  late final TextStyle titleText;
  late final Color nodeFill;
  late final Color nodeStroke;
  late final Color edge;
  late final Color labelFill;
  late final Color subgraphFill;
  late final Color subgraphStroke;

  bool sameAs(MermaidStyle other) =>
      theme == other.theme && textScaler == other.textScaler;
}

const double _labelMaxWidth = 220;
const double _padX = 12;
const double _padY = 8;
const double _cylinderCap = 6;
const double _margin = 8;

/// Measured text, layout and prebuilt paths for one diagram. Painting only
/// replays these, so repaints allocate nothing.
class MermaidScene {
  MermaidScene(this.graph, this.style) {
    final FlowLayout raw = layoutFlowchart(
      graph,
      nodeSize: _nodeSize,
      labelSize: (String label) {
        final TextPainter painter = _edgeLabel(label);
        return Size(painter.width + 8, painter.height + 2);
      },
      titleSize: (FlowSubgraph subgraph) {
        if (subgraph.title.isEmpty) return Size.zero;
        final TextPainter painter = _measure(
          subgraph.title,
          style.titleText,
          _labelMaxWidth * 1.5,
        );
        _titles[subgraph] = painter;
        return painter.size;
      },
    );
    layout = raw;
    size = Size(raw.size.width + _margin * 2, raw.size.height + _margin * 2);
    for (final LaidOutEdge edge in raw.edges) {
      _edges.add(_EdgeGeometry.of(edge, _edgeLabels));
    }
  }

  final FlowGraph graph;
  final MermaidStyle style;
  late final FlowLayout layout;
  late final Size size;

  final Map<FlowNode, TextPainter> _nodeLabels = <FlowNode, TextPainter>{};
  final Map<String, TextPainter> _edgeLabels = <String, TextPainter>{};
  final Map<FlowSubgraph, TextPainter> _titles = <FlowSubgraph, TextPainter>{};
  final List<_EdgeGeometry> _edges = <_EdgeGeometry>[];

  TextPainter _measure(String text, TextStyle textStyle, double maxWidth) {
    return TextPainter(
      text: TextSpan(text: text, style: textStyle),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      textScaler: style.textScaler,
    )..layout(maxWidth: maxWidth);
  }

  TextPainter _edgeLabel(String label) => _edgeLabels[label] ??= _measure(
    label,
    style.edgeText,
    _labelMaxWidth * 0.8,
  );

  Size _nodeSize(FlowNode node) {
    final TextPainter painter = _measure(
      node.label,
      style.text,
      _labelMaxWidth,
    );
    _nodeLabels[node] = painter;
    final double tw = painter.width;
    final double th = painter.height;
    final double w = tw + _padX * 2;
    final double h = th + _padY * 2;
    switch (node.shape) {
      case NodeShape.rect:
      case NodeShape.round:
        return Size(w, h);
      case NodeShape.subroutine:
        return Size(w + 16, h);
      case NodeShape.stadium:
        return Size(w + h / 2, h);
      case NodeShape.cylinder:
        return Size(w, h + _cylinderCap * 2);
      case NodeShape.circle:
      case NodeShape.doubleCircle:
        final double d =
            math.sqrt(tw * tw + th * th) +
            _padY * 2 +
            (node.shape == NodeShape.doubleCircle ? 10 : 0);
        return Size(d, d);
      case NodeShape.asymmetric:
        return Size(w + h / 3, h);
      case NodeShape.rhombus:
        // Half-diagonals a, b that contain the text box (p, q):
        // p / a + q / b == 1 with a = p + 2q.
        final double p = tw / 2 + 4;
        final double q = th / 2 + 4;
        return Size((p + 2 * q) * 2, (p / 2 + q) * 2);
      case NodeShape.hexagon:
        return Size(w + h / 2, h);
      case NodeShape.parallelogram:
      case NodeShape.parallelogramAlt:
      case NodeShape.trapezoid:
      case NodeShape.trapezoidAlt:
        return Size(w + h * 0.6, h);
    }
  }

  void dispose() {
    for (final TextPainter painter in _nodeLabels.values) {
      painter.dispose();
    }
    for (final TextPainter painter in _edgeLabels.values) {
      painter.dispose();
    }
    for (final TextPainter painter in _titles.values) {
      painter.dispose();
    }
  }

  void paint(Canvas canvas) {
    canvas.save();
    canvas.translate(_margin, _margin);
    final Paint fill = Paint()..style = PaintingStyle.fill;
    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    for (final LaidOutSubgraph subgraph in layout.subgraphs) {
      final RRect frame = RRect.fromRectAndRadius(
        subgraph.rect,
        const Radius.circular(6),
      );
      canvas.drawRRect(frame, fill..color = style.subgraphFill);
      canvas.drawRRect(frame, stroke..color = style.subgraphStroke);
      final TextPainter? title = _titles[subgraph.subgraph];
      title?.paint(canvas, subgraph.rect.topLeft + const Offset(10, 6));
    }

    for (final _EdgeGeometry edge in _edges) {
      edge.paint(canvas, style.edge, fill, stroke);
    }

    for (final LaidOutNode node in layout.nodes) {
      _paintNode(canvas, node, fill, stroke);
    }

    // Labels last so they sit above crossing edges.
    for (final _EdgeGeometry edge in _edges) {
      final TextPainter? label = edge.label;
      final Offset? center = edge.labelCenter;
      if (label == null || center == null) continue;
      final Rect box = Rect.fromCenter(
        center: center,
        width: label.width + 8,
        height: label.height + 2,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(box, const Radius.circular(3)),
        fill..color = style.labelFill,
      );
      label.paint(canvas, box.topLeft + const Offset(4, 1));
    }
    canvas.restore();
  }

  void _paintNode(
    Canvas canvas,
    LaidOutNode laidOut,
    Paint fill,
    Paint stroke,
  ) {
    final Rect r = laidOut.rect;
    final double h = r.height;
    fill.color = style.nodeFill;
    stroke.color = style.nodeStroke;
    void shape(Path path) {
      canvas.drawPath(path, fill);
      canvas.drawPath(path, stroke);
    }

    Path polygon(List<Offset> points) => Path()..addPolygon(points, true);

    Offset textCenter = r.center;
    switch (laidOut.node.shape) {
      case NodeShape.rect:
        shape(
          Path()
            ..addRRect(RRect.fromRectAndRadius(r, const Radius.circular(3))),
        );
      case NodeShape.round:
        shape(
          Path()
            ..addRRect(RRect.fromRectAndRadius(r, const Radius.circular(10))),
        );
      case NodeShape.stadium:
        shape(
          Path()..addRRect(RRect.fromRectAndRadius(r, Radius.circular(h / 2))),
        );
      case NodeShape.subroutine:
        shape(Path()..addRect(r));
        canvas.drawLine(
          Offset(r.left + 8, r.top),
          Offset(r.left + 8, r.bottom),
          stroke,
        );
        canvas.drawLine(
          Offset(r.right - 8, r.top),
          Offset(r.right - 8, r.bottom),
          stroke,
        );
      case NodeShape.cylinder:
        const double cap = _cylinderCap;
        final Radius radius = Radius.elliptical(r.width / 2, cap);
        shape(
          Path()
            ..moveTo(r.left, r.top + cap)
            ..lineTo(r.left, r.bottom - cap)
            ..arcToPoint(
              Offset(r.right, r.bottom - cap),
              radius: radius,
              clockwise: false,
            )
            ..lineTo(r.right, r.top + cap)
            ..arcToPoint(Offset(r.left, r.top + cap), radius: radius)
            ..close(),
        );
        shape(Path()..addOval(Rect.fromLTWH(r.left, r.top, r.width, cap * 2)));
        textCenter = r.center + const Offset(0, cap / 2);
      case NodeShape.circle:
        shape(Path()..addOval(r));
      case NodeShape.doubleCircle:
        shape(Path()..addOval(r));
        canvas.drawOval(r.deflate(4), stroke);
      case NodeShape.asymmetric:
        shape(
          polygon(<Offset>[
            r.topLeft,
            r.topRight,
            r.bottomRight,
            r.bottomLeft,
            Offset(r.left + h / 3, r.center.dy),
          ]),
        );
        textCenter = r.center + Offset(h / 6, 0);
      case NodeShape.rhombus:
        shape(
          polygon(<Offset>[
            r.topCenter,
            r.centerRight,
            r.bottomCenter,
            r.centerLeft,
          ]),
        );
      case NodeShape.hexagon:
        final double k = h / 4;
        shape(
          polygon(<Offset>[
            Offset(r.left + k, r.top),
            Offset(r.right - k, r.top),
            r.centerRight,
            Offset(r.right - k, r.bottom),
            Offset(r.left + k, r.bottom),
            r.centerLeft,
          ]),
        );
      case NodeShape.parallelogram:
        final double k = h * 0.3;
        shape(
          polygon(<Offset>[
            Offset(r.left + k, r.top),
            r.topRight,
            Offset(r.right - k, r.bottom),
            r.bottomLeft,
          ]),
        );
      case NodeShape.parallelogramAlt:
        final double k = h * 0.3;
        shape(
          polygon(<Offset>[
            r.topLeft,
            Offset(r.right - k, r.top),
            r.bottomRight,
            Offset(r.left + k, r.bottom),
          ]),
        );
      case NodeShape.trapezoid:
        final double k = h * 0.3;
        shape(
          polygon(<Offset>[
            Offset(r.left + k, r.top),
            Offset(r.right - k, r.top),
            r.bottomRight,
            r.bottomLeft,
          ]),
        );
      case NodeShape.trapezoidAlt:
        final double k = h * 0.3;
        shape(
          polygon(<Offset>[
            r.topLeft,
            r.topRight,
            Offset(r.right - k, r.bottom),
            Offset(r.left + k, r.bottom),
          ]),
        );
    }
    final TextPainter text = _nodeLabels[laidOut.node]!;
    text.paint(canvas, textCenter - Offset(text.width / 2, text.height / 2));
  }
}

/// One edge's prebuilt stroke and head paths.
class _EdgeGeometry {
  _EdgeGeometry(this.edge, this.line, this.heads, this.label, this.labelCenter);

  factory _EdgeGeometry.of(
    LaidOutEdge laidOut,
    Map<String, TextPainter> labels,
  ) {
    final FlowEdge edge = laidOut.edge;
    final String? text = edge.label;
    final TextPainter? label = text == null ? null : labels[text];
    final Path line = Path();
    final Path heads = Path();
    if (edge.stroke == EdgeStroke.invisible) {
      return _EdgeGeometry(edge, line, heads, null, null);
    }
    final List<Offset> p = laidOut.points;
    Offset? labelCenter = laidOut.labelCenter;
    Offset endDirection;
    Offset startDirection;
    if (laidOut.selfLoop) {
      final Rect r = Rect.fromPoints(p[0], p[1]);
      const double reach = 26;
      if (laidOut.vertical) {
        final Offset a = Offset(r.right, r.center.dy - r.height / 4);
        final Offset b = Offset(r.right, r.center.dy + r.height / 4);
        line
          ..moveTo(a.dx, a.dy)
          ..cubicTo(a.dx + reach, a.dy - 6, b.dx + reach, b.dy + 6, b.dx, b.dy);
        endDirection = const Offset(-1, 0);
        startDirection = const Offset(-1, 0);
        if (label != null) {
          labelCenter = Offset(r.right + 24 + label.width / 2, r.center.dy);
        }
        _addHead(heads, edge.endHead, b, endDirection);
        _addHead(heads, edge.startHead, a, startDirection);
      } else {
        final Offset a = Offset(r.center.dx - r.width / 4, r.bottom);
        final Offset b = Offset(r.center.dx + r.width / 4, r.bottom);
        line
          ..moveTo(a.dx, a.dy)
          ..cubicTo(a.dx - 6, a.dy + reach, b.dx + 6, b.dy + reach, b.dx, b.dy);
        endDirection = const Offset(0, -1);
        startDirection = const Offset(0, -1);
        if (label != null) {
          labelCenter = Offset(r.center.dx, r.bottom + 24 + label.height / 2);
        }
        _addHead(heads, edge.endHead, b, endDirection);
        _addHead(heads, edge.startHead, a, startDirection);
      }
    } else {
      endDirection = _axisDirection(p[p.length - 2], p.last, laidOut.vertical);
      startDirection = _axisDirection(p[1], p.first, laidOut.vertical);
      // Short straight stubs leave and enter nodes along the flow, so heads
      // line up; the waypoints between only steer a B-spline.
      _basis(line, <Offset>[
        p.first,
        p.first - startDirection * _stub(p.first, p[1], laidOut.vertical),
        ...p.sublist(1, p.length - 1),
        p.last -
            endDirection * _stub(p[p.length - 2], p.last, laidOut.vertical),
        p.last,
      ]);
      _addHead(heads, edge.endHead, p.last, endDirection);
      _addHead(heads, edge.startHead, p.first, startDirection);
      if (labelCenter != null) {
        labelCenter = _pointAtMain(line, labelCenter, laidOut.vertical);
      }
    }
    return _EdgeGeometry(
      edge,
      edge.stroke == EdgeStroke.dotted ? _dashed(line) : line,
      heads,
      label,
      labelCenter,
    );
  }

  final FlowEdge edge;
  final Path line;
  final Path heads;
  final TextPainter? label;
  final Offset? labelCenter;

  void paint(Canvas canvas, Color color, Paint fill, Paint stroke) {
    if (edge.stroke == EdgeStroke.invisible) return;
    final double previousWidth = stroke.strokeWidth;
    stroke
      ..color = color
      ..strokeWidth = edge.stroke == EdgeStroke.thick ? 2.6 : 1.3;
    canvas.drawPath(line, stroke);
    stroke.strokeWidth = 1.3;
    canvas.drawPath(heads, fill..color = color);
    canvas.drawPath(heads, stroke);
    stroke.strokeWidth = previousWidth;
  }
}

double _stub(Offset a, Offset b, bool vertical) {
  final double distance = vertical ? (b.dy - a.dy).abs() : (b.dx - a.dx).abs();
  return math.min(10, distance / 3);
}

/// Uniform cubic B-spline through the ends of [points], steered by the
/// interior ones (d3's curveBasis). Smooth even when waypoints zigzag.
void _basis(Path path, List<Offset> points) {
  path.moveTo(points.first.dx, points.first.dy);
  if (points.length == 2) {
    path.lineTo(points.last.dx, points.last.dy);
    return;
  }
  Offset p0 = points[0];
  Offset p1 = points[1];
  final Offset lead = (p0 * 5 + p1) / 6;
  path.lineTo(lead.dx, lead.dy);
  void segment(Offset next) {
    final Offset c1 = (p0 * 2 + p1) / 3;
    final Offset c2 = (p0 + p1 * 2) / 3;
    final Offset end = (p0 + p1 * 4 + next) / 6;
    path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, end.dx, end.dy);
  }

  for (int i = 2; i < points.length; i++) {
    segment(points[i]);
    p0 = p1;
    p1 = points[i];
  }
  segment(p1);
  path.lineTo(p1.dx, p1.dy);
}

/// The point on [path] at [target]'s main-axis coordinate, so a label sits
/// on its (smoothed) line rather than at the raw waypoint.
Offset _pointAtMain(Path path, Offset target, bool vertical) {
  Offset best = target;
  double bestGap = double.infinity;
  for (final ui.PathMetric metric in path.computeMetrics()) {
    for (double d = 0; d <= metric.length; d += 2) {
      final Offset? p = metric.getTangentForOffset(d)?.position;
      if (p == null) continue;
      final double gap = vertical
          ? (p.dy - target.dy).abs()
          : (p.dx - target.dx).abs();
      if (gap < bestGap) {
        bestGap = gap;
        best = p;
      }
    }
  }
  return best;
}

/// Unit vector along the main axis pointing from [from] to [to].
Offset _axisDirection(Offset from, Offset to, bool vertical) {
  if (vertical) return Offset(0, to.dy >= from.dy ? 1 : -1);
  return Offset(to.dx >= from.dx ? 1 : -1, 0);
}

/// Adds a head whose tip is at [tip], pointing along [direction].
void _addHead(Path heads, EdgeHead head, Offset tip, Offset direction) {
  final Offset normal = Offset(-direction.dy, direction.dx);
  switch (head) {
    case EdgeHead.none:
      return;
    case EdgeHead.arrow:
      final Offset base = tip - direction * 8;
      heads.addPolygon(<Offset>[
        tip,
        base + normal * 4.5,
        base - normal * 4.5,
      ], true);
    case EdgeHead.circle:
      heads.addOval(Rect.fromCircle(center: tip - direction * 4, radius: 4));
    case EdgeHead.cross:
      final Offset c = tip - direction * 5;
      const double k = 3.5;
      heads
        ..moveTo(c.dx - k, c.dy - k)
        ..lineTo(c.dx + k, c.dy + k)
        ..moveTo(c.dx + k, c.dy - k)
        ..lineTo(c.dx - k, c.dy + k);
  }
}

Path _dashed(Path source) {
  final Path dashed = Path();
  for (final ui.PathMetric metric in source.computeMetrics()) {
    double distance = 0;
    while (distance < metric.length) {
      dashed.addPath(metric.extractPath(distance, distance + 4), Offset.zero);
      distance += 7;
    }
  }
  return dashed;
}

/// Builds (and rebuilds on theme or text-scale changes) the scene for
/// [graph], then hands it to [builder].
class MermaidSceneBuilder extends StatefulWidget {
  const MermaidSceneBuilder({
    super.key,
    required this.graph,
    required this.builder,
  });

  final FlowGraph graph;
  final Widget Function(BuildContext context, MermaidScene scene) builder;

  @override
  State<MermaidSceneBuilder> createState() => _MermaidSceneBuilderState();
}

class _MermaidSceneBuilderState extends State<MermaidSceneBuilder> {
  MermaidScene? _scene;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _refresh();
  }

  @override
  void didUpdateWidget(MermaidSceneBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.graph != widget.graph) _refresh();
  }

  void _refresh() {
    final MermaidStyle style = MermaidStyle.of(context);
    final MermaidScene? current = _scene;
    if (current != null &&
        current.graph == widget.graph &&
        current.style.sameAs(style)) {
      return;
    }
    current?.dispose();
    _scene = MermaidScene(widget.graph, style);
  }

  @override
  void dispose() {
    _scene?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _scene!);
}

class MermaidPainter extends CustomPainter {
  const MermaidPainter(this.scene, {this.scale = 1});

  final MermaidScene scene;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(scale);
    scene.paint(canvas);
    canvas.restore();
  }

  @override
  bool shouldRepaint(MermaidPainter oldDelegate) =>
      oldDelegate.scene != scene || oldDelegate.scale != scale;
}

/// Inline diagram: scaled down to fit the available width (to a floor,
/// past which it scrolls horizontally).
class MermaidDiagram extends StatelessWidget {
  const MermaidDiagram({super.key, required this.graph});

  final FlowGraph graph;

  static const double minScale = 0.6;

  @override
  Widget build(BuildContext context) {
    return MermaidSceneBuilder(
      graph: graph,
      builder: (BuildContext context, MermaidScene scene) => LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double available = constraints.maxWidth;
          double scale = available.isFinite
              ? math.min(1.0, available / scene.size.width)
              : 1.0;
          final bool scrolls = scale < minScale;
          if (scrolls) scale = minScale;
          final Widget canvas = Semantics(
            label: 'Flowchart diagram',
            child: CustomPaint(
              size: scene.size * scale,
              painter: MermaidPainter(scene, scale: scale),
            ),
          );
          if (!scrolls) return Center(child: canvas);
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: canvas,
          );
        },
      ),
    );
  }
}

/// Full-screen pan/zoom view of a diagram.
Future<void> showMermaidViewer(BuildContext context, FlowGraph graph) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) =>
        Dialog.fullscreen(child: _MermaidViewer(graph: graph)),
  );
}

class _MermaidViewer extends StatefulWidget {
  const _MermaidViewer({required this.graph});

  final FlowGraph graph;

  @override
  State<_MermaidViewer> createState() => _MermaidViewerState();
}

class _MermaidViewerState extends State<_MermaidViewer> {
  final TransformationController _transform = TransformationController();
  Size? _fittedFor;

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _fit(Size viewport, Size content) {
    if (_fittedFor == viewport) return;
    _fittedFor = viewport;
    final double scale = math.min(
      2.0,
      math.min(
            viewport.width / content.width,
            viewport.height / content.height,
          ) *
          0.95,
    );
    final double dx = (viewport.width - content.width * scale) / 2;
    final double dy = (viewport.height - content.height * scale) / 2;
    _transform.value = Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: MermaidSceneBuilder(
            graph: widget.graph,
            builder: (BuildContext context, MermaidScene scene) =>
                LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    _fit(constraints.biggest, scene.size);
                    return InteractiveViewer(
                      transformationController: _transform,
                      constrained: false,
                      boundaryMargin: const EdgeInsets.all(double.infinity),
                      minScale: 0.1,
                      maxScale: 6,
                      child: CustomPaint(
                        size: scene.size,
                        painter: MermaidPainter(scene),
                      ),
                    );
                  },
                ),
          ),
        ),
        Positioned(
          top: 8,
          right: 8,
          child: SafeArea(
            child: IconButton(
              tooltip: 'Close',
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ),
      ],
    );
  }
}
