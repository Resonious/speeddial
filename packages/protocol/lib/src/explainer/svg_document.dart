/// The explainer SVG subset as a flat, validated element tree.
///
/// Parsing resolves the CSS cascade (presentation attributes, then `<style>`
/// rules by specificity, then inline `style`) into typed per-element values.
/// Inheritance is left to renderers so a step that restyles a `<g>` reaches
/// its children.
library;

import 'svg_values.dart';
import 'xml.dart';

enum SvgValueKind {
  paint,
  number,
  opacity,
  length,
  dashArray,
  keyword,
  fontWeight,
  string,
  marker,
  transform,
  points,
  path,
}

/// Every attribute the subset understands, by wire name. [inherited]
/// attributes flow from ancestors at render time; [presentation] ones may
/// also be set from CSS.
enum SvgAttr {
  fill('fill', SvgValueKind.paint, inherited: true),
  fillOpacity('fill-opacity', SvgValueKind.opacity, inherited: true),
  stroke('stroke', SvgValueKind.paint, inherited: true),
  strokeOpacity('stroke-opacity', SvgValueKind.opacity, inherited: true),
  strokeWidth('stroke-width', SvgValueKind.length, inherited: true),
  strokeDasharray('stroke-dasharray', SvgValueKind.dashArray, inherited: true),
  strokeLinecap(
    'stroke-linecap',
    SvgValueKind.keyword,
    inherited: true,
    keywords: <String>['butt', 'round', 'square'],
  ),
  strokeLinejoin(
    'stroke-linejoin',
    SvgValueKind.keyword,
    inherited: true,
    keywords: <String>['miter', 'round', 'bevel'],
  ),
  fontSize('font-size', SvgValueKind.length, inherited: true),
  fontWeight('font-weight', SvgValueKind.fontWeight, inherited: true),
  fontFamily('font-family', SvgValueKind.string, inherited: true),
  fontStyle(
    'font-style',
    SvgValueKind.keyword,
    inherited: true,
    keywords: <String>['normal', 'italic', 'oblique'],
  ),
  textAnchor(
    'text-anchor',
    SvgValueKind.keyword,
    inherited: true,
    keywords: <String>['start', 'middle', 'end'],
  ),
  dominantBaseline(
    'dominant-baseline',
    SvgValueKind.keyword,
    inherited: true,
    keywords: <String>[
      'auto',
      'alphabetic',
      'middle',
      'central',
      'hanging',
      'text-top',
      'text-bottom',
      'text-before-edge',
      'text-after-edge',
      'ideographic',
      'mathematical',
    ],
  ),
  markerStart('marker-start', SvgValueKind.marker, inherited: true),
  markerEnd('marker-end', SvgValueKind.marker, inherited: true),
  visibility(
    'visibility',
    SvgValueKind.keyword,
    inherited: true,
    keywords: <String>['visible', 'hidden', 'collapse'],
  ),
  opacity('opacity', SvgValueKind.opacity),
  display(
    'display',
    SvgValueKind.keyword,
    keywords: <String>['inline', 'block', 'inline-block', 'none'],
  ),
  transform('transform', SvgValueKind.transform, presentation: false),
  x('x', SvgValueKind.length, presentation: false),
  y('y', SvgValueKind.length, presentation: false),
  dx('dx', SvgValueKind.length, presentation: false),
  dy('dy', SvgValueKind.length, presentation: false),
  width('width', SvgValueKind.length, presentation: false),
  height('height', SvgValueKind.length, presentation: false),
  rx('rx', SvgValueKind.length, presentation: false),
  ry('ry', SvgValueKind.length, presentation: false),
  cx('cx', SvgValueKind.length, presentation: false),
  cy('cy', SvgValueKind.length, presentation: false),
  r('r', SvgValueKind.length, presentation: false),
  x1('x1', SvgValueKind.length, presentation: false),
  y1('y1', SvgValueKind.length, presentation: false),
  x2('x2', SvgValueKind.length, presentation: false),
  y2('y2', SvgValueKind.length, presentation: false),
  points('points', SvgValueKind.points, presentation: false),
  d('d', SvgValueKind.path, presentation: false),

