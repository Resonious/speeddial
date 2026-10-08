import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/ui/chat/mermaid/mermaid_layout.dart';
import 'package:speeddial_app/src/ui/chat/mermaid/mermaid_parser.dart';

FlowGraph _parse(String source) {
  final FlowGraph? graph = parseMermaidFlowchart(source);
  expect(graph, isNotNull, reason: source);
  return graph!;
}

FlowLayout _layout(FlowGraph graph) => layoutFlowchart(
  graph,
  nodeSize: (FlowNode node) => Size(node.label.length * 7.0 + 24, 32),
  labelSize: (String label) => Size(label.length * 6.0 + 8, 16),
  titleSize: (FlowSubgraph subgraph) =>
      Size(subgraph.title.length * 7.0, subgraph.title.isEmpty ? 0 : 16),
);

void main() {
  group('parseMermaidFlowchart', () {
    test('parses the chain agents typically emit', () {
      final FlowGraph graph = _parse('''
flowchart LR
    A["MySQL: tenant stats, logs<br/>and selected business tables"]
    B["ClickPipes CDC"]
    C["ClickHouse: replicated source tables"]
    A --> B --> C
''');
      expect(graph.direction, FlowDirection.leftRight);
      expect(graph.nodes.keys, <String>['A', 'B', 'C']);
      expect(
        graph.nodes['A']!.label,
        'MySQL: tenant stats, logs\nand selected business tables',
      );
      expect(graph.edges.map((FlowEdge e) => '${e.from}>${e.to}'), <String>[
        'A>B',
        'B>C',
      ]);
    });

    test('reads shapes, edge styles, heads and labels', () {
      final FlowGraph graph = _parse('''
graph TD
  a([stadium]) -->|yes| b{choice}
  b -- no --> c[(db)]
  c -.-> d((circle))
  d ==> e{{hex}}
  e --- f[/para/]
  f -. maybe .-> g>flag]
  g <--> h[[sub]]
  h --o i(round)
  i --x j[\\alt\\]
  j == strong ==> k[/trap\\]
  k ~~~ a
''');
      NodeShape shape(String id) => graph.nodes[id]!.shape;
      expect(shape('a'), NodeShape.stadium);
      expect(shape('b'), NodeShape.rhombus);
      expect(shape('c'), NodeShape.cylinder);
      expect(shape('d'), NodeShape.circle);
      expect(shape('e'), NodeShape.hexagon);
      expect(shape('f'), NodeShape.parallelogram);
      expect(shape('g'), NodeShape.asymmetric);
      expect(shape('h'), NodeShape.subroutine);
      expect(shape('i'), NodeShape.round);
      expect(shape('j'), NodeShape.parallelogramAlt);
      expect(shape('k'), NodeShape.trapezoid);

      final List<FlowEdge> edges = graph.edges;
      expect(edges.map((FlowEdge e) => e.label), <String?>[
        'yes',
        'no',
        null,
        null,
        null,
        'maybe',
        null,
        null,
        null,
        'strong',
        null,
      ]);
      expect(edges[2].stroke, EdgeStroke.dotted);
      expect(edges[3].stroke, EdgeStroke.thick);
      expect(edges[4].endHead, EdgeHead.none);
      expect(edges[5].stroke, EdgeStroke.dotted);
      expect(edges[6].startHead, EdgeHead.arrow);
      expect(edges[6].endHead, EdgeHead.arrow);
      expect(edges[7].endHead, EdgeHead.circle);
      expect(edges[8].endHead, EdgeHead.cross);
      expect(edges[9].stroke, EdgeStroke.thick);
      expect(edges[10].stroke, EdgeStroke.invisible);
    });

    test('expands & groups and ignores styling statements', () {
      final FlowGraph graph = _parse('''
flowchart TB
  %% comment
  A & B --> C:::hot & D; D --> other
  classDef hot fill:#f00
  style A fill:#0f0
  click A "https://example.com"
''');
      expect(graph.edges.map((FlowEdge e) => '${e.from}>${e.to}'), <String>[
        'A>C',
        'A>D',
        'B>C',
        'B>D',
        'D>other',
      ]);
    });

    test('a node starting with o or x is not an edge head', () {
      final FlowGraph graph = _parse('graph LR\n  A --- other --> xray');
      expect(graph.nodes.keys, <String>['A', 'other', 'xray']);
      expect(graph.edges.first.endHead, EdgeHead.none);
    });

    test('tracks nested subgraph membership and titles', () {
      final FlowGraph graph = _parse('''
flowchart LR
  subgraph outer [Outer box]
    direction TB
    a --> b
    subgraph inner["Inner #quot;box#quot;"]
      c
    end
  end
  b --> c --> d
''');
      final FlowSubgraph outer = graph.subgraphs[0];
      final FlowSubgraph inner = graph.subgraphs[1];
      expect(outer.title, 'Outer box');
      expect(outer.direction, FlowDirection.topDown);
      expect(inner.title, 'Inner "box"');
      expect(inner.parent, outer);
      expect(graph.nodes['a']!.parent, outer);
      expect(graph.nodes['c']!.parent, inner);
      expect(graph.nodes['d']!.parent, isNull);
    });

    test('returns null for anything outside the subset', () {
      for (final String source in <String>[
        'sequenceDiagram\n  A->>B: hi',
        'flowchart LR\n  A --> B\n  subgraph S\n  C',
        'flowchart LR\n  end',
        'flowchart LR\n  A --> S\n  subgraph S\n    B\n  end',
        'flowchart LR\n  A@{ shape: rect }',
        'flowchart LR\n  A ->> B',
        '',
      ]) {
        expect(parseMermaidFlowchart(source), isNull, reason: source);
      }
    });

    test('recognizes untagged flowchart fences', () {
      expect(looksLikeMermaidFlowchart('%% hi\nflowchart LR\nA-->B'), isTrue);
      expect(looksLikeMermaidFlowchart('graph TD;'), isTrue);
      expect(looksLikeMermaidFlowchart('graph = build()'), isFalse);
    });

    test('cleans label markup', () {
      expect(
        cleanMermaidLabel('<b>bold</b><br>**next** &amp; #35;'),
        'bold\nnext & #',
      );
    });
  });

  group('layoutFlowchart', () {
    void expectNoOverlaps(FlowLayout layout) {
      for (int i = 0; i < layout.nodes.length; i++) {
        for (int j = i + 1; j < layout.nodes.length; j++) {
          final Rect a = layout.nodes[i].rect;
          final Rect b = layout.nodes[j].rect;
          expect(
            a.overlaps(b),
            isFalse,
            reason:
                '${layout.nodes[i].node.id} overlaps ${layout.nodes[j].node.id}',
          );
        }
      }
      final Rect bounds = Offset.zero & layout.size;
      for (final LaidOutNode node in layout.nodes) {
        expect(bounds.inflate(0.01).contains(node.rect.topLeft), isTrue);
        expect(bounds.inflate(0.01).contains(node.rect.bottomRight), isTrue);
      }
    }

    test('edges flow along the main axis for every direction', () {
      for (final (String dir, Offset axis) in <(String, Offset)>[
        ('TD', const Offset(0, 1)),
        ('BT', const Offset(0, -1)),
        ('LR', const Offset(1, 0)),
        ('RL', const Offset(-1, 0)),
      ]) {
        final FlowLayout layout = _layout(
          _parse(
            'flowchart $dir\n  A --> B --> C\n  A --> C\n  B -->|label| D',
          ),
        );
        expectNoOverlaps(layout);
        Offset center(String id) => layout.nodes
            .firstWhere((LaidOutNode n) => n.node.id == id)
            .rect
            .center;
        double along(Offset p) => p.dx * axis.dx + p.dy * axis.dy;
        expect(
          along(center('B')),
          greaterThan(along(center('A'))),
          reason: dir,
        );
        expect(
          along(center('C')),
          greaterThan(along(center('B'))),
          reason: dir,
        );
        for (final LaidOutEdge edge in layout.edges) {
          expect(edge.points.length, greaterThanOrEqualTo(3));
        }
        final LaidOutEdge labelled = layout.edges.firstWhere(
          (LaidOutEdge e) => e.edge.label == 'label',
        );
        expect(labelled.labelCenter, isNotNull);
      }
    });

    test('cycles keep their direction and a stable layout', () {
      final FlowLayout layout = _layout(
        _parse('graph TD\n  A --> B --> C --> A\n  C --> C'),
      );
      expectNoOverlaps(layout);
      final LaidOutEdge back = layout.edges.firstWhere(
        (LaidOutEdge e) => e.edge.from == 'C' && e.edge.to == 'A',
      );
      final Rect a = layout.nodes.first.rect;
      // The reversed edge still ends on A.
      expect(
        back.points.last == a.topCenter || back.points.last == a.bottomCenter,
        isTrue,
      );
      expect(layout.edges.where((LaidOutEdge e) => e.selfLoop).length, 1);
    });

    test('subgraph frames contain their nodes and never overlap', () {
      final FlowLayout layout = _layout(
        _parse('''
flowchart TB
  start --> a1
  subgraph one [First]
    a1 --> a2
  end
  subgraph two [Second]
    b1 --> b2
    subgraph three [Nested]
      c1
    end
  end
  a2 --> b1
  b2 --> c1
  start --> b1
'''),
      );
      expectNoOverlaps(layout);
      Rect frame(String id) => layout.subgraphs
          .firstWhere((LaidOutSubgraph s) => s.subgraph.id == id)
          .rect;
      for (final LaidOutNode node in layout.nodes) {
        final FlowSubgraph? parent = node.node.parent;
        if (parent == null) continue;
        expect(frame(parent.id).contains(node.rect.center), isTrue);
      }
      expect(frame('one').overlaps(frame('two')), isFalse);
      expect(frame('two').expandToInclude(frame('three')), frame('two'));
      // Outer frames are listed before the frames nested in them.
      expect(
        layout.subgraphs.indexWhere(
          (LaidOutSubgraph s) => s.subgraph.id == 'two',
        ),
        lessThan(
          layout.subgraphs.indexWhere(
            (LaidOutSubgraph s) => s.subgraph.id == 'three',
          ),
        ),
      );
    });

    test('a graph that is all cycle starts where the source starts', () {
      final FlowLayout layout = _layout(
        _parse('''
flowchart LR
  subgraph ingest
    api --> queue
  end
  queue --> parse --> enrich
  enrich --> dlq
  dlq --> queue
'''),
      );
      expectNoOverlaps(layout);
      double x(String id) => layout.nodes
          .firstWhere((LaidOutNode n) => n.node.id == id)
          .rect
          .center
          .dx;
      expect(x('api'), lessThan(x('queue')));
      expect(x('queue'), lessThan(x('parse')));
      expect(x('enrich'), lessThan(x('dlq')));
    });

    test('a wide fan-out keeps siblings apart', () {
      final StringBuffer source = StringBuffer('graph TD\n');
      for (int i = 0; i < 12; i++) {
        source.writeln('  root --> n$i --> sink');
      }
      expectNoOverlaps(_layout(_parse(source.toString())));
    });
  });
}
