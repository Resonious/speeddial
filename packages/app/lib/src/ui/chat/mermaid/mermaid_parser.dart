/// Parser for the subset of Mermaid flowchart syntax agents commonly emit.
///
/// [parseMermaidFlowchart] returns null for anything outside the subset
/// (other diagram types, unknown statements, edges to subgraphs, ...) so the
/// caller can fall back to showing the source as a plain code block. A
/// partial diagram that silently drops statements would be misleading.
library;

/// Layout direction: the axis edges flow along.
enum FlowDirection { topDown, bottomUp, leftRight, rightLeft }

enum NodeShape {
  rect,
  round,
  stadium,
  subroutine,
  cylinder,
  circle,
  doubleCircle,
  asymmetric,
  rhombus,
  hexagon,
  parallelogram,
  parallelogramAlt,
  trapezoid,
  trapezoidAlt,
}

enum EdgeStroke { solid, dotted, thick, invisible }

enum EdgeHead { none, arrow, circle, cross }

class FlowNode {
  FlowNode(this.id, this.label);

  final String id;
  String label;
  NodeShape shape = NodeShape.rect;

  /// Innermost subgraph containing the node; null at the top level.
  FlowSubgraph? parent;
}

class FlowEdge {
  const FlowEdge({
    required this.from,
    required this.to,
    required this.stroke,
    required this.startHead,
    required this.endHead,
    this.label,
  });

  final String from;
  final String to;
  final EdgeStroke stroke;
  final EdgeHead startHead;
  final EdgeHead endHead;
  final String? label;
}

class FlowSubgraph {
  FlowSubgraph(this.id, this.title, this.parent);

  final String id;
  final String title;
  final FlowSubgraph? parent;

  /// Set by a `direction` statement inside the subgraph.
  FlowDirection? direction;
}

class FlowGraph {
  FlowGraph(this.direction);

  final FlowDirection direction;

  /// Declaration order is preserved; layout uses it for stable output.
  final Map<String, FlowNode> nodes = <String, FlowNode>{};
  final List<FlowEdge> edges = <FlowEdge>[];
  final List<FlowSubgraph> subgraphs = <FlowSubgraph>[];
}

/// Upper bounds that keep parsing and layout comfortably sub-frame.
const int maxMermaidSourceLength = 20000;
const int maxMermaidNodes = 250;
const int maxMermaidEdges = 500;

final RegExp _header = RegExp(
  r'^(?:flowchart|graph)(?:\s+(TB|TD|BT|LR|RL))?\s*;?\s*$',
  caseSensitive: false,
);

/// Whether [source] starts like a flowchart, for fences without an info
/// string. Comment lines (`%%`) before the header are allowed.
bool looksLikeMermaidFlowchart(String source) {
  for (final String line in source.split('\n')) {
    final String trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('%%')) continue;
    return _header.hasMatch(trimmed);
  }
  return false;
}

FlowGraph? parseMermaidFlowchart(String source) {
  if (source.length > maxMermaidSourceLength) return null;
  final List<String> lines = source
      .replaceAll('\r\n', '\n')
      .split('\n')
      .map((String line) => line.trim())
      .where((String line) => line.isNotEmpty && !line.startsWith('%%'))
      .toList();
  if (lines.isEmpty) return null;
  final RegExpMatch? header = _header.firstMatch(lines.first);
  if (header == null) return null;
  final _Parser parser = _Parser(
    FlowGraph(_direction(header.group(1)) ?? FlowDirection.topDown),
  );
  for (final String line in lines.skip(1)) {
    for (final String statement in _splitStatements(line)) {
      if (!parser.statement(statement)) return null;
    }
  }
  return parser.finish();
}

FlowDirection? _direction(String? token) {
  switch (token?.toUpperCase()) {
    case 'TB':
    case 'TD':
      return FlowDirection.topDown;
    case 'BT':
      return FlowDirection.bottomUp;
    case 'LR':
      return FlowDirection.leftRight;
    case 'RL':
      return FlowDirection.rightLeft;
  }
  return null;
}

