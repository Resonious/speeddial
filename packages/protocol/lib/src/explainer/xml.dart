/// Minimal XML reader for the explainer SVG subset: elements, attributes,
/// text, CDATA, comments, and the five predefined plus numeric entities.
/// No namespaces, DTDs, or processing beyond skipping them.
library;

sealed class XmlNode {
  const XmlNode();
}

class XmlElement extends XmlNode {
  XmlElement(this.name, this.attributes, this.line);

  final String name;
  final Map<String, String> attributes;
  final List<XmlNode> children = <XmlNode>[];

  /// 1-based source line of the start tag, for error messages.
  final int line;
}

class XmlText extends XmlNode {
  const XmlText(this.text);
  final String text;
}

class XmlParseException implements Exception {
  const XmlParseException(this.message, this.line);
  final String message;
  final int line;

  @override
  String toString() => 'line $line: $message';
}

/// Deepest element nesting accepted; deeper input is rejected rather than
/// risking the stack.
const int kMaxXmlDepth = 64;

/// Parses [source] and returns its single root element.
XmlElement parseXml(String source) => _XmlReader(source).document();

class _XmlReader {
  _XmlReader(this._s);

  final String _s;
  int _i = 0;
  int _depth = 0;

  // The read position only moves forward, so lines are counted incrementally.
  int _counted = 0;
  int _lines = 1;

  int get _line {
    final int end = _i < _s.length ? _i : _s.length;
    for (; _counted < end; _counted++) {
      if (_s.codeUnitAt(_counted) == 0x0A) _lines++;
    }
    return _lines;
  }

  Never _fail(String message) => throw XmlParseException(message, _line);

  bool _startsWith(String prefix) => _s.startsWith(prefix, _i);

  void _skipUntil(String terminator, String what) {
    final int end = _s.indexOf(terminator, _i);
    if (end < 0) _fail('unterminated $what');
    _i = end + terminator.length;
  }

  void _skipMisc() {
    while (true) {
      _skipSpace();
      if (_startsWith('<?')) {
        _skipUntil('?>', 'processing instruction');
      } else if (_startsWith('<!--')) {
        _skipUntil('-->', 'comment');
      } else if (_startsWith('<!DOCTYPE') || _startsWith('<!doctype')) {
        _skipUntil('>', 'doctype');
      } else {
        return;
      }
    }
  }

  XmlElement document() {
    _skipMisc();
    if (!_startsWith('<')) _fail('expected a root element');
    final XmlElement root = _element();
    _skipMisc();
    if (_i < _s.length) _fail('unexpected content after the root element');
    return root;
  }

  void _skipSpace() {
    while (_i < _s.length && _isSpace(_s.codeUnitAt(_i))) {
      _i++;
    }
  }

  static bool _isSpace(int c) =>
      c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;

  static bool _isNameChar(int c) =>
      (c >= 0x61 && c <= 0x7A) || // a-z
      (c >= 0x41 && c <= 0x5A) || // A-Z
      (c >= 0x30 && c <= 0x39) || // 0-9
      c == 0x2D || // -
      c == 0x5F || // _
      c == 0x3A || // :
      c == 0x2E; // .

  String _name() {
    final int start = _i;
    while (_i < _s.length && _isNameChar(_s.codeUnitAt(_i))) {
      _i++;
    }
    if (_i == start) _fail('expected a name');
    return _s.substring(start, _i);
  }

  XmlElement _element() {
    if (++_depth > kMaxXmlDepth) {
      _fail('elements are nested more than $kMaxXmlDepth deep');
    }
    try {
      return _elementBody();
    } finally {
      _depth--;
    }
  }

  XmlElement _elementBody() {
    final int line = _line;
    _i++; // <
    final String name = _name();
    final Map<String, String> attributes = <String, String>{};
    while (true) {
      _skipSpace();
      if (_i >= _s.length) _fail('unterminated <$name> tag');
      if (_startsWith('/>')) {
        _i += 2;
        return XmlElement(name, attributes, line);
      }
      if (_startsWith('>')) {
        _i++;
        break;
      }
      final String attribute = _name();
      _skipSpace();
      if (!_startsWith('=')) _fail('attribute $attribute needs a value');
      _i++;
      _skipSpace();
      if (_i >= _s.length) _fail('unterminated <$name> tag');
      final String quote = _s[_i];
      if (quote != '"' && quote != "'") {
        _fail('attribute $attribute value must be quoted');
      }
      _i++;
      final int end = _s.indexOf(quote, _i);
      if (end < 0) _fail('unterminated value for attribute $attribute');
      if (attributes.containsKey(attribute)) {
        _fail('duplicate attribute $attribute on <$name>');
      }
      attributes[attribute] = _decode(_s.substring(_i, end));
      _i = end + 1;
    }
    final XmlElement element = XmlElement(name, attributes, line);
    final StringBuffer text = StringBuffer();
    void flushText() {
      if (text.isEmpty) return;
      element.children.add(XmlText(text.toString()));
      text.clear();
    }

    while (true) {
      if (_i >= _s.length) _fail('<$name> is never closed');
      if (_startsWith('</')) {
        flushText();
        _i += 2;
        final String closing = _name();
        if (closing != name) _fail('</$closing> does not close <$name>');
        _skipSpace();
        if (!_startsWith('>')) _fail('malformed </$closing>');
        _i++;
        return element;
      }
      if (_startsWith('<!--')) {
        _skipUntil('-->', 'comment');
      } else if (_startsWith('<![CDATA[')) {
        final int start = _i + 9;
        _skipUntil(']]>', 'CDATA section');
        text.write(_s.substring(start, _i - 3));
      } else if (_startsWith('<?')) {
        _skipUntil('?>', 'processing instruction');
      } else if (_startsWith('<')) {
        flushText();
        element.children.add(_element());
      } else {
        final int start = _i;
        final int next = _s.indexOf('<', _i);
        _i = next < 0 ? _s.length : next;
        text.write(_decode(_s.substring(start, _i)));
      }
    }
  }

  String _decode(String raw) {
    if (!raw.contains('&')) return raw;
    final StringBuffer out = StringBuffer();
    int k = 0;
    while (k < raw.length) {
      final int amp = raw.indexOf('&', k);
      if (amp < 0) {
        out.write(raw.substring(k));
        break;
      }
      out.write(raw.substring(k, amp));
      final int semi = raw.indexOf(';', amp);
      if (semi < 0) _fail('unterminated entity');
      final String entity = raw.substring(amp + 1, semi);
      out.write(switch (entity) {
        'lt' => '<',
        'gt' => '>',
        'amp' => '&',
        'quot' => '"',
        'apos' => "'",
        'nbsp' => ' ',
        _ when entity.startsWith('#x') || entity.startsWith('#X') => _codePoint(
          entity.substring(2),
          16,
          entity,
        ),
        _ when entity.startsWith('#') => _codePoint(
          entity.substring(1),
          10,
          entity,
        ),
        _ => _fail('unknown entity &$entity;'),
      });
      k = semi + 1;
    }
    return out.toString();
  }

  String _codePoint(String digits, int radix, String entity) {
    final int? value = int.tryParse(digits, radix: radix);
    if (value == null || value < 0 || value > 0x10FFFF) {
      _fail('bad character reference &$entity;');
    }
    return String.fromCharCode(value);
  }
}
