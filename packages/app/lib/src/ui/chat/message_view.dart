import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:syntax_highlight/syntax_highlight.dart';

import '../../theme.dart';
import 'active_pulse.dart';
import 'external_link_launcher.dart';

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
  if (RegExp(
    r'^\s*[A-Za-z][A-Za-z0-9_-]*\s*:',
    multiLine: true,
  ).hasMatch(source)) {
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
///
/// Attachments render above the text: images as ~160px thumbnails (payload
/// fetched through [attachmentLoader] and opened full-screen on tap),
/// everything else as a compact file row. When the text is empty the Text is
/// omitted entirely and the bubble shows just the attachments.
class UserMessageBubble extends StatelessWidget {
  const UserMessageBubble({
    super.key,
    required this.text,
    this.attachments = const <Attachment>[],
    this.attachmentLoader,
  });

  final String text;

  /// Files attached to the message (metadata only; ids address the daemon).
  final List<Attachment> attachments;

  /// Fetches an attachment's payload by id; when null, attachments render as
  /// static chips without loading (defensive default).
  final Future<AttachmentData> Function(String attachmentId)? attachmentLoader;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool hasText = text.isNotEmpty;
    final List<Widget> content = <Widget>[
      if (hasText)
        Text(
          text,
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: scheme.onPrimary),
        ),
      if (attachments.isNotEmpty) ...<Widget>[
        if (hasText) const SizedBox(height: 8),
        for (final Attachment attachment in attachments)
          AttachmentView(attachment: attachment, loader: attachmentLoader),
      ],
    ];
    return Align(
      alignment: Alignment.centerRight,
      widthFactor: 1,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 560),
        decoration: BoxDecoration(
          color: scheme.primary,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: content,
        ),
      ),
    );
  }
}

/// One rendered attachment: image thumbnails fetch and decode their payload;
/// other types render a compact icon+name+size row.
class AttachmentView extends StatelessWidget {
  const AttachmentView({
    super.key,
    required this.attachment,
    required this.loader,
  });

  final Attachment attachment;

  /// See [UserMessageBubble.attachmentLoader].
  final Future<AttachmentData> Function(String attachmentId)? loader;

  @override
  Widget build(BuildContext context) {
    if (!isImageMimeType(attachment.mimeType)) {
      // No payload needed; a loader is irrelevant here.
      return _AttachmentMetaRow(attachment: attachment);
    }
    final Future<AttachmentData> Function(String attachmentId)? load = loader;
    if (load == null) {
      // Defensive: metadata chip without loading bytes.
      return _AttachmentMetaRow(attachment: attachment);
    }
    return FutureBuilder<AttachmentData>(
      future: load(attachment.id),
      builder: (BuildContext context, AsyncSnapshot<AttachmentData> snapshot) {
        final AttachmentData? data = snapshot.data;
        if (data == null) {
          // Loading (or failed): a small placeholder box.
          return _ImageThumbPlaceholder(attachment: attachment);
        }
        return _ImageThumbnail(attachment: data);
      },
    );
  }
}

/// Compact file row: icon by type, name, formatted size.
class _AttachmentMetaRow extends StatelessWidget {
  const _AttachmentMetaRow({required this.attachment});

