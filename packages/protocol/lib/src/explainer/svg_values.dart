/// Typed attribute values of the explainer SVG subset, plus their parsers.
/// Every parser throws [FormatException] with a message fit for an agent.
library;

import 'dart:math' as math;

/// Theme colors an explainer may reference as `var(--name)`. Clients map
/// them to their own palette so explainers follow light and dark themes.
const List<String> kExplainerThemeTokens = <String>[
  'fg',
  'muted',
  'bg',
  'surface',
  'border',
  'accent',
  'success',
  'warning',
  'danger',
  'info',
  'purple',
  'code',
];

/// A fill or stroke.
sealed class SvgPaint {
  const SvgPaint();
}

class SvgNoPaint extends SvgPaint {
  const SvgNoPaint();

  @override
  bool operator ==(Object other) => other is SvgNoPaint;

  @override
  int get hashCode => 0;
}

/// A literal color as 0xAARRGGBB.
class SvgColor extends SvgPaint {
  const SvgColor(this.argb);
  final int argb;

  @override
  bool operator ==(Object other) => other is SvgColor && other.argb == argb;

  @override
  int get hashCode => argb.hashCode;
}

/// One of [kExplainerThemeTokens]; `currentColor` resolves to `fg`.
class SvgThemeColor extends SvgPaint {
  const SvgThemeColor(this.token);
  final String token;

  @override
  bool operator ==(Object other) =>
      other is SvgThemeColor && other.token == token;

  @override
  int get hashCode => token.hashCode;
}

/// `context-stroke` / `context-fill`: inside a `<marker>`, the stroke or fill
/// of the element the marker is drawn on (so arrowheads match their edge).
/// Elsewhere it paints nothing.
class SvgContextPaint extends SvgPaint {
  const SvgContextPaint({required this.stroke});
  final bool stroke;

  @override
  bool operator ==(Object other) =>
      other is SvgContextPaint && other.stroke == stroke;

  @override
  int get hashCode => stroke.hashCode;
}

SvgPaint parseSvgPaint(String raw) {
  final String value = raw.trim();
  final String lower = value.toLowerCase();
  if (lower == 'none' || lower == 'transparent') return const SvgNoPaint();
  if (lower == 'currentcolor') return const SvgThemeColor('fg');
  if (lower == 'context-stroke') return const SvgContextPaint(stroke: true);
  if (lower == 'context-fill') return const SvgContextPaint(stroke: false);
  if (lower.startsWith('var(')) {
    final RegExpMatch? match = RegExp(r'^var\(\s*--([a-z0-9-]+)\s*\)$')
        .firstMatch(lower);
    final String? token = match?.group(1);
    if (token == null || !kExplainerThemeTokens.contains(token)) {
      throw FormatException(
        'unknown theme color "$value"; use one of '
        '${kExplainerThemeTokens.map((t) => 'var(--$t)').join(', ')}',
      );
    }
    return SvgThemeColor(token);
  }
  if (lower.startsWith('url(')) {
    throw FormatException(
      'paint server "$value" is not supported; use a flat color',
    );
  }
  return SvgColor(parseCssColor(value));
}

