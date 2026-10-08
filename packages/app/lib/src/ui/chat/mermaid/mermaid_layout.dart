import 'dart:math' as math;
import 'dart:ui';

import 'mermaid_parser.dart';

/// Layered (Sugiyama-style) layout for a parsed [FlowGraph].
///
/// Each subgraph is laid out on its own and then treated as one large node by
/// its parent, so subgraph frames never overlap. Within a level:
/// cycles are broken by reversing DFS back edges, nodes get longest-path
/// ranks (every edge spans two ranks so its label has a rank of its own),
/// long edges are split into dummy vertices, layer order comes from
/// barycenter sweeps that keep the fewest crossings, and cross-axis
/// positions are the least-squares fit to neighbor averages under minimum
/// spacing (pool-adjacent-violators).
class FlowLayout {
  const FlowLayout({
    required this.size,
    required this.nodes,
    required this.edges,
    required this.subgraphs,
  });

  final Size size;
  final List<LaidOutNode> nodes;
  final List<LaidOutEdge> edges;

  /// Outer subgraphs come first, so painting in order nests correctly.
  final List<LaidOutSubgraph> subgraphs;
}

class LaidOutNode {
  const LaidOutNode(this.node, this.rect);

  final FlowNode node;
  final Rect rect;
}

class LaidOutSubgraph {
  const LaidOutSubgraph(this.subgraph, this.rect);

  final FlowSubgraph subgraph;
  final Rect rect;
}

class LaidOutEdge {
  const LaidOutEdge({
    required this.edge,
    required this.points,
    required this.vertical,
    this.labelCenter,
    this.selfLoop = false,
  });

  final FlowEdge edge;

  /// Start point on the source boundary, the route's waypoints, and the end
  /// point on the target boundary, in edge direction. Segments are meant to
  /// be drawn as curves whose tangents follow the main axis at each point.
  final List<Offset> points;

  /// Whether the level this edge was laid out in flows vertically.
  final bool vertical;

  final Offset? labelCenter;

  /// Node-to-itself edge; [points] holds the node's rect corners
  /// (top-left, bottom-right) and the painter draws a loop beside it.
  final bool selfLoop;
}

class FlowLayoutMetrics {
  const FlowLayoutMetrics({
    this.rankGap = 22,
    this.nodeGap = 28,
    this.dummyGap = 12,
    this.subgraphPadding = 14,
    this.loopSize = 18,
  });

  /// Spacing between consecutive ranks; adjacent nodes sit two ranks apart.
  final double rankGap;

  /// Cross-axis spacing between neighboring nodes.
  final double nodeGap;

  /// Cross-axis spacing next to an edge's waypoint.
  final double dummyGap;

  final double subgraphPadding;
  final double loopSize;
}

FlowLayout layoutFlowchart(
  FlowGraph graph, {
  required Size Function(FlowNode node) nodeSize,
  required Size Function(String label) labelSize,
  required Size Function(FlowSubgraph subgraph) titleSize,
  FlowLayoutMetrics metrics = const FlowLayoutMetrics(),
}) {
  return _FlowLayouter(graph, nodeSize, labelSize, titleSize, metrics).run();
}

/// One laid-out level: geometry relative to the level's own origin.
class _Block {
  _Block(this.size);

  final Size size;
  final Map<FlowNode, Rect> nodes = <FlowNode, Rect>{};
  final List<(FlowSubgraph, Rect)> subgraphs = <(FlowSubgraph, Rect)>[];
  final List<_Route> routes = <_Route>[];

  void addShifted(_Block child, Offset by) {
    for (final MapEntry<FlowNode, Rect> entry in child.nodes.entries) {
      nodes[entry.key] = entry.value.shift(by);
    }
    for (final (FlowSubgraph subgraph, Rect rect) in child.subgraphs) {
      subgraphs.add((subgraph, rect.shift(by)));
    }
    for (final _Route route in child.routes) {
      routes.add(route.shift(by));
    }
  }
}

/// An edge's route before endpoints are attached to the real node boxes.
class _Route {
  _Route(this.edge, this.waypoints, this.vertical, this.label, this.selfLoop);

  final FlowEdge edge;
  final List<Offset> waypoints;
  final bool vertical;
  final Offset? label;
  final bool selfLoop;

