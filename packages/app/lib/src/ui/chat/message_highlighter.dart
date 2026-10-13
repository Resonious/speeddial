import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:syntax_highlight/syntax_highlight.dart';

/// Bounded, shared cache so scrolling a completed message back into view does
/// not repeat tokenization. Native tokenization runs off the UI isolate, in
/// serialized batches rather than spawning a worker for every code block.
class MessageHighlighter {
  static final MessageHighlighter instance = MessageHighlighter();
  static const int maxBlockLength = 8000;
  static const int maxBatchLength = 32000;
  static const int _maxCacheLength = 256000;

  Future<void>? _initializing;
  late HighlighterTheme _lightTheme;
  late HighlighterTheme _darkTheme;
  Future<void> _queue = Future<void>.value();
  final LinkedHashMap<(Brightness, Color, String, String), TextSpan> _cache =
      LinkedHashMap<(Brightness, Color, String, String), TextSpan>();
  int _cachedLength = 0;

  Future<void> _initialize() async {
    await Highlighter.initialize(<String>['dart', 'json', 'sql', 'yaml']);
    _lightTheme = await HighlighterTheme.loadLightTheme();
    _darkTheme = await HighlighterTheme.loadDarkTheme();
  }

  Future<Map<String, TextSpan>> highlight(
    Map<String, String> languages, {
    required Brightness brightness,
    required Color background,
    bool Function()? isCurrent,
  }) {
    final Future<Map<String, TextSpan>> result = _queue.then((_) async {
      if (languages.isEmpty || isCurrent?.call() == false) {
        return <String, TextSpan>{};
      }
      await (_initializing ??= _initialize());
      if (isCurrent?.call() == false) return <String, TextSpan>{};
      final Map<String, TextSpan> spans = <String, TextSpan>{};
      final List<(String, Highlighter, Color)> jobs =
          <(String, Highlighter, Color)>[];
      final HighlighterTheme theme = brightness == Brightness.light
          ? _lightTheme
          : _darkTheme;
      int length = 0;
      for (final MapEntry<String, String> entry in languages.entries) {
        final String code = entry.key;
        // Web compute runs on the main thread; use a smaller work limit there.
        if (code.length > (kIsWeb ? 2000 : maxBlockLength)) continue;
        if (length + code.length > maxBatchLength) continue;
        length += code.length;
        final (Brightness, Color, String, String) key = (
          brightness,
          background,
          entry.value,
          code,
        );
        final TextSpan? cached = _cache.remove(key);
        if (cached != null) {
          _cache[key] = cached;
          spans[code] = cached;
        } else {
          jobs.add((
            code,
            Highlighter(language: entry.value, theme: theme),
            background,
          ));
        }
      }
      if (jobs.isNotEmpty) {
        final Map<String, TextSpan> fresh = await compute(
          _highlightBatch,
          jobs,
          debugLabel: 'chat syntax highlighting',
        );
        spans.addAll(fresh);
        for (final MapEntry<String, TextSpan> entry in fresh.entries) {
          _cache[(brightness, background, languages[entry.key]!, entry.key)] =
              entry.value;
          _cachedLength += entry.key.length;
        }
        while (_cachedLength > _maxCacheLength || _cache.length > 128) {
          final (Brightness, Color, String, String) oldest = _cache.keys.first;
          _cachedLength -= oldest.$4.length;
          _cache.remove(oldest);
        }
      }
      return spans;
    });
    // Keep later requests usable if an asset or worker fails. The requesting
    // widget receives the original error and keeps its readable plain code.
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

Map<String, TextSpan> _highlightBatch(List<(String, Highlighter, Color)> jobs) {
  return <String, TextSpan>{
    for (final (String code, Highlighter highlighter, Color background) in jobs)
      code: _readableSpan(highlighter.highlight(code), background),
  };
}

// The library's bracket palette is fixed, even in its light theme. Correct
// low-contrast colors once in the worker, before caching the styled spans.
TextSpan _readableSpan(TextSpan span, Color background) {
  final Color? color = span.style?.color;
  return TextSpan(
    text: span.text,
    style: color == null
        ? span.style
        : span.style!.copyWith(color: _readableColor(color, background)),
    children: span.children
        ?.map(
          (InlineSpan child) => _readableSpan(child as TextSpan, background),
        )
        .toList(),
  );
}

Color _readableColor(Color color, Color background) {
  final double surface = background.computeLuminance();
  double contrast(Color foreground) {
    final double ink = foreground.computeLuminance();
    return ink > surface
        ? (ink + 0.05) / (surface + 0.05)
        : (surface + 0.05) / (ink + 0.05);
  }

  if (contrast(color) >= 4.5) return color;
  final Color target = surface > 0.179
      ? const Color(0xff000000)
      : const Color(0xffffffff);
  double low = 0;
  double high = 1;
  for (int i = 0; i < 12; i++) {
    final double middle = (low + high) / 2;
    if (contrast(Color.lerp(color, target, middle)!) >= 4.5) {
      high = middle;
    } else {
      low = middle;
    }
  }
  return Color.lerp(color, target, high)!;
}