/// Parses `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`, `rgb()`/`rgba()`,
/// `hsl()`/`hsla()`, and CSS named colors into 0xAARRGGBB.
int parseCssColor(String raw) {
  final String value = raw.trim().toLowerCase();
  if (value.startsWith('#')) {
    final String hex = value.substring(1);
    final int? parsed = int.tryParse(hex, radix: 16);
    if (parsed != null) {
      switch (hex.length) {
        case 3:
        case 4:
          int expand(int nibble) => nibble << 4 | nibble;
          final int r = expand(int.parse(hex[0], radix: 16));
          final int g = expand(int.parse(hex[1], radix: 16));
          final int b = expand(int.parse(hex[2], radix: 16));
          final int a = hex.length == 4
              ? expand(int.parse(hex[3], radix: 16))
              : 0xFF;
          return a << 24 | r << 16 | g << 8 | b;
        case 6:
          return 0xFF000000 | parsed;
        case 8:
          return (parsed & 0xFF) << 24 | parsed >> 8;
      }
    }
    throw FormatException('bad hex color "$raw"');
  }
  final RegExpMatch? function = RegExp(r'^(rgba?|hsla?)\((.*)\)$')
      .firstMatch(value);
  if (function != null) {
    final List<String> parts = function
        .group(2)!
        .split(RegExp(r'[\s,/]+'))
        .where((String part) => part.isNotEmpty)
        .toList();
    if (parts.length != 3 && parts.length != 4) {
      throw FormatException('bad color "$raw"');
    }
    double channel(String part, double scale) {
      final bool percent = part.endsWith('%');
      final double? number = double.tryParse(
        percent ? part.substring(0, part.length - 1) : part,
      );
      if (number == null) throw FormatException('bad color "$raw"');
      return percent ? number / 100 * scale : number;
    }

    final double alpha = parts.length == 4
        ? channel(parts[3], 1).clamp(0, 1).toDouble()
        : 1;
    final int a = (alpha * 255).round();
    if (function.group(1)!.startsWith('rgb')) {
      final int r = channel(parts[0], 255).round().clamp(0, 255);
      final int g = channel(parts[1], 255).round().clamp(0, 255);
      final int b = channel(parts[2], 255).round().clamp(0, 255);
      return a << 24 | r << 16 | g << 8 | b;
    }
    final double h =
        (double.tryParse(parts[0].replaceAll('deg', '')) ??
            (throw FormatException('bad color "$raw"'))) %
        360;
    final double s = channel(parts[1], 1).clamp(0, 1).toDouble();
    final double l = channel(parts[2], 1).clamp(0, 1).toDouble();
    final double c = (1 - (2 * l - 1).abs()) * s;
    final double x = c * (1 - ((h / 60) % 2 - 1).abs());
    final double m = l - c / 2;
    final (double r1, double g1, double b1) = switch (h) {
      < 60 => (c, x, 0.0),
      < 120 => (x, c, 0.0),
      < 180 => (0.0, c, x),
      < 240 => (0.0, x, c),
      < 300 => (x, 0.0, c),
      _ => (c, 0.0, x),
    };
    int byte(double v) => ((v + m) * 255).round().clamp(0, 255);
    return a << 24 | byte(r1) << 16 | byte(g1) << 8 | byte(b1);
  }
  final int? named = _namedColors[value];
  if (named != null) return 0xFF000000 | named;
  throw FormatException('unknown color "$raw"');
}

final RegExp _numberPattern = RegExp(
  r'[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?',
);

/// A plain number or a `px` length. Percentages and font-relative units are
/// rejected: explainers are laid out in viewBox units.
double parseSvgLength(String raw, {double? fontSize}) {
  String value = raw.trim();
  double scale = 1;
  if (value.endsWith('px')) {
    value = value.substring(0, value.length - 2);
  } else if (value.endsWith('em') && fontSize != null) {
    value = value.substring(0, value.length - 2);
    scale = fontSize;
  }
  final double? number = double.tryParse(value);
  if (number == null || !number.isFinite) {
    throw FormatException(
      '"$raw" is not a number (use plain viewBox units; % and em are not '
      'supported here)',
    );
  }
  return number * scale;
}

/// Comma- or space-separated numbers, e.g. `points` or `viewBox`.
List<double> parseSvgNumberList(String raw) {
  final String rest = raw
      .replaceAll(_numberPattern, '')
      .replaceAll(RegExp(r'[\s,]'), '');
  if (rest.isNotEmpty) throw FormatException('"$raw" is not a number list');
  return _numberPattern
      .allMatches(raw)
      .map((RegExpMatch m) => double.parse(m.group(0)!))
      .toList(growable: false);
}

/// An affine matrix `[a b c d e f]` as in SVG `matrix()`.
class SvgMatrix {
  const SvgMatrix(this.a, this.b, this.c, this.d, this.e, this.f);

  static const SvgMatrix identity = SvgMatrix(1, 0, 0, 1, 0, 0);

  final double a, b, c, d, e, f;

  SvgMatrix multiply(SvgMatrix o) => SvgMatrix(
    a * o.a + c * o.b,
    b * o.a + d * o.b,
    a * o.c + c * o.d,
    b * o.c + d * o.d,
    a * o.e + c * o.f + e,
    b * o.e + d * o.f + f,
  );

  (double, double) apply(double x, double y) =>
      (a * x + c * y + e, b * x + d * y + f);

  @override
  bool operator ==(Object other) =>
      other is SvgMatrix &&
      other.a == a &&
      other.b == b &&
      other.c == c &&
      other.d == d &&
      other.e == e &&
      other.f == f;