  _Route shift(Offset by) => _Route(
    edge,
    <Offset>[for (final Offset p in waypoints) p + by],
    vertical,
    label == null ? null : label! + by,
    selfLoop,
  );
}

/// A vertex in one level's layered graph: an item (node or subgraph block)
/// or an edge waypoint.
class _Vertex {
  _Vertex(this.cross, this.main, {this.item, this.labelled = false});

  final double cross;
  final double main;
  final int? item;
  final bool labelled;
  final List<_Vertex> ups = <_Vertex>[];
  final List<_Vertex> downs = <_Vertex>[];
  int rank = 0;
  int order = 0;
  double x = 0;

  /// For waypoints next to an item: where the real endpoint sits on the
  /// cross axis relative to that item's center. Non-zero when the item is
  /// a subgraph block and the edge attaches to a node inside it.
  double upPort = 0;
  double downPort = 0;

  bool get dummy => item == null;

  /// Where this vertex wants to be on the cross axis according to neighbor
  /// [n] (one of [ups] when [up], else of [downs]).
  double targetFrom(_Vertex n, bool up) {
    if (dummy) return n.x + (up ? upPort : downPort);
    return n.x - (up ? n.downPort : n.upPort);
  }

  /// [targetFrom] in layer-order units, for barycenter ordering.
  double orderFrom(_Vertex n, bool up) {
    if (!dummy || n.cross <= 0) return n.order.toDouble();
    final double port = up ? upPort : downPort;
    return n.order + (port / n.cross).clamp(-0.49, 0.49);
  }
}

class _LevelEdge {
  _LevelEdge(this.edge, this.from, this.to);

  final FlowEdge edge;
  int from;
  int to;
  double fromPort = 0;
  double toPort = 0;
  bool reversed = false;
  final List<_Vertex> chain = <_Vertex>[];
  _Vertex? labelVertex;
}

class _FlowLayouter {
  _FlowLayouter(
    this.graph,
    this.nodeSize,
    this.labelSize,
    this.titleSize,
    this.metrics,
  );

  final FlowGraph graph;
  final Size Function(FlowNode node) nodeSize;
  final Size Function(String label) labelSize;
  final Size Function(FlowSubgraph subgraph) titleSize;
  final FlowLayoutMetrics metrics;

  final Map<FlowSubgraph?, List<FlowEdge>> _edgesByLevel =
      <FlowSubgraph?, List<FlowEdge>>{};
  final Map<FlowNode, List<FlowSubgraph>> _chains =
      <FlowNode, List<FlowSubgraph>>{};

  /// Subgraphs with an edge crossing their frame. Like Mermaid, these
  /// ignore their own `direction`: edges entering a block laid out across
  /// the parent's flow would cut through its nodes.
  final Set<FlowSubgraph> _crossed = <FlowSubgraph>{};

  FlowLayout run() {
    for (final FlowNode node in graph.nodes.values) {
      final List<FlowSubgraph> chain = <FlowSubgraph>[];
      for (FlowSubgraph? s = node.parent; s != null; s = s.parent) {
        chain.insert(0, s);
      }
      _chains[node] = chain;
    }
    for (final FlowEdge edge in graph.edges) {
      final List<FlowSubgraph> a = _chains[graph.nodes[edge.from]!]!;
      final List<FlowSubgraph> b = _chains[graph.nodes[edge.to]!]!;
      int depth = 0;
      while (depth < a.length && depth < b.length && a[depth] == b[depth]) {
        depth++;
      }
      final FlowSubgraph? level = depth == 0 ? null : a[depth - 1];
      (_edgesByLevel[level] ??= <FlowEdge>[]).add(edge);
      _crossed
        ..addAll(a.skip(depth))
        ..addAll(b.skip(depth));
    }

    final _Block root = _layoutLevel(null, graph.direction);
    final List<LaidOutEdge> edges = <LaidOutEdge>[
      for (final _Route route in root.routes) _attach(route, root.nodes),
    ];
    return FlowLayout(
      size: root.size,
      nodes: <LaidOutNode>[
        for (final FlowNode node in graph.nodes.values)
          LaidOutNode(node, root.nodes[node]!),
      ],
      edges: edges,
      subgraphs: <LaidOutSubgraph>[
        for (final (FlowSubgraph subgraph, Rect rect) in root.subgraphs)
          LaidOutSubgraph(subgraph, rect),
      ],
    );
  }