  /// Replaces a `<text>`/`<tspan>` element's content. Only steps and toggles
  /// set it; in markup, content is the element's character data.
  text('text', SvgValueKind.string, presentation: false);

  const SvgAttr(
    this.wire,
    this.kind, {
    this.inherited = false,
    this.presentation = true,
    this.keywords = const <String>[],
  });

  final String wire;
  final SvgValueKind kind;
  final bool inherited;
  final bool presentation;
  final List<String> keywords;

  static final Map<String, SvgAttr> byWire = <String, SvgAttr>{
    for (final SvgAttr attr in values) attr.wire: attr,
  };
}

/// Geometry attributes each drawable element accepts.
const Map<String, Set<SvgAttr>> kSvgGeometry = <String, Set<SvgAttr>>{
  'rect': <SvgAttr>{
    SvgAttr.x,
    SvgAttr.y,
    SvgAttr.width,
    SvgAttr.height,
    SvgAttr.rx,
    SvgAttr.ry,
  },
  'circle': <SvgAttr>{SvgAttr.cx, SvgAttr.cy, SvgAttr.r},
  'ellipse': <SvgAttr>{SvgAttr.cx, SvgAttr.cy, SvgAttr.rx, SvgAttr.ry},
  'line': <SvgAttr>{SvgAttr.x1, SvgAttr.y1, SvgAttr.x2, SvgAttr.y2},
  'polyline': <SvgAttr>{SvgAttr.points},
  'polygon': <SvgAttr>{SvgAttr.points},
  'path': <SvgAttr>{SvgAttr.d},
  'text': <SvgAttr>{SvgAttr.x, SvgAttr.y, SvgAttr.dx, SvgAttr.dy, SvgAttr.text},
  'tspan': <SvgAttr>{
    SvgAttr.x,
    SvgAttr.y,
    SvgAttr.dx,
    SvgAttr.dy,
    SvgAttr.text,
  },
  'g': <SvgAttr>{},
  'svg': <SvgAttr>{},
  'marker': <SvgAttr>{},
};

/// Elements that hold other elements but draw nothing themselves.
const Set<String> _kContainers = <String>{'svg', 'g', 'defs', 'marker'};

/// Elements whose content is ignored without complaint.
const Set<String> _kIgnoredElements = <String>{'desc', 'metadata'};

const Map<String, String> _kUnsupportedHints = <String, String>{
  'linearGradient': 'use flat colors',
  'radialGradient': 'use flat colors',
  'pattern': 'use flat colors',
  'filter': 'drop filters; use opacity or stroke for emphasis',
  'clipPath': 'clip paths are not supported',
  'mask': 'masks are not supported',
  'image': 'embedded images are not supported',
  'foreignObject': 'HTML is not supported; use <text>',
  'script': 'scripts are not supported; use steps and toggles',
  'animate': 'use steps; changes between steps animate automatically',
  'animateTransform': 'use steps; changes between steps animate automatically',
  'animateMotion': 'use steps; changes between steps animate automatically',
  'set': 'use steps',
  'use': 'repeat the shape instead of <use>',
  'symbol': 'repeat the shape instead of <symbol>',
  'a': 'links are not supported; use <g>',
  'switch': 'use <g>',
  'textPath': 'use positioned <text>',
};

/// Attributes accepted silently but without effect.
bool _ignoredAttribute(String name) =>
    name == 'xmlns' ||
    name.startsWith('xmlns:') ||
    name.startsWith('xml:') ||
    name.startsWith('aria-') ||
    name.startsWith('data-') ||
    name == 'version' ||
    name == 'baseProfile' ||
    name == 'preserveAspectRatio' ||
    name == 'role' ||
    name == 'focusable' ||
    name == 'shape-rendering' ||
    name == 'text-rendering' ||
    name == 'vector-effect' ||
    name == 'letter-spacing' ||
    name == 'paint-order';