/// Splits on `;` outside quotes and bracketed labels.
List<String> _splitStatements(String line) {
  final List<String> out = <String>[];
  int depth = 0;
  bool quoted = false;
  int start = 0;
  for (int i = 0; i < line.length; i++) {
    final String c = line[i];
    if (c == '"') {
      quoted = !quoted;
    } else if (!quoted && '[({'.contains(c)) {
      depth++;
    } else if (!quoted && '])}'.contains(c) && depth > 0) {
      depth--;
    } else if (!quoted && depth == 0 && c == ';') {
      out.add(line.substring(start, i));
      start = i + 1;
    }
  }
  out.add(line.substring(start));
  return <String>[
    for (final String s in out)
      if (s.trim().isNotEmpty) s.trim(),
  ];
}

const List<(String, String, NodeShape)> _shapes = <(String, String, NodeShape)>[
  ('(((', ')))', NodeShape.doubleCircle),
  ('([', '])', NodeShape.stadium),
  ('[[', ']]', NodeShape.subroutine),
  ('[(', ')]', NodeShape.cylinder),
  ('((', '))', NodeShape.circle),
  ('{{', '}}', NodeShape.hexagon),
  ('[/', '/]', NodeShape.parallelogram),
  ('[/', r'\]', NodeShape.trapezoid),
  (r'[\', r'\]', NodeShape.parallelogramAlt),
  (r'[\', '/]', NodeShape.trapezoidAlt),
  ('[', ']', NodeShape.rect),
  ('(', ')', NodeShape.round),
  ('{', '}', NodeShape.rhombus),
  ('>', ']', NodeShape.asymmetric),
];

final RegExp _id = RegExp(
  r'[\p{L}\p{N}_]+(?:[-.][\p{L}\p{N}_]+)*',
  unicode: true,
);
final RegExp _classSuffix = RegExp(r':::[\w-]+');
final RegExp _ignored = RegExp(
  r'^(classDef|class|style|linkStyle|click|accTitle|accDescr)\b',
);
final RegExp _subgraph = RegExp(r'^subgraph(?:\s+(.*))?$');
final RegExp _directionStatement = RegExp(
  r'^direction\s+(TB|TD|BT|LR|RL)$',
  caseSensitive: false,
);

// Edge operators. Labelled forms are tried first so `-- text -->` is not read
// as a bare `--` link followed by a node called `text`. A trailing `o`/`x`
// only counts as a head when not followed by an identifier character.
const String _endHead = r'(>|[ox](?![\p{L}\p{N}_]))?';
final List<(RegExp, EdgeStroke)> _labelledEdges = <(RegExp, EdgeStroke)>[
  (
    RegExp(
      r'(<|[ox])?--(?![->]|[ox](?![\p{L}\p{N}_]))\s*(.+?)\s*-{2,}' + _endHead,
      unicode: true,
    ),
    EdgeStroke.solid,
  ),
  (
    RegExp(r'(<|[ox])?-\.(?![.-])\s*(.+?)\s*\.+-' + _endHead, unicode: true),
    EdgeStroke.dotted,
  ),
  (
    RegExp(r'(<|[ox])?==(?![=>])\s*(.+?)\s*={2,}' + _endHead, unicode: true),
    EdgeStroke.thick,
  ),
];
final List<(RegExp, EdgeStroke)> _plainEdges = <(RegExp, EdgeStroke)>[
  (RegExp(r'(<|[ox])?-{2,}' + _endHead, unicode: true), EdgeStroke.solid),
  (RegExp(r'(<|[ox])?-\.+-' + _endHead, unicode: true), EdgeStroke.dotted),
  (RegExp(r'(<|[ox])?={2,}' + _endHead, unicode: true), EdgeStroke.thick),
  (RegExp(r'()~{3,}()'), EdgeStroke.invisible),
];

EdgeHead _head(String? token) {
  switch (token) {
    case '<':
    case '>':
      return EdgeHead.arrow;
    case 'o':
      return EdgeHead.circle;
    case 'x':
      return EdgeHead.cross;
  }
  return EdgeHead.none;
}