  _Block _layoutLevel(FlowSubgraph? level, FlowDirection direction) {
    final bool vertical =
        direction == FlowDirection.topDown ||
        direction == FlowDirection.bottomUp;

    // Items: direct nodes and child subgraph blocks, in declaration order.
    final List<Object> items = <Object>[];
    final List<Size> sizes = <Size>[];
    final Map<FlowNode, int> nodeItem = <FlowNode, int>{};
    final Map<FlowSubgraph, int> subgraphItem = <FlowSubgraph, int>{};
    final Map<FlowSubgraph, _Block> blocks = <FlowSubgraph, _Block>{};
    for (final FlowNode node in graph.nodes.values) {
      if (node.parent == level) {
        nodeItem[node] = items.length;
        items.add(node);
        sizes.add(nodeSize(node));
      }
    }
    for (final FlowSubgraph subgraph in graph.subgraphs) {
      if (subgraph.parent != level) continue;
      final _Block block = _framed(
        subgraph,
        _layoutLevel(
          subgraph,
          _crossed.contains(subgraph)
              ? direction
              : subgraph.direction ?? direction,
        ),
      );
      subgraphItem[subgraph] = items.length;
      blocks[subgraph] = block;
      items.add(subgraph);
      sizes.add(block.size);
    }
    if (items.isEmpty) return _Block(Size.zero);

    final int depth = level == null ? 0 : _depthOf(level);
    int itemFor(FlowNode node) {
      final List<FlowSubgraph> chain = _chains[node]!;
      if (chain.length > depth) return subgraphItem[chain[depth]]!;
      return nodeItem[node]!;
    }

    double portOf(FlowNode node, int item) {
      final Object target = items[item];
      if (target is! FlowSubgraph) return 0;
      final _Block block = blocks[target]!;
      final Offset center = block.nodes[node]!.center;
      return vertical
          ? center.dx - block.size.width / 2
          : center.dy - block.size.height / 2;
    }

    final List<_LevelEdge> edges = <_LevelEdge>[];
    final List<FlowEdge> selfLoops = <FlowEdge>[];
    for (final FlowEdge edge in _edgesByLevel[level] ?? const <FlowEdge>[]) {
      final FlowNode fromNode = graph.nodes[edge.from]!;
      final FlowNode toNode = graph.nodes[edge.to]!;
      final int from = itemFor(fromNode);
      final int to = itemFor(toNode);
      if (from == to) {
        selfLoops.add(edge);
      } else {
        edges.add(
          _LevelEdge(edge, from, to)
            ..fromPort = portOf(fromNode, from)
            ..toPort = portOf(toNode, to),
        );
      }
    }

    // Where each item is first mentioned in the source: cycles are broken
    // along the order the author wrote them in.
    final List<int> firstMention = List<int>.filled(items.length, 1 << 30);
    int mention = 0;
    for (final FlowNode node in graph.nodes.values) {
      final List<FlowSubgraph> chain = _chains[node]!;
      if (level == null ||
          (chain.length >= depth && chain[depth - 1] == level)) {
        final int item = itemFor(node);
        firstMention[item] = math.min(firstMention[item], mention);
      }
      mention++;
    }

    _breakCycles(items.length, edges, firstMention);
    final List<int> ranks = _rank(items.length, edges);

    double crossOf(Size s) => vertical ? s.width : s.height;
    double mainOf(Size s) => vertical ? s.height : s.width;

    final List<_Vertex> vertices = <_Vertex>[
      for (int i = 0; i < items.length; i++)
        _Vertex(crossOf(sizes[i]), mainOf(sizes[i]), item: i)..rank = ranks[i],
    ];
    final List<_Vertex> all = List<_Vertex>.of(vertices);
    for (final _LevelEdge e in edges) {
      final int start = ranks[e.from];
      final int end = ranks[e.to];
      int labelRank = (start + end) ~/ 2;
      if (labelRank.isEven) labelRank++;
      final String? label = e.edge.label;
      _Vertex previous = vertices[e.from];
      for (int r = start + 1; r < end; r++) {
        final bool labelled = label != null && r == labelRank;
        final Size size = labelled ? labelSize(label) : Size.zero;
        final _Vertex dummy = _Vertex(
          labelled ? crossOf(size) : 0,
          labelled ? mainOf(size) : 0,
          labelled: labelled,
        )..rank = r;
        all.add(dummy);
        e.chain.add(dummy);
        if (r == labelRank) e.labelVertex = dummy;
        previous.downs.add(dummy);
        dummy.ups.add(previous);
        previous = dummy;
      }
      e.chain.first.upPort = e.fromPort;
      e.chain.last.downPort = e.toPort;
      previous.downs.add(vertices[e.to]);
      vertices[e.to].ups.add(previous);
    }

    final List<List<_Vertex>> layers = _order(all, vertices);
    _placeCross(layers);

    // Main axis: each rank is as thick as its thickest member.
    final List<double> mainCenter = List<double>.filled(layers.length, 0);
    double cursor = 0;
    for (int r = 0; r < layers.length; r++) {
      double thickness = 0;
      for (final _Vertex v in layers[r]) {
        thickness = math.max(thickness, v.main);
      }
      if (r > 0) cursor += metrics.rankGap;
      mainCenter[r] = cursor + thickness / 2;
      cursor += thickness;
    }
    final double mainExtent = cursor;
    double minCross = double.infinity;
    double maxCross = double.negativeInfinity;
    for (final _Vertex v in all) {
      minCross = math.min(minCross, v.x - v.cross / 2);
      maxCross = math.max(maxCross, v.x + v.cross / 2);
    }
    // Self loops bulge past their node on the cross axis.
    for (final FlowEdge loop in selfLoops) {
      final _Vertex v = vertices[itemFor(graph.nodes[loop.from]!)];
      maxCross = math.max(
        maxCross,
        v.x + v.cross / 2 + metrics.loopSize + _loopLabelExtent(loop, vertical),
      );
    }
    final double crossExtent = maxCross - minCross;

    Offset point(double cross, double main) {
      final double c = cross - minCross;
      switch (direction) {
        case FlowDirection.topDown:
          return Offset(c, main);
        case FlowDirection.bottomUp:
          return Offset(c, mainExtent - main);
        case FlowDirection.leftRight:
          return Offset(main, c);
        case FlowDirection.rightLeft:
          return Offset(mainExtent - main, c);
      }
    }

    Offset centerOf(_Vertex v) => point(v.x, mainCenter[v.rank]);

    final _Block block = _Block(
      vertical ? Size(crossExtent, mainExtent) : Size(mainExtent, crossExtent),
    );
    for (int i = 0; i < items.length; i++) {
      final Rect rect = Rect.fromCenter(
        center: centerOf(vertices[i]),
        width: sizes[i].width,
        height: sizes[i].height,
      );
      final Object item = items[i];
      if (item is FlowNode) {
        block.nodes[item] = rect;
      } else {
        block.addShifted(blocks[item as FlowSubgraph]!, rect.topLeft);
      }
    }
    for (final _LevelEdge e in edges) {
      final List<Offset> waypoints = <Offset>[
        for (final _Vertex v in e.chain) centerOf(v),
      ];
      block.routes.add(
        _Route(
          e.edge,
          e.reversed ? waypoints.reversed.toList() : waypoints,
          vertical,
          e.labelVertex == null ? null : centerOf(e.labelVertex!),
          false,
        ),
      );
    }
    for (final FlowEdge loop in selfLoops) {
      block.routes.add(_Route(loop, const <Offset>[], vertical, null, true));
    }
    return block;
  }