  @override
  int get hashCode => Object.hash(a, b, c, d, e, f);
}

enum SvgTransformKind { matrix, translate, scale, rotate, skewX, skewY }

/// One function of a transform list, with SVG's defaults filled in so that
/// two lists of the same shape can be interpolated argument by argument.
class SvgTransformOp {
  const SvgTransformOp(this.kind, this.args);
  final SvgTransformKind kind;

  /// matrix: 6; translate: tx ty; scale: sx sy; rotate: angle cx cy;
  /// skewX/skewY: angle.
  final List<double> args;

  SvgMatrix get matrix {
    switch (kind) {
      case SvgTransformKind.matrix:
        return SvgMatrix(args[0], args[1], args[2], args[3], args[4], args[5]);
      case SvgTransformKind.translate:
        return SvgMatrix(1, 0, 0, 1, args[0], args[1]);
      case SvgTransformKind.scale:
        return SvgMatrix(args[0], 0, 0, args[1], 0, 0);
      case SvgTransformKind.rotate:
        final double r = args[0] * math.pi / 180;
        final double cos = math.cos(r);
        final double sin = math.sin(r);
        final SvgMatrix rotation = SvgMatrix(cos, sin, -sin, cos, 0, 0);
        if (args[1] == 0 && args[2] == 0) return rotation;
        return SvgMatrix(1, 0, 0, 1, args[1], args[2])
            .multiply(rotation)
            .multiply(SvgMatrix(1, 0, 0, 1, -args[1], -args[2]));
      case SvgTransformKind.skewX:
        return SvgMatrix(1, 0, math.tan(args[0] * math.pi / 180), 1, 0, 0);
      case SvgTransformKind.skewY:
        return SvgMatrix(1, math.tan(args[0] * math.pi / 180), 0, 1, 0, 0);
    }
  }
}

class SvgTransform {
  const SvgTransform(this.ops);
  final List<SvgTransformOp> ops;

  SvgMatrix get matrix {
    SvgMatrix result = SvgMatrix.identity;
    for (final SvgTransformOp op in ops) {
      result = result.multiply(op.matrix);
    }
    return result;
  }

  /// True when [other] has the same functions in the same order, so the two
  /// can be tweened argument by argument.
  bool sameShape(SvgTransform other) {
    if (other.ops.length != ops.length) return false;
    for (int i = 0; i < ops.length; i++) {
      if (ops[i].kind != other.ops[i].kind) return false;
    }
    return true;
  }
}

SvgTransform parseSvgTransform(String raw) {
  final List<SvgTransformOp> ops = <SvgTransformOp>[];
  final RegExp function = RegExp(r'\s*,?\s*([a-zA-Z]+)\s*\(([^)]*)\)');
  int at = 0;
  final String value = raw.trim();
  while (at < value.length) {
    final Match? match = function.matchAsPrefix(value, at);
    if (match == null) throw FormatException('bad transform "$raw"');
    at = match.end;
    final String name = match.group(1)!;
    final List<double> args = parseSvgNumberList(match.group(2)!);
    Never bad() =>
        throw FormatException('bad $name() arguments in transform "$raw"');
    switch (name) {
      case 'matrix':
        if (args.length != 6) bad();
        ops.add(SvgTransformOp(SvgTransformKind.matrix, args));
      case 'translate':
        if (args.isEmpty || args.length > 2) bad();
        ops.add(
          SvgTransformOp(SvgTransformKind.translate, <double>[
            args[0],
            args.length > 1 ? args[1] : 0,
          ]),
        );
      case 'scale':
        if (args.isEmpty || args.length > 2) bad();
        ops.add(
          SvgTransformOp(SvgTransformKind.scale, <double>[
            args[0],
            args.length > 1 ? args[1] : args[0],
          ]),
        );
      case 'rotate':
        if (args.length != 1 && args.length != 3) bad();
        ops.add(
          SvgTransformOp(SvgTransformKind.rotate, <double>[
            args[0],
            args.length == 3 ? args[1] : 0,
            args.length == 3 ? args[2] : 0,
          ]),
        );
      case 'skewX':
        if (args.length != 1) bad();
        ops.add(SvgTransformOp(SvgTransformKind.skewX, args));
      case 'skewY':
        if (args.length != 1) bad();
        ops.add(SvgTransformOp(SvgTransformKind.skewY, args));
      default:
        throw FormatException('unknown transform function $name()');
    }
  }
  return SvgTransform(ops);
}