class _EdgeOp {
  const _EdgeOp(this.stroke, this.startHead, this.endHead, this.label);

  final EdgeStroke stroke;
  final EdgeHead startHead;
  final EdgeHead endHead;
  final String? label;
}

class _Parser {
  _Parser(this.graph);

  final FlowGraph graph;
  final List<FlowSubgraph> _stack = <FlowSubgraph>[];

  late String _s;
  int _pos = 0;

  FlowGraph? finish() {
    if (_stack.isNotEmpty) return null;
    if (graph.nodes.isEmpty) return null;
    for (final FlowSubgraph subgraph in graph.subgraphs) {
      // Edges to subgraphs need compound routing; leave those to Mermaid.
      if (graph.nodes.containsKey(subgraph.id)) return null;
    }
    return graph;
  }

  bool statement(String text) {
    if (_ignored.hasMatch(text)) return true;
    if (text == 'end') {
      if (_stack.isEmpty) return false;
      _stack.removeLast();
      return true;
    }
    final RegExpMatch? direction = _directionStatement.firstMatch(text);
    if (direction != null) {
      if (_stack.isNotEmpty) _stack.last.direction = _direction(direction[1]);
      return true;
    }
    final RegExpMatch? subgraph = _subgraph.firstMatch(text);
    if (subgraph != null) return _openSubgraph(subgraph.group(1)?.trim());
    return _chain(text);
  }

  bool _openSubgraph(String? spec) {
    String id;
    String title;
    if (spec == null || spec.isEmpty) {
      id = 'subgraph${graph.subgraphs.length}';
      title = '';
    } else {
      final RegExpMatch? bracketed = RegExp(r'^([^\s\[]+)\s*\[(.*)\]$')
          .firstMatch(spec);
      if (bracketed != null) {
        id = bracketed[1]!;
        title = cleanMermaidLabel(_unquote(bracketed[2]!.trim()));
      } else {
        title = cleanMermaidLabel(_unquote(spec));
        id = _unquote(spec);
      }
    }
    final FlowSubgraph created = FlowSubgraph(
      id,
      title,
      _stack.isEmpty ? null : _stack.last,
    );
    graph.subgraphs.add(created);
    _stack.add(created);
    return true;
  }

  bool _chain(String text) {
    _s = text;
    _pos = 0;
    List<String>? left = _nodeGroup();
    if (left == null) return false;
    while (true) {
      _skipSpace();
      if (_pos >= _s.length) return true;
      final _EdgeOp? op = _edge();
      if (op == null) return false;
      final List<String>? right = _nodeGroup();
      if (right == null) return false;
      for (final String from in left!) {
        for (final String to in right) {
          if (graph.edges.length >= maxMermaidEdges) return false;
          graph.edges.add(
            FlowEdge(
              from: from,
              to: to,
              stroke: op.stroke,
              startHead: op.startHead,
              endHead: op.endHead,
              label: op.label,
            ),
          );
        }
      }
      left = right;
    }
  }

  List<String>? _nodeGroup() {
    final List<String> ids = <String>[];
    while (true) {
      _skipSpace();
      final String? id = _node();
      if (id == null) return null;
      ids.add(id);
      _skipSpace();
      if (_pos < _s.length && _s[_pos] == '&') {
        _pos++;
        continue;
      }
      return ids;
    }
  }