  final Attachment attachment;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool pdf = attachment.mimeType.toLowerCase() == 'application/pdf';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Icon(
            pdf
                ? Icons.picture_as_pdf_outlined
                : Icons.insert_drive_file_outlined,
            size: 16,
            color: theme.colorScheme.onPrimary,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              attachment.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onPrimary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _formatSize(attachment.size),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Loading placeholder for an image thumb whose payload is still arriving.
class _ImageThumbPlaceholder extends StatelessWidget {
  const _ImageThumbPlaceholder({required this.attachment});

  final Attachment attachment;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      width: 160,
      height: 160,
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.image_outlined, color: theme.colorScheme.onPrimary),
            const SizedBox(height: 4),
            Text(
              attachment.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A decoded image thumb; tapping opens it full-screen (zooming via
/// [InteractiveViewer]).
class _ImageThumbnail extends StatelessWidget {
  const _ImageThumbnail({required this.attachment});

  final AttachmentData attachment;

  @override
  Widget build(BuildContext context) {
    final Uint8List bytes;
    try {
      bytes = base64Decode(attachment.data);
    } on FormatException {
      // Malformed payload from the daemon: degrade to the metadata row.
      return _AttachmentMetaRow(attachment: attachment);
    }
    return GestureDetector(
      onTap: () => _showImageDialog(context, bytes, attachment.name),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(
          bytes,
          width: 160,
          height: 160,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (
            BuildContext context,
            Object error,
            StackTrace? stackTrace,
          ) => _AttachmentMetaRow(attachment: attachment),
        ),
      ),
    );
  }
}

/// Full-screen dialog with the image, pan/zoom via [InteractiveViewer].
void _showImageDialog(BuildContext context, Uint8List bytes, String name) {
  showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => Dialog.fullscreen(
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: InteractiveViewer(
              child: Center(
                child: Image.memory(
                  bytes,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                ),
              ),
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: IconButton(
              tooltip: 'Close',
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Formats [size] bytes compactly: B, KiB, or MiB (one decimal below 10).
String _formatSize(int size) {
  const int kib = 1024;
  const int mib = 1024 * 1024;
  if (size < kib) return '$size B';
  if (size < mib) {
    final double value = size / kib;
    return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} KiB';
  }
  final double value = size / mib;
  return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} MiB';
}

Future<bool> _launchExternal(Uri uri) => launchExternalLink(uri);

/// Returns the daemon-side path represented by a non-web markdown [href].
///
/// File URIs, absolute paths, and cwd-relative paths are supported. Codex's
/// clickable-file convention appends `:line[:column]`; that location suffix
/// is removed because the host application opens the downloaded file itself.
String? localFilePathFromHref(String href) {
  if (href.isEmpty || href.startsWith('#') || href.startsWith('//')) {
    return null;
  }
  String path;
  final bool windowsPath = RegExp(r'^[A-Za-z]:[/\\]').hasMatch(href);
  if (windowsPath) {
    path = href;
  } else {
    final Uri? uri = Uri.tryParse(href);
    if (uri == null || uri.scheme == 'http' || uri.scheme == 'https') {
      return null;
    }
    if (uri.scheme.isNotEmpty && uri.scheme != 'file') return null;
    path = Uri.decodeComponent(uri.path);
    if (uri.scheme == 'file' && uri.host.isNotEmpty) {
      path = '//${uri.host}$path';
    } else if (uri.scheme == 'file' && RegExp(r'^/[A-Za-z]:/').hasMatch(path)) {
      path = path.substring(1);
    }
  }
  path = path.replaceFirst(RegExp(r':\d+(?::\d+)?$'), '');
  return path.isEmpty ? null : path;
}

/// One agent message: markdown body with syntax-highlighted code blocks.
///
/// While text is still streaming (chunk deltas arriving), code blocks render
/// as plain monospace; once the text has been stable for
/// [settleDelay], each block is highlighted once (via [Highlighter]) and the
/// resulting [TextSpan] cached in this State, keyed by the exact code text.
class AgentMessageView extends StatefulWidget {
  const AgentMessageView({
    super.key,
    required this.text,
    this.launchExternal = _launchExternal,
    this.openLocalFile,
  });

  /// Combined (chunk-merged) markdown body text.
  final String text;

  /// Opens an external URI when a markdown link is activated.
  ///
  /// Injected in tests so link activation does not touch the host platform.
  final Future<bool> Function(Uri uri) launchExternal;

  /// Downloads and opens a daemon-local file path. Production supplies this
  /// from the selected session; standalone views may leave it null.
  final Future<void> Function(String path)? openLocalFile;

  /// How long the text must stop changing before highlighting kicks in.
  static const Duration settleDelay = Duration(milliseconds: 300);

  @override
  State<AgentMessageView> createState() => _AgentMessageViewState();
}

class _AgentMessageViewState extends State<AgentMessageView> {
  final Map<String, TextSpan> _highlightCache = <String, TextSpan>{};
  final Map<String, String?> _languageCache = <String, String?>{};
  late final Map<String, MarkdownElementBuilder> _elementBuilders;

  Timer? _settleTimer;
  bool _settled = false;
  bool _highlighterReady = false;
  bool _initStarted = false;

  @override
  void initState() {
    super.initState();
    _elementBuilders = <String, MarkdownElementBuilder>{
      'a': _LinkElementBuilder(onActivate: _activateLink),
    };
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
    unawaited(
      _ensureHighlighter().then((bool ready) {
        if (!mounted) return;
        _highlighterReady = ready;
        // Re-parse the body so code blocks pick up the fresh highlighter.
        setState(() {});
      }),
    );
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

  void _activateLink(String href) {
    final Uri? uri = Uri.tryParse(href);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      unawaited(_openExternal(uri));
      return;
    }
    final String? path = localFilePathFromHref(href);
    final Future<void> Function(String path)? opener = widget.openLocalFile;
    if (path != null && opener != null) unawaited(opener(path));
  }

  Future<void> _openExternal(Uri uri) async {
    bool opened = false;
    try {
      opened = await widget.launchExternal(uri);
    } catch (_) {
      // The failure is reported in the UI below.
    }
    if (opened || !mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('Could not open URL. Right-click it to copy the URL.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final TextStyle? bodyStyle = Theme.of(context).textTheme.bodyMedium;
    TextSpan plain(String code) =>
        TextSpan(style: context.speedDialColors.mono, text: code);

    return Align(
      alignment: Alignment.centerLeft,
      widthFactor: 1,
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
          builders: _elementBuilders,
        ),
      ),
    );
  }
}

class _LinkElementBuilder extends MarkdownElementBuilder {
  _LinkElementBuilder({required this.onActivate});

  final void Function(String href) onActivate;

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final String label = element.textContent;
    final String? href = element.attributes['href'];
    final TextStyle? style =
        parentStyle?.merge(preferredStyle) ?? preferredStyle;
    if (href == null || href.isEmpty) return Text(label, style: style);
    return _MarkdownLink(
      label: label,
      href: href,
      style: style,
      onActivate: () => onActivate(href),
    );
  }
}

enum _LinkMenuAction { copyUrl }

class _MarkdownLink extends StatelessWidget {
  const _MarkdownLink({
    required this.label,
    required this.href,
    required this.style,
    required this.onActivate,
  });

  final String label;
  final String href;
  final TextStyle? style;
  final VoidCallback onActivate;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      link: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onActivate,
          onSecondaryTapDown: (TapDownDetails details) {
            unawaited(_showContextMenu(context, details.globalPosition));
          },
          child: Text(label, style: style),
        ),
      ),
    );
  }