  double _loopLabelExtent(FlowEdge loop, bool vertical) {
    final String? label = loop.label;
    if (label == null) return 0;
    final Size size = labelSize(label);
    return 4 + (vertical ? size.width : size.height);
  }

  int _depthOf(FlowSubgraph subgraph) {
    int depth = 0;
    for (FlowSubgraph? s = subgraph; s != null; s = s.parent) {
      depth++;
    }
    return depth;
  }

  /// Wraps a subgraph's content with padding and a title strip on top.
  _Block _framed(FlowSubgraph subgraph, _Block content) {
    final Size title = titleSize(subgraph);
    final double pad = metrics.subgraphPadding;
    final double width = math.max(
      content.size.width + pad * 2,
      title.width + pad * 2,
    );
    final double titleBand = title.height > 0 ? title.height + 6 : 0;
    final Size size = Size(width, content.size.height + pad * 2 + titleBand);
    final _Block framed = _Block(size);
    framed.subgraphs.add((subgraph, Offset.zero & size));
    framed.addShifted(
      content,
      Offset((width - content.size.width) / 2, pad + titleBand),
    );
    return framed;
  }

  /// Reverses DFS back edges so every level is acyclic.
  void _breakCycles(int count, List<_LevelEdge> edges, List<int> firstMention) {
    final List<List<_LevelEdge>> out = List<List<_LevelEdge>>.generate(
      count,
      (_) => <_LevelEdge>[],
    );
    for (final _LevelEdge e in edges) {
      out[e.from].add(e);
    }
    // 0 = unvisited, 1 = on stack, 2 = done.
    final List<int> state = List<int>.filled(count, 0);
    void visit(int v) {
      state[v] = 1;
      for (final _LevelEdge e in out[v]) {
        if (state[e.to] == 1) {
          e.reversed = true;
        } else if (state[e.to] == 0) {
          visit(e.to);
        }
      }
      state[v] = 2;
    }

    final List<bool> hasIncoming = List<bool>.filled(count, false);
    for (final _LevelEdge e in edges) {
      hasIncoming[e.to] = true;
    }
    final List<int> starts = List<int>.generate(count, (int v) => v)
      ..sort((int a, int b) {
        if (hasIncoming[a] != hasIncoming[b]) return hasIncoming[a] ? 1 : -1;
        return firstMention[a].compareTo(firstMention[b]);
      });
    for (final int v in starts) {
      if (state[v] == 0) visit(v);
    }
    for (final _LevelEdge e in edges) {
      if (e.reversed) {
        final int from = e.from;
        e.from = e.to;
        e.to = from;
        final double fromPort = e.fromPort;
        e.fromPort = e.toPort;
        e.toPort = fromPort;
      }
    }
  }