enum SvgPathVerb { moveTo, lineTo, cubicTo, quadTo, arcTo, close }

/// One absolute path segment. Arguments per verb: moveTo/lineTo: x y;
/// cubicTo: x1 y1 x2 y2 x y; quadTo: x1 y1 x y; arcTo: rx ry rotation
/// largeArc(0/1) sweep(0/1) x y; close: none.
class SvgPathCommand {
  const SvgPathCommand(this.verb, this.args);
  final SvgPathVerb verb;
  final List<double> args;
}

class SvgPathData {
  const SvgPathData(this.commands);
  final List<SvgPathCommand> commands;

  bool sameShape(SvgPathData other) {
    if (other.commands.length != commands.length) return false;
    for (int i = 0; i < commands.length; i++) {
      final SvgPathCommand a = commands[i];
      final SvgPathCommand b = other.commands[i];
      if (a.verb != b.verb) return false;
      if (a.verb == SvgPathVerb.arcTo &&
          (a.args[3] != b.args[3] || a.args[4] != b.args[4])) {
        return false;
      }
    }
    return true;
  }
}

/// Parses path data into absolute commands. Relative commands, H/V, and the
/// smooth S/T forms are normalized away.
SvgPathData parseSvgPathData(String raw) {
  final List<SvgPathCommand> out = <SvgPathCommand>[];
  final _PathScanner scan = _PathScanner(raw);
  double x = 0, y = 0; // current point
  double sx = 0, sy = 0; // subpath start
  double? lastCubicX, lastCubicY, lastQuadX, lastQuadY;
  String? command;
  while (true) {
    scan.skipSeparators();
    if (scan.done) break;
    final String? letter = scan.letter();
    if (letter != null) {
      command = letter;
    } else if (command == null) {
      throw FormatException('path data "$raw" must start with M');
    } else if (command == 'M') {
      command = 'L';
    } else if (command == 'm') {
      command = 'l';
    } else if (command == 'Z' || command == 'z') {
      throw FormatException('unexpected number after Z in path "$raw"');
    }
    if (out.isEmpty && command != 'M' && command != 'm') {
      throw FormatException('path data "$raw" must start with M');
    }
    final bool rel = command.toLowerCase() == command;
    final double ox = rel ? x : 0;
    final double oy = rel ? y : 0;
    double? cubicX, cubicY, quadX, quadY;
    switch (command.toUpperCase()) {
      case 'M':
        x = ox + scan.number();
        y = oy + scan.number();
        sx = x;
        sy = y;
        out.add(SvgPathCommand(SvgPathVerb.moveTo, <double>[x, y]));
      case 'L':
        x = ox + scan.number();
        y = oy + scan.number();
        out.add(SvgPathCommand(SvgPathVerb.lineTo, <double>[x, y]));
      case 'H':
        x = ox + scan.number();
        out.add(SvgPathCommand(SvgPathVerb.lineTo, <double>[x, y]));
      case 'V':
        y = oy + scan.number();
        out.add(SvgPathCommand(SvgPathVerb.lineTo, <double>[x, y]));
      case 'C':
      case 'S':
        final double x1, y1;
        if (command.toUpperCase() == 'C') {
          x1 = ox + scan.number();
          y1 = oy + scan.number();
        } else {
          x1 = lastCubicX == null ? x : 2 * x - lastCubicX;
          y1 = lastCubicY == null ? y : 2 * y - lastCubicY;
        }
        final double x2 = ox + scan.number();
        final double y2 = oy + scan.number();
        x = ox + scan.number();
        y = oy + scan.number();
        cubicX = x2;
        cubicY = y2;
        out.add(
          SvgPathCommand(SvgPathVerb.cubicTo, <double>[x1, y1, x2, y2, x, y]),
        );
      case 'Q':
      case 'T':
        final double x1, y1;
        if (command.toUpperCase() == 'Q') {
          x1 = ox + scan.number();
          y1 = oy + scan.number();
        } else {
          x1 = lastQuadX == null ? x : 2 * x - lastQuadX;
          y1 = lastQuadY == null ? y : 2 * y - lastQuadY;
        }
        x = ox + scan.number();
        y = oy + scan.number();
        quadX = x1;
        quadY = y1;
        out.add(SvgPathCommand(SvgPathVerb.quadTo, <double>[x1, y1, x, y]));
      case 'A':
        final double rx = scan.number().abs();
        final double ry = scan.number().abs();
        final double rotation = scan.number();
        final double large = scan.flag();
        final double sweep = scan.flag();
        x = ox + scan.number();
        y = oy + scan.number();
        out.add(
          SvgPathCommand(SvgPathVerb.arcTo, <double>[
            rx,
            ry,
            rotation,
            large,
            sweep,
            x,
            y,
          ]),
        );
      case 'Z':
        x = sx;
        y = sy;
        out.add(const SvgPathCommand(SvgPathVerb.close, <double>[]));
      default:
        throw FormatException('unknown path command "$command" in "$raw"');
    }
    lastCubicX = cubicX;
    lastCubicY = cubicY;
    lastQuadX = quadX;
    lastQuadY = quadY;
  }
  if (out.isEmpty) throw FormatException('path data "$raw" is empty');
  return SvgPathData(out);
}

