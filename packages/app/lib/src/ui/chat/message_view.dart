import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:syntax_highlight/syntax_highlight.dart';

import '../../theme.dart';

/// Grammars bundled with syntax_highlight 0.4.x; requested via
/// [Highlighter.initialize] and matched by [detectCodeLanguage].
const List<String> _supportedGrammars = <String>['dart', 'json', 'sql', 'yaml'];

Future<bool>? _highlighterInit;
HighlighterTheme? _highlighterTheme;

/// One-time async grammar/theme load, shared by every message view. Returns
/// true when highlighting is usable; never throws.
Future<bool> _ensureHighlighter() {
  return _highlighterInit ??= _load();
}

Future<bool> _load() async {
  try {
    await Highlighter.initialize(_supportedGrammars);
    _highlighterTheme = await HighlighterTheme.loadDarkTheme();
    return true;
  } catch (_) {
    return false;
  }
}

/// Best-effort language guess for a fenced code block, restricted to the
/// grammars bundled with syntax_highlight. Returns null for anything
/// unrecognized, in which case the block stays plain.
String? detectCodeLanguage(String source) {
  final String trimmed = source.trimLeft();
  if (trimmed.isEmpty) return null;
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) return 'json';
  if (RegExp(r'^\s*[A-Za-z][A-Za-z0-9_-]*\s*:', multiLine: true)
      .hasMatch(source)) {
    return 'yaml';
  }
  if (RegExp(
    r'\b(CREATE|SELECT|INSERT|UPDATE|DELETE|ALTER|DROP)\b',
    caseSensitive: false,
  ).hasMatch(source)) {
    return 'sql';
  }
  if (RegExp(r'\b(void main|import .*dart:|class |final |const )')
      .hasMatch(source)) {
    return 'dart';
  }
  return null;
}

/// Right-aligned outgoing user message bubble.
class UserMessageBubble extends StatelessWidget {
  const UserMessageBubble({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 560),
        decoration: BoxDecoration(
          color: scheme.primary,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          text,
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: scheme.onPrimary),
        ),
      ),
    );
  }
}

/// One agent message: markdown body with syntax-highlighted code blocks.
///
/// While text is still streaming (chunk deltas arriving), code blocks render
/// as plain monospace; once the text has been stable for
/// [settleDelay], each block is highlighted once (via [Highlighter]) and the
/// resulting [TextSpan] cached in this State, keyed by the exact code text.
class AgentMessageView extends StatefulWidget {
  const AgentMessageView({super.key, required this.text});

  /// Combined (chunk-merged) markdown body text.
  final String text;

  /// How long the text must stop changing before highlighting kicks in.
  static const Duration settleDelay = Duration(milliseconds: 300);

  @override
  State<AgentMessageView> createState() => _AgentMessageViewState();
}

class _AgentMessageViewState extends State<AgentMessageView> {
  final Map<String, TextSpan> _highlightCache = <String, TextSpan>{};
  final Map<String, String?> _languageCache = <String, String?>{};

  Timer? _settleTimer;
  bool _settled = false;
  bool _highlighterReady = false;
  bool _initStarted = false;

  @override
  void initState() {
    super.initState();
    _restartSettleTimer();
  }

  @override
  void didUpdateWidget(AgentMessageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _restartSettleTimer();
    }
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    super.dispose();
  }

  void _restartSettleTimer() {
    _settleTimer?.cancel();
    _settled = false;
    _settleTimer = Timer(AgentMessageView.settleDelay, _onSettled);
  }

  void _onSettled() {
    _settled = true;
    _kickHighlighter();
    if (mounted) setState(() {});
  }

  void _kickHighlighter() {
    if (_initStarted) return;
    _initStarted = true;
    unawaited(_ensureHighlighter().then((bool ready) {
      if (!mounted) return;
      _highlighterReady = ready;
      // Re-parse the body so code blocks pick up the fresh highlighter.
      setState(() {});
    }));
  }

  /// Cached highlighted span for [code], or null while the block must stay
  /// plain (still streaming, or no usable grammar).
  TextSpan? _spanFor(String code) {
    final TextSpan? cached = _highlightCache[code];
    if (cached != null) return cached;
    if (!_settled || !_highlighterReady) return null;
    final String? language = _languageCache.putIfAbsent(
      code,
      () => detectCodeLanguage(code),
    );
    if (language == null) return null;
    try {
      final TextSpan span = Highlighter(
        language: language,
        theme: _highlighterTheme!,
      ).highlight(code);
      _highlightCache[code] = span;
      return span;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final TextStyle? bodyStyle = Theme.of(context).textTheme.bodyMedium;
    TextSpan plain(String code) =>
        TextSpan(style: context.speedDialColors.mono, text: code);

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        constraints: const BoxConstraints(maxWidth: 720),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: MarkdownBody(
          // Bump the key when highlight availability changes so the body
          // re-parses and re-runs the (cached) highlighter; data changes
          // re-parse natively.
          key: ValueKey<String>('agent-message-$_settled-$_highlighterReady'),
          data: widget.text,
          styleSheet: _styleSheetFor(context, bodyStyle),
          syntaxHighlighter: _CachingSyntaxHighlighter(this, plain),
        ),
      ),
    );
  }
}