  /// Longest-path ranks, with sources pulled down next to their successors.
  List<int> _rank(int count, List<_LevelEdge> edges) {
    final List<int> ranks = List<int>.filled(count, 0);
    final List<int> indegree = List<int>.filled(count, 0);
    final List<List<int>> out = List<List<int>>.generate(count, (_) => <int>[]);
    for (final _LevelEdge e in edges) {
      indegree[e.to]++;
      out[e.from].add(e.to);
    }
    final List<int> sources = <int>[
      for (int v = 0; v < count; v++)
        if (indegree[v] == 0) v,
    ];
    final List<int> queue = List<int>.of(sources);
    final List<int> remaining = List<int>.of(indegree);
    for (int i = 0; i < queue.length; i++) {
      final int v = queue[i];
      for (final int w in out[v]) {
        ranks[w] = math.max(ranks[w], ranks[v] + 2);
        if (--remaining[w] == 0) queue.add(w);
      }
    }
    for (final int v in sources) {
      if (out[v].isEmpty) continue;
      int nearest = ranks[out[v].first];
      for (final int w in out[v]) {
        nearest = math.min(nearest, ranks[w]);
      }
      ranks[v] = nearest - 2;
    }
    final int lowest = ranks.reduce(math.min);
    return <int>[for (final int r in ranks) r - lowest];
  }