class SvgViewBox {
  const SvgViewBox(this.x, this.y, this.width, this.height);
  final double x, y, width, height;
}

/// Placement of a `<marker>`'s content at a path vertex.
class SvgMarker {
  const SvgMarker({
    required this.refX,
    required this.refY,
    required this.markerWidth,
    required this.markerHeight,
    required this.viewBox,
    required this.orient,
    required this.strokeWidthUnits,
  });

  final double refX, refY, markerWidth, markerHeight;
  final SvgViewBox? viewBox;

  /// Fixed angle in degrees, or null for `auto`/`auto-start-reverse`
  /// (follow the path; see [SvgNode.orientReverse]).
  final double? orient;
  final bool strokeWidthUnits;
}

/// One element, or a run of character data inside `<text>` (tag `#text`,
/// its content in [props] under [SvgAttr.text]).
class SvgNode {
  SvgNode({
    required this.index,
    required this.tag,
    required this.id,
    required this.classes,
    required this.parent,
    required this.props,
    required this.line,
  });

  final int index;
  final String tag;
  final String? id;
  final List<String> classes;

  /// Index of the parent node; -1 for the root `<svg>`.
  final int parent;
  final List<int> children = <int>[];

  /// The element's own cascaded values (inheritance not applied).
  final Map<SvgAttr, Object> props;
  final int line;

  /// Tooltip text from a `<title>` child.
  String? title;

  /// Set when [tag] is `marker`.
  SvgMarker? marker;

  /// `auto-start-reverse` orientation on a marker.
  bool orientReverse = false;
}

class SvgDocument {
  SvgDocument._(this.viewBox, this.nodes, this.ids);

  final SvgViewBox viewBox;

  /// All nodes in document order; `nodes[0]` is the root `<svg>`.
  final List<SvgNode> nodes;
  final Map<String, int> ids;

  /// Node indices matching a comma-separated list of simple selectors.
  List<int> select(String selector) {
    final List<SvgSelector> parsed = parseSvgSelectors(selector);
    return <int>[
      for (final SvgNode node in nodes)
        if (node.tag != '#text' &&
            parsed.any((SvgSelector s) => s.matches(node)))
          node.index,
    ];
  }
}

/// A selector of the form `tag`, `#id`, `.class`, `tag.class.other`, or `*`.
class SvgSelector {
  const SvgSelector({this.tag, this.id, this.classes = const <String>[]});

  final String? tag;
  final String? id;
  final List<String> classes;

  int get specificity =>
      (id == null ? 0 : 100) + classes.length * 10 + (tag == null ? 0 : 1);

  bool matches(SvgNode node) {
    if (tag != null && tag != node.tag) return false;
    if (id != null && id != node.id) return false;
    for (final String c in classes) {
      if (!node.classes.contains(c)) return false;
    }
    return true;
  }
}

final RegExp _simpleSelector = RegExp(
  r'^(\*|[a-zA-Z][a-zA-Z0-9]*)?((?:[#.][a-zA-Z_][-a-zA-Z0-9_]*)*)$',
);
final RegExp _selectorPart = RegExp(r'([#.])([a-zA-Z_][-a-zA-Z0-9_]*)');

List<SvgSelector> parseSvgSelectors(String raw) {
  final List<SvgSelector> out = <SvgSelector>[];
  for (final String part in raw.split(',')) {
    final String trimmed = part.trim();
    final RegExpMatch? match = _simpleSelector.firstMatch(trimmed);
    if (trimmed.isEmpty || match == null) {
      throw FormatException(
        'unsupported selector "$trimmed"; use #id, .class, tag, or tag.class '
        '(no descendant/child combinators or pseudo-classes)',
      );
    }
    final String? tag = match.group(1);
    String? id;
    final List<String> classes = <String>[];
    for (final RegExpMatch piece in _selectorPart.allMatches(match.group(2)!)) {
      if (piece.group(1) == '#') {
        if (id != null) {
          throw FormatException('selector "$trimmed" has two ids');
        }
        id = piece.group(2);
      } else {
        classes.add(piece.group(2)!);
      }
    }
    out.add(
      SvgSelector(tag: tag == '*' ? null : tag, id: id, classes: classes),
    );
  }
  return out;
}