/// Bridges this State into flutter_markdown_plus's `pre` hook. Created fresh
/// per build; [format] consults the State's settle flag + span cache. A new
/// instance per build alone does not re-parse (the body keys off data), so
/// [AgentMessageViewState] bumps the MarkdownBody key when settle/ready
/// flips.
class _CachingSyntaxHighlighter implements SyntaxHighlighter {
  _CachingSyntaxHighlighter(this._state, this._plain);

  final _AgentMessageViewState _state;
  final TextSpan Function(String code) _plain;

  @override
  TextSpan format(String source) {
    if (source.isEmpty) return const TextSpan(text: '');
    return _state._spanFor(source) ?? _plain(source);
  }
}

MarkdownStyleSheet? _cachedStyleSheet;

MarkdownStyleSheet _styleSheetFor(BuildContext context, TextStyle? bodyStyle) {
  // Static is safe only if the theme is fixed; refresh on color-scheme
  // changes by keying the cache on brightness.
  final Brightness brightness = Theme.of(context).brightness;
  if (_cachedStyleSheet == null || _cachedBrightness != brightness) {
    _cachedStyleSheet = MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: bodyStyle,
      code: context.speedDialColors.mono.copyWith(fontSize: 12.5),
      codeblockPadding: const EdgeInsets.all(10),
      blockquotePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    );
    _cachedBrightness = brightness;
  }
  return _cachedStyleSheet!;
}

Brightness? _cachedBrightness;

/// Collapsed "Thinking…" expansion tile for agent reasoning deltas.
///
/// While [active] (reasoning deltas still arriving) the icon and title pulse
/// in the primary color; once the run closes they settle to a static muted
/// "Thought" so live and finished thinking are distinguishable at a glance.
class AgentThoughtView extends StatefulWidget {
  const AgentThoughtView({super.key, required this.text, this.active = false});

  final String text;
  final bool active;

  @override
  State<AgentThoughtView> createState() => _AgentThoughtViewState();
}

class _AgentThoughtViewState extends State<AgentThoughtView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  late final Animation<double> _opacity = Tween<double>(
    begin: 0.35,
    end: 1,
  ).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut));

  @override
  void initState() {
    super.initState();
    if (widget.active) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(AgentThoughtView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _pulse.repeat(reverse: true);
    } else if (!widget.active && oldWidget.active) {
      // Settle at full opacity: one last static frame, no ticker.
      _pulse
        ..stop()
        ..value = 1;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool active = widget.active;
    final Color color =
        active ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant;
    final TextStyle italic = (theme.textTheme.bodySmall ?? const TextStyle())
        .copyWith(color: color, fontStyle: FontStyle.italic);

    final Widget leading = Icon(Icons.psychology_outlined, size: 16, color: color);
    final Widget title = Text(active ? 'Thinking…' : 'Thought', style: italic);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        dense: true,
        leading: active
            ? FadeTransition(
                key: const ValueKey<String>('thought-pulse'),
                opacity: _opacity,
                child: leading,
              )
            : leading,
        title: active
            ? FadeTransition(
                key: const ValueKey<String>('thought-pulse'),
                opacity: _opacity,
                child: title,
              )
            : title,
        children: <Widget>[
          Text(
            widget.text,
            style: italic.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