  Future<void> _showContextMenu(
    BuildContext context,
    Offset globalPosition,
  ) async {
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    final RenderBox overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final Offset position = overlay.globalToLocal(globalPosition);
    final _LinkMenuAction? action = await showMenu<_LinkMenuAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        overlay.size.width - position.dx,
        overlay.size.height - position.dy,
      ),
      items: const <PopupMenuEntry<_LinkMenuAction>>[
        PopupMenuItem<_LinkMenuAction>(
          value: _LinkMenuAction.copyUrl,
          child: Row(
            children: <Widget>[
              Icon(Icons.content_copy, size: 18),
              SizedBox(width: 8),
              Text('Copy URL'),
            ],
          ),
        ),
      ],
    );
    if (action != _LinkMenuAction.copyUrl) return;
    await Clipboard.setData(ClipboardData(text: href));
    if (messenger == null || !messenger.mounted) return;
    messenger.showSnackBar(const SnackBar(content: Text('URL copied')));
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
    _cachedStyleSheet = MarkdownStyleSheet.fromTheme(Theme.of(context))
        .copyWith(
          p: bodyStyle,
          code: context.speedDialColors.mono.copyWith(fontSize: 12.5),
          codeblockPadding: const EdgeInsets.all(10),
          blockquotePadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 4,
          ),
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
class AgentThoughtView extends StatelessWidget {
  const AgentThoughtView({super.key, required this.text, this.active = false});

  final String text;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color color = active
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    final TextStyle italic = (theme.textTheme.bodySmall ?? const TextStyle())
        .copyWith(color: color, fontStyle: FontStyle.italic);

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
        leading: ActivePulse(
          active: active,
          pulseKey: const ValueKey<String>('thought-pulse'),
          child: Icon(Icons.psychology_outlined, size: 16, color: color),
        ),
        title: ActivePulse(
          active: active,
          pulseKey: const ValueKey<String>('thought-pulse'),
          child: Text(active ? 'Thinking…' : 'Thought', style: italic),
        ),
        children: <Widget>[
          Text(
            text,
            style: italic.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