/// Thrown when an explainer or its SVG is invalid. [errors] lists every
/// problem found, so an agent can fix them all at once.
class ExplainerException implements Exception {
  const ExplainerException(this.errors, {this.warnings = const <String>[]});
  final List<String> errors;
  final List<String> warnings;

  @override
  String toString() => errors.join('\n');
}

/// Collects problems while parsing.
class ExplainerDiagnostics {
  final List<String> errors = <String>[];
  final List<String> warnings = <String>[];
  final Set<String> _warned = <String>{};

  void error(String message) {
    if (errors.length < 50) errors.add(message);
  }

  void warn(String message) {
    if (_warned.add(message) && warnings.length < 30) warnings.add(message);
  }
}

const int kMaxExplainerNodes = 5000;

/// Parses one attribute value. [fontSize] resolves `em` for `dx`/`dy`.
Object parseSvgAttrValue(SvgAttr attr, String raw, {double fontSize = 16}) {
  final String value = raw.trim();
  switch (attr.kind) {
    case SvgValueKind.paint:
      return parseSvgPaint(value);
    case SvgValueKind.number:
      return parseSvgLength(value);
    case SvgValueKind.opacity:
      if (value.endsWith('%')) {
        return (parseSvgLength(value.substring(0, value.length - 1)) / 100)
            .clamp(0.0, 1.0);
      }
      return parseSvgLength(value).clamp(0.0, 1.0);
    case SvgValueKind.length:
      final bool relative = attr == SvgAttr.dx || attr == SvgAttr.dy;
      final double length = parseSvgLength(
        value,
        fontSize: relative ? fontSize : null,
      );
      if (length < 0 &&
          attr != SvgAttr.x &&
          attr != SvgAttr.y &&
          attr != SvgAttr.dx &&
          attr != SvgAttr.dy &&
          attr != SvgAttr.x1 &&
          attr != SvgAttr.y1 &&
          attr != SvgAttr.x2 &&
          attr != SvgAttr.y2 &&
          attr != SvgAttr.cx &&
          attr != SvgAttr.cy) {
        throw FormatException('${attr.wire} must not be negative');
      }
      return length;
    case SvgValueKind.dashArray:
      if (value == 'none') return const <double>[];
      final List<double> dashes = parseSvgNumberList(
        value.replaceAll('px', ''),
      );
      if (dashes.any((double v) => v < 0)) {
        throw FormatException('stroke-dasharray must not be negative');
      }
      if (dashes.isNotEmpty && dashes.every((double v) => v == 0)) {
        return const <double>[];
      }
      return dashes.length.isOdd ? <double>[...dashes, ...dashes] : dashes;
    case SvgValueKind.keyword:
      if (!attr.keywords.contains(value)) {
        throw FormatException(
          '${attr.wire} must be one of ${attr.keywords.join(', ')}',
        );
      }
      return value;
    case SvgValueKind.fontWeight:
      return switch (value) {
        'normal' => 400.0,
        'bold' || 'bolder' => 700.0,
        'lighter' => 300.0,
        _ => switch (double.tryParse(value)) {
          final double w when w >= 1 && w <= 1000 => w,
          _ => throw FormatException('bad font-weight "$value"'),
        },
      };
    case SvgValueKind.string:
      return raw;
    case SvgValueKind.marker:
      if (value == 'none') return '';
      final RegExpMatch? match = RegExp(
        r'''^url\(\s*['"]?#([^'")\s]+)['"]?\s*\)$''',
      ).firstMatch(value);
      if (match == null) {
        throw FormatException('${attr.wire} must be url(#id) or none');
      }
      return match.group(1)!;
    case SvgValueKind.transform:
      return parseSvgTransform(value);
    case SvgValueKind.points:
      final List<double> points = parseSvgNumberList(value);
      if (points.length.isOdd || points.length < 4) {
        throw FormatException('points needs at least two x,y pairs');
      }
      return points;
    case SvgValueKind.path:
      return parseSvgPathData(value);
  }
}