class _PathScanner {
  _PathScanner(this.s);
  final String s;
  int i = 0;

  bool get done => i >= s.length;

  void skipSeparators() {
    while (i < s.length) {
      final int c = s.codeUnitAt(i);
      if (c == 0x20 || c == 0x2C || c == 0x09 || c == 0x0A || c == 0x0D) {
        i++;
      } else {
        return;
      }
    }
  }

  String? letter() {
    final String c = s[i];
    if (RegExp(r'[MmLlHhVvCcSsQqTtAaZz]').hasMatch(c)) {
      i++;
      return c;
    }
    if (RegExp(r'[a-zA-Z]').hasMatch(c)) {
      throw FormatException('unknown path command "$c" in "$s"');
    }
    return null;
  }

  double number() {
    skipSeparators();
    final Match? match = _numberPattern.matchAsPrefix(s, i);
    if (match == null) throw FormatException('expected a number in path "$s"');
    i = match.end;
    return double.parse(match.group(0)!);
  }

  double flag() {
    skipSeparators();
    if (i < s.length && (s[i] == '0' || s[i] == '1')) {
      return s[i++] == '1' ? 1 : 0;
    }
    throw FormatException('expected an arc flag (0 or 1) in path "$s"');
  }
}

const Map<String, int> _namedColors = <String, int>{
  'aliceblue': 0xF0F8FF,
  'antiquewhite': 0xFAEBD7,
  'aqua': 0x00FFFF,
  'aquamarine': 0x7FFFD4,
  'azure': 0xF0FFFF,
  'beige': 0xF5F5DC,
  'bisque': 0xFFE4C4,
  'black': 0x000000,
  'blanchedalmond': 0xFFEBCD,
  'blue': 0x0000FF,
  'blueviolet': 0x8A2BE2,
  'brown': 0xA52A2A,
  'burlywood': 0xDEB887,
  'cadetblue': 0x5F9EA0,
  'chartreuse': 0x7FFF00,
  'chocolate': 0xD2691E,
  'coral': 0xFF7F50,
  'cornflowerblue': 0x6495ED,
  'cornsilk': 0xFFF8DC,
  'crimson': 0xDC143C,
  'cyan': 0x00FFFF,
  'darkblue': 0x00008B,
  'darkcyan': 0x008B8B,
  'darkgoldenrod': 0xB8860B,
  'darkgray': 0xA9A9A9,
  'darkgreen': 0x006400,
  'darkgrey': 0xA9A9A9,
  'darkkhaki': 0xBDB76B,
  'darkmagenta': 0x8B008B,
  'darkolivegreen': 0x556B2F,
  'darkorange': 0xFF8C00,
  'darkorchid': 0x9932CC,
  'darkred': 0x8B0000,
  'darksalmon': 0xE9967A,
  'darkseagreen': 0x8FBC8F,
  'darkslateblue': 0x483D8B,
  'darkslategray': 0x2F4F4F,
  'darkslategrey': 0x2F4F4F,
  'darkturquoise': 0x00CED1,
  'darkviolet': 0x9400D3,
  'deeppink': 0xFF1493,
  'deepskyblue': 0x00BFFF,
  'dimgray': 0x696969,
  'dimgrey': 0x696969,
  'dodgerblue': 0x1E90FF,
  'firebrick': 0xB22222,
  'floralwhite': 0xFFFAF0,
  'forestgreen': 0x228B22,
  'fuchsia': 0xFF00FF,
  'gainsboro': 0xDCDCDC,
  'ghostwhite': 0xF8F8FF,
  'gold': 0xFFD700,
  'goldenrod': 0xDAA520,
  'gray': 0x808080,
  'grey': 0x808080,
  'green': 0x008000,
  'greenyellow': 0xADFF2F,
  'honeydew': 0xF0FFF0,
  'hotpink': 0xFF69B4,
  'indianred': 0xCD5C5C,
  'indigo': 0x4B0082,
  'ivory': 0xFFFFF0,
  'khaki': 0xF0E68C,
  'lavender': 0xE6E6FA,
  'lavenderblush': 0xFFF0F5,
  'lawngreen': 0x7CFC00,
  'lemonchiffon': 0xFFFACD,
  'lightblue': 0xADD8E6,
  'lightcoral': 0xF08080,
  'lightcyan': 0xE0FFFF,
  'lightgoldenrodyellow': 0xFAFAD2,
  'lightgray': 0xD3D3D3,
  'lightgreen': 0x90EE90,
  'lightgrey': 0xD3D3D3,
  'lightpink': 0xFFB6C1,
  'lightsalmon': 0xFFA07A,
  'lightseagreen': 0x20B2AA,
  'lightskyblue': 0x87CEFA,
  'lightslategray': 0x778899,
  'lightslategrey': 0x778899,
  'lightsteelblue': 0xB0C4DE,
  'lightyellow': 0xFFFFE0,
  'lime': 0x00FF00,
  'limegreen': 0x32CD32,
  'linen': 0xFAF0E6,
  'magenta': 0xFF00FF,
  'maroon': 0x800000,
  'mediumaquamarine': 0x66CDAA,
  'mediumblue': 0x0000CD,
  'mediumorchid': 0xBA55D3,
  'mediumpurple': 0x9370DB,
  'mediumseagreen': 0x3CB371,
  'mediumslateblue': 0x7B68EE,
  'mediumspringgreen': 0x00FA9A,
  'mediumturquoise': 0x48D1CC,
  'mediumvioletred': 0xC71585,
  'midnightblue': 0x191970,
  'mintcream': 0xF5FFFA,
  'mistyrose': 0xFFE4E1,
  'moccasin': 0xFFE4B5,
  'navajowhite': 0xFFDEAD,
  'navy': 0x000080,
  'oldlace': 0xFDF5E6,
  'olive': 0x808000,
  'olivedrab': 0x6B8E23,
  'orange': 0xFFA500,
  'orangered': 0xFF4500,
  'orchid': 0xDA70D6,
  'palegoldenrod': 0xEEE8AA,
  'palegreen': 0x98FB98,
  'paleturquoise': 0xAFEEEE,
  'palevioletred': 0xDB7093,
  'papayawhip': 0xFFEFD5,
  'peachpuff': 0xFFDAB9,
  'peru': 0xCD853F,
  'pink': 0xFFC0CB,
  'plum': 0xDDA0DD,
  'powderblue': 0xB0E0E6,
  'purple': 0x800080,
  'rebeccapurple': 0x663399,
  'red': 0xFF0000,
  'rosybrown': 0xBC8F8F,
  'royalblue': 0x4169E1,
  'saddlebrown': 0x8B4513,
  'salmon': 0xFA8072,
  'sandybrown': 0xF4A460,
  'seagreen': 0x2E8B57,
  'seashell': 0xFFF5EE,
  'sienna': 0xA0522D,
  'silver': 0xC0C0C0,
  'skyblue': 0x87CEEB,
  'slateblue': 0x6A5ACD,
  'slategray': 0x708090,
  'slategrey': 0x708090,
  'snow': 0xFFFAFA,
  'springgreen': 0x00FF7F,
  'steelblue': 0x4682B4,
  'tan': 0xD2B48C,
  'teal': 0x008080,
  'thistle': 0xD8BFD8,
  'tomato': 0xFF6347,
  'turquoise': 0x40E0D0,
  'violet': 0xEE82EE,
  'wheat': 0xF5DEB3,
  'white': 0xFFFFFF,
  'whitesmoke': 0xF5F5F5,
  'yellow': 0xFFFF00,
  'yellowgreen': 0x9ACD32,
};