  String? _node() {
    final Match? match = _id.matchAsPrefix(_s, _pos);
    if (match == null) return null;
    final String id = match[0]!;
    _pos = match.end;
    String? label;
    NodeShape? shape;
    for (final (String open, String close, NodeShape kind) in _shapes) {
      if (!_s.startsWith(open, _pos)) continue;
      final int textStart = _pos + open.length;
      int closeAt;
      if (textStart < _s.length && _s[textStart] == '"') {
        final int endQuote = _s.indexOf('"', textStart + 1);
        if (endQuote < 0) return null;
        closeAt = endQuote + 1;
        while (closeAt < _s.length && _s[closeAt] == ' ') {
          closeAt++;
        }
        if (!_s.startsWith(close, closeAt)) continue;
      } else {
        closeAt = _s.indexOf(close, textStart);
        if (closeAt < 0) continue;
      }
      label = cleanMermaidLabel(_unquote(_s.substring(textStart, closeAt)));
      shape = kind;
      _pos = closeAt + close.length;
      break;
    }
    if (shape == null && _s.startsWith('@{', _pos)) return null;
    final Match? suffix = _classSuffix.matchAsPrefix(_s, _pos);
    if (suffix != null) _pos = suffix.end;

    FlowNode? node = graph.nodes[id];
    if (node == null) {
      if (graph.nodes.length >= maxMermaidNodes) return null;
      node = FlowNode(id, id);
      graph.nodes[id] = node;
    }
    if (shape != null) {
      node.label = label!;
      node.shape = shape;
    }
    // Mermaid places a node in the subgraph where it is first mentioned
    // inside any subgraph body.
    if (node.parent == null && _stack.isNotEmpty) node.parent = _stack.last;
    return id;
  }

  _EdgeOp? _edge() {
    for (final (RegExp pattern, EdgeStroke stroke) in _labelledEdges) {
      final Match? match = pattern.matchAsPrefix(_s, _pos);
      if (match == null) continue;
      _pos = match.end;
      return _EdgeOp(
        stroke,
        _head(match[1]),
        _head(match[3]),
        cleanMermaidLabel(_unquote(match[2]!)),
      );
    }
    for (final (RegExp pattern, EdgeStroke stroke) in _plainEdges) {
      final Match? match = pattern.matchAsPrefix(_s, _pos);
      if (match == null) continue;
      _pos = match.end;
      _skipSpace();
      String? label;
      if (_pos < _s.length && _s[_pos] == '|') {
        final int close = _s.indexOf('|', _pos + 1);
        if (close < 0) return null;
        label = cleanMermaidLabel(_unquote(_s.substring(_pos + 1, close)));
        _pos = close + 1;
      }
      return _EdgeOp(
        stroke,
        _head(match[1]),
        _head(match[2]),
        label == null || label.isEmpty ? null : label,
      );
    }
    return null;
  }

  void _skipSpace() {
    while (_pos < _s.length && (_s[_pos] == ' ' || _s[_pos] == '\t')) {
      _pos++;
    }
  }
}

String _unquote(String text) {
  final String trimmed = text.trim();
  if (trimmed.length >= 2 && trimmed.startsWith('"') && trimmed.endsWith('"')) {
    return trimmed.substring(1, trimmed.length - 1);
  }
  return trimmed;
}

final RegExp _lineBreak = RegExp(r'<br\s*/?>', caseSensitive: false);
final RegExp _tag = RegExp(r'</?[A-Za-z][^>]*>');
final RegExp _mermaidEntity = RegExp(r'#(\d+|[A-Za-z]+);');
final RegExp _htmlEntity = RegExp(r'&(#\d+|[A-Za-z]+);');
final RegExp _emphasis = RegExp(r'\*\*|__|`');

const Map<String, String> _namedEntities = <String, String>{
  'quot': '"',
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'apos': "'",
  'nbsp': ' ',
};

/// Converts Mermaid label markup to plain text: `<br>` becomes a newline,
/// other HTML tags and markdown emphasis are dropped, entities decoded.
String cleanMermaidLabel(String raw) {
  String text = raw.replaceAll(_lineBreak, '\n').replaceAll(_tag, '');
  String entity(Match match) {
    String name = match[1]!;
    if (name.startsWith('#')) name = name.substring(1);
    final int? code = int.tryParse(name);
    if (code != null && code > 0 && code <= 0x10FFFF) {
      return String.fromCharCode(code);
    }
    return _namedEntities[name] ?? match[0]!;
  }

  text = text
      .replaceAllMapped(_mermaidEntity, entity)
      .replaceAllMapped(_htmlEntity, entity)
      .replaceAll(_emphasis, '');
  return text.split('\n').map((String line) => line.trim()).join('\n').trim();
}