/// Parses `prop: value; ...` declarations, as in `style=""` or a CSS rule.
List<(String, String)> _declarations(String block) {
  final List<(String, String)> out = <(String, String)>[];
  for (final String declaration in block.split(';')) {
    final int colon = declaration.indexOf(':');
    if (colon < 0) continue;
    final String name = declaration.substring(0, colon).trim().toLowerCase();
    String value = declaration.substring(colon + 1).trim();
    if (value.endsWith('!important')) {
      value = value.substring(0, value.length - 10).trim();
    }
    if (name.isNotEmpty && value.isNotEmpty) out.add((name, value));
  }
  return out;
}

class _CssRule {
  const _CssRule(this.selector, this.declarations, this.order);
  final SvgSelector selector;
  final List<(String, String)> declarations;
  final int order;
}

/// Appends [css]'s rules to [rules], numbered after those already there.
void _parseStylesheet(
  String css,
  ExplainerDiagnostics diag,
  List<_CssRule> rules,
) {
  final String source = css.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  int i = 0;
  while (i < source.length) {
    final int open = source.indexOf('{', i);
    if (open < 0) break;
    final String prelude = source.substring(i, open).trim();
    // Find the matching close brace (at-rules like @media nest).
    int depth = 1;
    int close = open + 1;
    while (close < source.length && depth > 0) {
      final String c = source[close];
      if (c == '{') depth++;
      if (c == '}') depth--;
      close++;
    }
    if (depth != 0) {
      diag.error('<style>: unbalanced braces');
      break;
    }
    final String body = source.substring(open + 1, close - 1);
    i = close;
    if (prelude.startsWith('@')) {
      final String at = prelude.split(RegExp(r'\s')).first;
      diag.warn(
        '<style>: $at rules are ignored'
        '${at == '@keyframes' ? '; use steps (changes animate automatically)' : ''}',
      );
      continue;
    }
    final List<SvgSelector> selectors;
    try {
      selectors = parseSvgSelectors(prelude);
    } on FormatException catch (e) {
      diag.warn('<style>: rule skipped: ${e.message}');
      continue;
    }
    final List<(String, String)> declarations = _declarations(body);
    for (final SvgSelector selector in selectors) {
      rules.add(_CssRule(selector, declarations, rules.length));
    }
  }
}