  /// Orders each layer by barycenter sweeps; keeps the fewest crossings.
  List<List<_Vertex>> _order(List<_Vertex> all, List<_Vertex> items) {
    int maxRank = 0;
    for (final _Vertex v in all) {
      maxRank = math.max(maxRank, v.rank);
    }
    final List<List<_Vertex>> layers = List<List<_Vertex>>.generate(
      maxRank + 1,
      (_) => <_Vertex>[],
    );
    // DFS from sources in declaration order gives a stable starting point.
    final Set<_Vertex> seen = <_Vertex>{};
    void visit(_Vertex v) {
      if (!seen.add(v)) return;
      layers[v.rank].add(v);
      for (final _Vertex w in v.downs) {
        visit(w);
      }
    }

    for (final _Vertex v in items) {
      if (v.ups.isEmpty) visit(v);
    }
    for (final _Vertex v in all) {
      visit(v);
    }
    void number() {
      for (final List<_Vertex> layer in layers) {
        for (int i = 0; i < layer.length; i++) {
          layer[i].order = i;
        }
      }
    }

    number();
    List<List<_Vertex>> best = <List<_Vertex>>[
      for (final List<_Vertex> layer in layers) List<_Vertex>.of(layer),
    ];
    int bestCrossings = _crossings(layers);
    for (int iteration = 0; iteration < 12 && bestCrossings > 0; iteration++) {
      final bool down = iteration.isEven;
      final int start = down ? 1 : layers.length - 2;
      final int step = down ? 1 : -1;
      for (int r = start; r >= 0 && r < layers.length; r += step) {
        final List<_Vertex> layer = layers[r];
        final Map<_Vertex, double> bary = <_Vertex, double>{};
        for (final _Vertex v in layer) {
          final List<_Vertex> neighbors = down ? v.ups : v.downs;
          if (neighbors.isEmpty) {
            bary[v] = v.order.toDouble();
          } else {
            double sum = 0;
            for (final _Vertex n in neighbors) {
              sum += v.orderFrom(n, down);
            }
            bary[v] = sum / neighbors.length;
          }
        }
        // List.sort is not stable; break ties by current order.
        layer.sort((_Vertex a, _Vertex b) {
          final int byBary = bary[a]!.compareTo(bary[b]!);
          return byBary != 0 ? byBary : a.order.compareTo(b.order);
        });
        for (int i = 0; i < layer.length; i++) {
          layer[i].order = i;
        }
      }
      final int crossings = _crossings(layers);
      if (crossings < bestCrossings) {
        bestCrossings = crossings;
        best = <List<_Vertex>>[
          for (final List<_Vertex> layer in layers) List<_Vertex>.of(layer),
        ];
      }
    }
    for (int r = 0; r < layers.length; r++) {
      layers[r] = best[r];
    }
    number();
    return layers;
  }

  int _crossings(List<List<_Vertex>> layers) {
    int total = 0;
    for (int r = 0; r + 1 < layers.length; r++) {
      final List<(double, double)> pairs = <(double, double)>[
        for (final _Vertex u in layers[r])
          for (final _Vertex w in u.downs)
            (w.orderFrom(u, true), u.orderFrom(w, false)),
      ];
      pairs.sort(((double, double) a, (double, double) b) {
        final int first = a.$2.compareTo(b.$2);
        return first != 0 ? first : a.$1.compareTo(b.$1);
      });
      total += _inversions(<double>[
        for (final (double, double) p in pairs) p.$1,
      ]);
    }
    return total;
  }

  /// Cross-axis centers: repeated least-squares pulls toward neighbors.
  void _placeCross(List<List<_Vertex>> layers) {
    for (final List<_Vertex> layer in layers) {
      double cursor = 0;
      for (int i = 0; i < layer.length; i++) {
        if (i > 0) cursor += _gap(layer[i - 1], layer[i]);
        layer[i].x = cursor + layer[i].cross / 2;
        cursor += layer[i].cross;
      }
      // Center every layer on a common axis before refining.
      final double shift = -cursor / 2;
      for (final _Vertex v in layer) {
        v.x += shift;
      }
    }
    void sweep(int r, bool useUps, bool useDowns) {
      final List<_Vertex> layer = layers[r];
      final List<double> desired = <double>[];
      for (final _Vertex v in layer) {
        double sum = 0;
        int count = 0;
        if (useUps) {
          for (final _Vertex n in v.ups) {
            sum += v.targetFrom(n, true);
            count++;
          }
        }
        if (useDowns) {
          for (final _Vertex n in v.downs) {
            sum += v.targetFrom(n, false);
            count++;
          }
        }
        desired.add(count == 0 ? v.x : sum / count);
      }
      final List<double> placed = _fit(layer, desired);
      for (int i = 0; i < layer.length; i++) {
        layer[i].x = placed[i];
      }
    }

    for (int pass = 0; pass < 8; pass++) {
      for (int r = 1; r < layers.length; r++) {
        sweep(r, true, false);
      }
      for (int r = layers.length - 2; r >= 0; r--) {
        sweep(r, false, true);
      }
    }
    for (int pass = 0; pass < 2; pass++) {
      for (int r = 0; r < layers.length; r++) {
        sweep(r, true, true);
      }
    }
  }

