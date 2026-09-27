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
  late HighlighterTheme _theme;
  Future<void> _queue = Future<void>.value();
  final LinkedHashMap<String, TextSpan> _cache =
      LinkedHashMap<String, TextSpan>();
  int _cachedLength = 0;

  Future<void> _initialize() async {
    await Highlighter.initialize(<String>['dart', 'json', 'sql', 'yaml']);
    _theme = await HighlighterTheme.loadDarkTheme();
  }

  Future<Map<String, TextSpan>> highlight(
    Map<String, String> languages, {
    bool Function()? isCurrent,
  }) {
    final Future<Map<String, TextSpan>> result = _queue.then((_) async {
      if (languages.isEmpty || isCurrent?.call() == false) {
        return <String, TextSpan>{};
      }
      await (_initializing ??= _initialize());
      if (isCurrent?.call() == false) return <String, TextSpan>{};
      final Map<String, TextSpan> spans = <String, TextSpan>{};
      final List<(String, Highlighter)> jobs = <(String, Highlighter)>[];
      int length = 0;
      for (final MapEntry<String, String> entry in languages.entries) {
        final String code = entry.key;
        // Web compute runs on the main thread; use a smaller work limit there.
        if (code.length > (kIsWeb ? 2000 : maxBlockLength)) continue;
        if (length + code.length > maxBatchLength) continue;
        length += code.length;
        final TextSpan? cached = _cache.remove(code);
        if (cached != null) {
          _cache[code] = cached;
          spans[code] = cached;
        } else {
          jobs.add((code, Highlighter(language: entry.value, theme: _theme)));
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
          _cache[entry.key] = entry.value;
          _cachedLength += entry.key.length;
        }
        while (_cachedLength > _maxCacheLength || _cache.length > 128) {
          final String oldest = _cache.keys.first;
          _cachedLength -= oldest.length;
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

Map<String, TextSpan> _highlightBatch(List<(String, Highlighter)> jobs) {
  return <String, TextSpan>{
    for (final (String code, Highlighter highlighter) in jobs)
      code: highlighter.highlight(code),
  };
}