/// Parses the explainer SVG subset. Throws [ExplainerException] when
/// [diag] holds errors afterwards; the caller decides, so step problems
/// can be reported alongside markup problems.
SvgDocument? parseSvgDocument(String source, ExplainerDiagnostics diag) {
  final XmlElement root;
  try {
    root = parseXml(source);
  } on XmlParseException catch (e) {
    diag.error('svg is not well-formed XML: $e');
    return null;
  }
  if (root.name != 'svg') {
    diag.error('the root element must be <svg>, not <${root.name}>');
    return null;
  }

  // Stylesheets apply document-wide regardless of where <style> appears.
  final List<_CssRule> rules = <_CssRule>[];
  void collectStyles(XmlElement element) {
    for (final XmlNode child in element.children) {
      if (child is! XmlElement) continue;
      if (child.name == 'style') {
        final String css = child.children
            .whereType<XmlText>()
            .map((XmlText t) => t.text)
            .join();
        _parseStylesheet(css, diag, rules);
      } else {
        collectStyles(child);
      }
    }
  }

  collectStyles(root);
  rules.sort((_CssRule a, _CssRule b) {
    final int bySpecificity = a.selector.specificity.compareTo(
      b.selector.specificity,
    );
    return bySpecificity != 0 ? bySpecificity : a.order.compareTo(b.order);
  });

  final SvgViewBox? viewBox = _rootViewBox(root, diag);
  final List<SvgNode> nodes = <SvgNode>[];
  final Map<String, int> ids = <String, int>{};
  final List<(int, SvgAttr, String, int)> markerRefs =
      <(int, SvgAttr, String, int)>[];

  double inheritedFontSize(int parent) {
    for (int p = parent; p >= 0; p = nodes[p].parent) {
      final Object? size = nodes[p].props[SvgAttr.fontSize];
      if (size is double) return size;
    }
    return 16;
  }

  bool overflowed = false;
  void visit(XmlElement element, int parent, bool inText) {
    if (nodes.length >= kMaxExplainerNodes) {
      if (!overflowed) {
        diag.error('svg has more than $kMaxExplainerNodes elements');
        overflowed = true;
      }
      return;
    }
    final String tag = element.name;
    final String where = 'line ${element.line} <$tag>';
    if (_kUnsupportedHints[tag] case final String hint) {
      diag.error('$where is not supported: $hint');
      return;
    }
    final bool textual = tag == 'text' || tag == 'tspan';
    if (!_kContainers.contains(tag) && !kSvgGeometry.containsKey(tag)) {
      diag.error('$where is not part of the explainer SVG subset');
      return;
    }
    if (tag == 'svg' && parent >= 0) {
      diag.error('$where: nested <svg> is not supported; use <g>');
      return;
    }
    if (inText && tag != 'tspan') {
      diag.error('$where: only <tspan> may appear inside <text>');
      return;
    }
    if (tag == 'tspan' && !inText) {
      diag.error('$where: <tspan> must be inside <text>');
      return;
    }

    final String? id = element.attributes['id'];
    final List<String> classes = (element.attributes['class'] ?? '')
        .split(RegExp(r'\s+'))
        .where((String c) => c.isNotEmpty)
        .toList(growable: false);
    final Set<SvgAttr> geometry = kSvgGeometry[tag] ?? const <SvgAttr>{};
    final Map<SvgAttr, String> raw = <SvgAttr, String>{};

    for (final MapEntry<String, String> entry in element.attributes.entries) {
      final String name = entry.key;
      if (name == 'id' || name == 'class' || name == 'style') continue;
      if (tag == 'svg' &&
          (name == 'viewBox' || name == 'width' || name == 'height')) {
        continue;
      }
      if (tag == 'marker' && _kMarkerAttributes.contains(name)) continue;
      if (_ignoredAttribute(name)) continue;
      final SvgAttr? attr = SvgAttr.byWire[name];
      if (attr == null || attr == SvgAttr.text) {
        if (name.startsWith('on')) {
          diag.error(
            '$where: event handler $name is not supported; use '
            'steps, toggles, and <title> tooltips',
          );
        } else {
          diag.warn('attribute "$name" is not supported and was ignored');
        }
        continue;
      }
      if (!attr.presentation && !geometry.contains(attr)) {
        if (attr == SvgAttr.transform && tag != 'marker') {
          raw[attr] = entry.value;
          continue;
        }
        diag.error('$where: attribute ${attr.wire} does not apply here');
        continue;
      }
      raw[attr] = entry.value;
    }

    // Cascade: presentation attributes < stylesheet rules < inline style.
    final SvgNode probe = SvgNode(
      index: -1,
      tag: tag,
      id: id,
      classes: classes,
      parent: parent,
      props: const <SvgAttr, Object>{},
      line: element.line,
    );
    void declare(String name, String value, String origin) {
      final SvgAttr? attr = SvgAttr.byWire[name];
      if (attr == null || !attr.presentation) {
        diag.warn('$origin property "$name" is not supported and was ignored');
        return;
      }
      raw[attr] = value;
    }

    for (final _CssRule rule in rules) {
      if (!rule.selector.matches(probe)) continue;
      for (final (String name, String value) in rule.declarations) {
        declare(name, value, '<style>');
      }
    }
    if (element.attributes['style'] case final String inline) {
      for (final (String name, String value) in _declarations(inline)) {
        declare(name, value, 'style=""');
      }
    }

    final Map<SvgAttr, Object> props = <SvgAttr, Object>{};
    final int index = nodes.length;
    final SvgNode node = SvgNode(
      index: index,
      tag: tag,
      id: id,
      classes: classes,
      parent: parent,
      props: props,
      line: element.line,
    );
    nodes.add(node);
    if (parent >= 0) nodes[parent].children.add(index);
    if (id != null) {
      if (ids.containsKey(id)) {
        diag.error('$where: duplicate id "$id"');
      } else {
        ids[id] = index;
      }
    }

    // font-size first: em offsets on this element resolve against it.
    final List<SvgAttr> order = raw.keys.toList()
      ..sort((SvgAttr a, SvgAttr b) {
        if (a == SvgAttr.fontSize) return -1;
        if (b == SvgAttr.fontSize) return 1;
        return 0;
      });
    for (final SvgAttr attr in order) {
      try {
        final Object value = parseSvgAttrValue(
          attr,
          raw[attr]!,
          fontSize:
              props[SvgAttr.fontSize] as double? ?? inheritedFontSize(parent),
        );
        props[attr] = value;
        if (attr.kind == SvgValueKind.marker &&
            value is String &&
            value.isNotEmpty) {
          markerRefs.add((index, attr, value, element.line));
        }
      } on FormatException catch (e) {
        diag.error('$where: ${attr.wire}: ${e.message}');
      }
    }
    _checkGeometry(node, where, diag);

    if (tag == 'marker') node.marker = _marker(element, where, diag, node);

    for (final XmlNode child in element.children) {
      switch (child) {
        case XmlElement(name: 'title'):
          node.title = child.children
              .whereType<XmlText>()
              .map((XmlText t) => t.text)
              .join()
              .trim()
              .replaceAll(RegExp(r'\s+'), ' ');
        case XmlElement(name: 'style'):
          break; // collected up front
        case XmlElement(:final String name)
            when _kIgnoredElements.contains(name):
          break;
        case XmlElement():
          visit(child, index, textual);
        case XmlText(:final String text):
          if (!textual) {
            if (text.trim().isNotEmpty) {
              diag.warn('text outside <text> is not drawn; wrap it in <text>');
            }
            continue;
          }
          final int textIndex = nodes.length;
          nodes.add(
            SvgNode(
              index: textIndex,
              tag: '#text',
              id: null,
              classes: const <String>[],
              parent: index,
              props: <SvgAttr, Object>{SvgAttr.text: text},
              line: element.line,
            ),
          );
          node.children.add(textIndex);
      }
    }
  }

  visit(root, -1, false);

  for (final (int index, SvgAttr attr, String id, int line) in markerRefs) {
    final int? target = ids[id];
    if (target == null || nodes[target].tag != 'marker') {
      diag.error(
        'line $line <${nodes[index].tag}>: ${attr.wire} references '
        '#$id, which is not a <marker>',
      );
    }
  }
  _collapseWhitespace(nodes);

  if (viewBox == null || diag.errors.isNotEmpty) return null;
  return SvgDocument._(viewBox, nodes, ids);
}