  double _gap(_Vertex a, _Vertex b) {
    if (!a.dummy && !b.dummy) return metrics.nodeGap;
    if (a.labelled || b.labelled) return metrics.dummyGap + 4;
    return metrics.dummyGap;
  }

  /// Closest positions to [desired] (least squares) that keep [layer]'s
  /// order and minimum spacing: isotonic regression on offset targets.
  List<double> _fit(List<_Vertex> layer, List<double> desired) {
    final int n = layer.length;
    final List<double> offsets = List<double>.filled(n, 0);
    for (int i = 1; i < n; i++) {
      offsets[i] =
          offsets[i - 1] +
          (layer[i - 1].cross + layer[i].cross) / 2 +
          _gap(layer[i - 1], layer[i]);
    }
    final List<double> sums = <double>[];
    final List<int> counts = <int>[];
    for (int i = 0; i < n; i++) {
      sums.add(desired[i] - offsets[i]);
      counts.add(1);
      while (sums.length > 1 &&
          sums[sums.length - 2] / counts[counts.length - 2] >
              sums.last / counts.last) {
        final double sum = sums.removeLast();
        final int count = counts.removeLast();
        sums[sums.length - 1] += sum;
        counts[counts.length - 1] += count;
      }
    }
    final List<double> result = <double>[];
    for (int b = 0; b < sums.length; b++) {
      final double mean = sums[b] / counts[b];
      for (int k = 0; k < counts[b]; k++) {
        result.add(mean + offsets[result.length]);
      }
    }
    return result;
  }

  /// Joins a route to the real node boxes at its ends.
  LaidOutEdge _attach(_Route route, Map<FlowNode, Rect> rects) {
    final Rect from = rects[graph.nodes[route.edge.from]!]!;
    final Rect to = rects[graph.nodes[route.edge.to]!]!;
    if (route.selfLoop) {
      return LaidOutEdge(
        edge: route.edge,
        points: <Offset>[from.topLeft, from.bottomRight],
        vertical: route.vertical,
        labelCenter: null,
        selfLoop: true,
      );
    }
    final Offset next = route.waypoints.isEmpty
        ? to.center
        : route.waypoints.first;
    final Offset previous = route.waypoints.isEmpty
        ? from.center
        : route.waypoints.last;
    return LaidOutEdge(
      edge: route.edge,
      points: <Offset>[
        _port(from, next, route.vertical),
        ...route.waypoints,
        _port(to, previous, route.vertical),
      ],
      vertical: route.vertical,
      labelCenter: route.label,
    );
  }

  /// Middle of the side of [rect] that faces [toward] along the main axis.
  Offset _port(Rect rect, Offset toward, bool vertical) {
    if (vertical) {
      return toward.dy >= rect.center.dy ? rect.bottomCenter : rect.topCenter;
    }
    return toward.dx >= rect.center.dx ? rect.centerRight : rect.centerLeft;
  }
}

/// Number of inversions in [values], by merge sort.
int _inversions(List<double> values) {
  if (values.length < 2) return 0;
  final List<double> buffer = List<double>.filled(values.length, 0);
  int sort(int lo, int hi) {
    if (hi - lo < 2) return 0;
    final int mid = (lo + hi) ~/ 2;
    int count = sort(lo, mid) + sort(mid, hi);
    int i = lo;
    int j = mid;
    int k = lo;
    while (i < mid && j < hi) {
      if (values[j] < values[i]) {
        count += mid - i;
        buffer[k++] = values[j++];
      } else {
        buffer[k++] = values[i++];
      }
    }
    while (i < mid) {
      buffer[k++] = values[i++];
    }
    while (j < hi) {
      buffer[k++] = values[j++];
    }
    for (int m = lo; m < hi; m++) {
      values[m] = buffer[m];
    }
    return count;
  }

  return sort(0, values.length);
}