const Set<String> _kMarkerAttributes = <String>{
  'viewBox',
  'refX',
  'refY',
  'markerWidth',
  'markerHeight',
  'orient',
  'markerUnits',
};

SvgViewBox? _rootViewBox(XmlElement root, ExplainerDiagnostics diag) {
  final String? raw = root.attributes['viewBox'];
  if (raw != null) {
    try {
      return _viewBox(raw);
    } on FormatException catch (e) {
      diag.error('<svg> viewBox: ${e.message}');
      return null;
    }
  }
  try {
    final String? width = root.attributes['width'];
    final String? height = root.attributes['height'];
    if (width != null && height != null) {
      return SvgViewBox(0, 0, parseSvgLength(width), parseSvgLength(height));
    }
  } on FormatException catch (e) {
    diag.error('<svg> size: ${e.message}');
    return null;
  }
  diag.error('<svg> needs a viewBox, e.g. viewBox="0 0 640 360"');
  return null;
}

SvgViewBox _viewBox(String raw) {
  final List<double> numbers = parseSvgNumberList(raw);
  if (numbers.length != 4 || numbers[2] <= 0 || numbers[3] <= 0) {
    throw const FormatException(
      'needs four numbers "minX minY width height" with positive size',
    );
  }
  return SvgViewBox(numbers[0], numbers[1], numbers[2], numbers[3]);
}

SvgMarker? _marker(
  XmlElement element,
  String where,
  ExplainerDiagnostics diag,
  SvgNode node,
) {
  final Map<String, String> a = element.attributes;
  try {
    double number(String name, double fallback) {
      final String? value = a[name];
      return value == null ? fallback : parseSvgLength(value);
    }

    final String orient = (a['orient'] ?? '0').trim();
    double? angle;
    if (orient == 'auto-start-reverse') {
      node.orientReverse = true;
    } else if (orient != 'auto') {
      angle = parseSvgLength(orient.replaceAll('deg', ''));
    }
    final String units = a['markerUnits'] ?? 'strokeWidth';
    if (units != 'strokeWidth' && units != 'userSpaceOnUse') {
      throw const FormatException(
        'markerUnits must be strokeWidth or userSpaceOnUse',
      );
    }
    return SvgMarker(
      refX: number('refX', 0),
      refY: number('refY', 0),
      markerWidth: number('markerWidth', 3),
      markerHeight: number('markerHeight', 3),
      viewBox: a['viewBox'] == null ? null : _viewBox(a['viewBox']!),
      orient: angle,
      strokeWidthUnits: units == 'strokeWidth',
    );
  } on FormatException catch (e) {
    diag.error('$where: ${e.message}');
    return null;
  }
}

void _checkGeometry(SvgNode node, String where, ExplainerDiagnostics diag) {
  final Map<SvgAttr, Object> p = node.props;
  switch (node.tag) {
    case 'rect':
      if (!p.containsKey(SvgAttr.width) || !p.containsKey(SvgAttr.height)) {
        diag.error('$where needs width and height');
      }
    case 'circle':
      if (!p.containsKey(SvgAttr.r)) diag.error('$where needs r');
    case 'ellipse':
      if (!p.containsKey(SvgAttr.rx) && !p.containsKey(SvgAttr.ry)) {
        diag.error('$where needs rx and ry');
      }
    case 'polyline':
    case 'polygon':
      if (!p.containsKey(SvgAttr.points)) diag.error('$where needs points');
    case 'path':
      if (!p.containsKey(SvgAttr.d)) diag.error('$where needs d');
  }
}

/// Applies SVG's default whitespace handling to `<text>` content: newlines
/// and tabs become spaces, runs collapse, and the ends of each `<text>` trim.
void _collapseWhitespace(List<SvgNode> nodes) {
  for (final SvgNode node in nodes) {
    if (node.tag != 'text') continue;
    final List<SvgNode> runs = <SvgNode>[];
    void collect(SvgNode parent) {
      for (final int child in parent.children) {
        final SvgNode c = nodes[child];
        if (c.tag == '#text') {
          runs.add(c);
        } else {
          collect(c);
        }
      }
    }

    collect(node);
    bool previousSpace = true; // trims the leading edge
    for (final SvgNode run in runs) {
      final String text = run.props[SvgAttr.text]! as String;
      final StringBuffer out = StringBuffer();
      for (final int unit in text.runes) {
        final bool space =
            unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D;
        if (space) {
          if (!previousSpace) out.write(' ');
          previousSpace = true;
        } else {
          out.writeCharCode(unit);
          previousSpace = false;
        }
      }
      run.props[SvgAttr.text] = out.toString();
    }
    for (int i = runs.length - 1; i >= 0; i--) {
      final String text = runs[i].props[SvgAttr.text]! as String;
      final String trimmed = text.trimRight();
      runs[i].props[SvgAttr.text] = trimmed;
      if (trimmed.isNotEmpty) break;
    }
  }
}
