import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../theme.dart';
import 'active_pulse.dart';
import 'external_link_launcher.dart';
import 'history_expansion.dart';
import 'message_highlighter.dart';
import 'mermaid/mermaid_diagram.dart';
import 'mermaid/mermaid_parser.dart';
import 'writing_sparks.dart';

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

  /// Space between the bubble and the edges of the widget.
  static const EdgeInsets margin = EdgeInsets.symmetric(
    vertical: 4,
    horizontal: 8,
  );

  /// The bubble's outline: squared corner toward the sender, like a speech
  /// tail.
  static const BorderRadius radius = BorderRadius.only(
    topLeft: Radius.circular(14),
    topRight: Radius.circular(14),
    bottomLeft: Radius.circular(14),
    bottomRight: Radius.circular(4),
  );

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool hasText = text.isNotEmpty;
    final List<Widget> content = <Widget>[
      if (hasText)
        Text(
          text,
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: scheme.onPrimaryContainer),
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
        margin: margin,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 560),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: radius,
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
            color: theme.colorScheme.onPrimaryContainer,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              attachment.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _formatSize(attachment.size),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onPrimaryContainer,
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
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.image_outlined,
              color: theme.colorScheme.onPrimaryContainer,
            ),
            const SizedBox(height: 4),
            Text(
              attachment.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
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
/// [settleDelay] after streaming ends, bounded code blocks are highlighted
/// off the UI isolate on native platforms and cached across message views.
class AgentMessageView extends StatefulWidget {
  const AgentMessageView({
    super.key,
    required this.text,
    this.streaming = false,
    this.launchExternal = _launchExternal,
    this.openLocalFile,
  });

  /// Combined (chunk-merged) markdown body text.
  final String text;

  /// Whether the containing turn is still producing output.
  final bool streaming;

  /// Opens an external URI when a markdown link is activated.
  ///
  /// Injected in tests so link activation does not touch the host platform.
  final Future<bool> Function(Uri uri) launchExternal;

  /// Downloads and opens a daemon-local file path. Production supplies this
  /// from the selected session; standalone views may leave it null.
  final Future<void> Function(String path)? openLocalFile;

  /// How long the text must stop changing before highlighting kicks in.
  static const Duration streamRenderInterval = Duration(milliseconds: 100);

  static const Duration settleDelay = Duration(milliseconds: 300);

  @override
  State<AgentMessageView> createState() => _AgentMessageViewState();
}

class _AgentMessageViewState extends State<AgentMessageView> {
  final Map<String, TextSpan> _highlightCache = <String, TextSpan>{};
  final Set<String> _codeBlocks = <String>{};

  /// Mermaid sources the user switched to the code view; survives the
  /// markdown rebuild that a highlight batch triggers.
  final Set<String> _mermaidSourceShown = <String>{};
  late String _renderedText;

  /// Times streamed text grew on screen; each one lights [WritingSparks].
  int _writes = 0;
  Timer? _renderTimer;
  int _highlightRevision = 0;
  final _MessageSelectionDelegate _selectionDelegate =
      _MessageSelectionDelegate();
  late final Map<String, MarkdownElementBuilder> _elementBuilders;

  Timer? _settleTimer;

  @override
  void initState() {
    super.initState();
    _renderedText = widget.text;
    _elementBuilders = <String, MarkdownElementBuilder>{
      'a': _LinkElementBuilder(onActivate: _activateLink),
      'pre': _CodeBlockBuilder(this),
    };
    _restartSettleTimer();
  }

  @override
  void didUpdateWidget(AgentMessageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.streaming != widget.streaming) {
      if (!widget.streaming ||
          !oldWidget.streaming ||
          !widget.text.startsWith(oldWidget.text)) {
        _renderTimer?.cancel();
        _renderTimer = null;
        _setRenderedText();
      } else if (_renderedText != widget.text) {
        _renderTimer ??= Timer(AgentMessageView.streamRenderInterval, () {
          _renderTimer = null;
          if (mounted) setState(_setRenderedText);
        });
      }
      _restartSettleTimer();
    }
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    _renderTimer?.cancel();
    _selectionDelegate.dispose();
    super.dispose();
  }

  void _setRenderedText() {
    if (_renderedText == widget.text) return;
    if (widget.streaming && widget.text.length > _renderedText.length) {
      _writes++;
    }
    _renderedText = widget.text;
    _codeBlocks.clear();
    _highlightCache.clear();
  }

  void _restartSettleTimer() {
    _settleTimer?.cancel();
    if (widget.streaming) return;
    _settleTimer = Timer(AgentMessageView.settleDelay, _highlight);
  }

  Future<void> _highlight() async {
    final String text = _renderedText;
    final Map<String, String> languages = <String, String>{};
    for (final String code in _codeBlocks) {
      if (code.length > MessageHighlighter.maxBlockLength) continue;
      final String? language = detectCodeLanguage(code);
      if (language != null) languages[code] = language;
    }
    if (languages.isEmpty) return;
    try {
      final Map<String, TextSpan> spans = await MessageHighlighter.instance
          .highlight(
            languages,
            isCurrent: () =>
                mounted && !widget.streaming && widget.text == text,
          );
      if (!mounted ||
          widget.streaming ||
          widget.text != text ||
          spans.isEmpty) {
        return;
      }
      setState(() {
        _highlightCache.addAll(spans);
        _highlightRevision++;
      });
    } on Object {
      // Highlighting is optional; the full selectable code stays visible.
    }
  }

  /// Markdown's synchronous hook only collects blocks and reads cached spans.
  TextSpan? _spanFor(String code) {
    _codeBlocks.add(code);
    return _highlightCache[code];
  }

  /// Whether [code]'s fence has closed. While streaming, the trailing block
  /// may still be growing; drawing it would flicker between diagram and
  /// fallback with every chunk.
  bool _fenceClosed(String code) {
    if (!widget.streaming) return true;
    final int at = _renderedText.lastIndexOf(code);
    if (at < 0) return false;
    return _closingFence.hasMatch(_renderedText.substring(at + code.length));
  }

  static final RegExp _closingFence = RegExp(r'^\s*(```|~~~)', multiLine: true);

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

    return Align(
      alignment: Alignment.centerLeft,
      widthFactor: 1,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        constraints: const BoxConstraints(maxWidth: 720),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(4),
            topRight: Radius.circular(14),
            bottomLeft: Radius.circular(14),
            bottomRight: Radius.circular(14),
          ),
          border: Border.all(color: context.speedDialColors.border),
        ),
        child: WritingSparks(
          writes: _writes,
          child: SelectionContainer(
            delegate: _selectionDelegate,
            child: MarkdownBody(
              // Reparse once when an asynchronous highlight batch is ready.
              key: ValueKey<int>(_highlightRevision),
              data: _renderedText,
              styleSheet: _styleSheetFor(context, bodyStyle),
              builders: _elementBuilders,
            ),
          ),
        ),
      ),
    );
  }
}

/// Keeps code scrolling while making the selected characters visible over
/// syntax-colored text. Markdown's default code block only paints the
/// selection behind that text.
class _CodeBlockBuilder extends MarkdownElementBuilder {
  _CodeBlockBuilder(this._message);

  final _AgentMessageViewState _message;

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final String code = element.textContent.replaceFirst(RegExp(r'\n$'), '');
    final MarkdownStyleSheet styleSheet = _styleSheetFor(
      context,
      Theme.of(context).textTheme.bodyMedium,
    );
    final Widget codeBlock = _CodeBlock(
      span: _message._spanFor(code) ?? TextSpan(text: code),
      padding: styleSheet.codeblockPadding ?? EdgeInsets.zero,
      textStyle: styleSheet.code ?? context.speedDialColors.mono,
    );
    if (!_isMermaid(element, code) || !_message._fenceClosed(code)) {
      return codeBlock;
    }
    final FlowGraph? graph = cachedMermaidGraph(code);
    if (graph == null) return codeBlock;
    return _MermaidBlock(
      graph: graph,
      codeBlock: codeBlock,
      showSource: _message._mermaidSourceShown.contains(code),
      onShowSourceChanged: (bool shown) {
        if (shown) {
          _message._mermaidSourceShown.add(code);
        } else {
          _message._mermaidSourceShown.remove(code);
        }
      },
    );
  }

  /// A `mermaid` fence, or an untagged fence that starts like a flowchart.
  bool _isMermaid(md.Element pre, String code) {
    final List<md.Node>? children = pre.children;
    final md.Node? first = children == null || children.isEmpty
        ? null
        : children.first;
    final String? language = first is md.Element
        ? first.attributes['class']
        : null;
    if (language == null) return looksLikeMermaidFlowchart(code);
    return language == 'language-mermaid';
  }
}

/// A rendered Mermaid diagram with a toggle back to its source.
class _MermaidBlock extends StatefulWidget {
  const _MermaidBlock({
    required this.graph,
    required this.codeBlock,
    required this.showSource,
    required this.onShowSourceChanged,
  });

  final FlowGraph graph;
  final Widget codeBlock;
  final bool showSource;
  final ValueChanged<bool> onShowSourceChanged;

  @override
  State<_MermaidBlock> createState() => _MermaidBlockState();
}

class _MermaidBlockState extends State<_MermaidBlock> {
  late bool _showSource = widget.showSource;

  void _toggle() {
    setState(() => _showSource = !_showSource);
    widget.onShowSourceChanged(_showSource);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurfaceVariant;
    const VisualDensity dense = VisualDensity(horizontal: -4, vertical: -4);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 2, 2, 0),
          child: Row(
            children: <Widget>[
              Text(
                'mermaid',
                style: context.speedDialColors.mono.copyWith(
                  fontSize: 11,
                  color: muted,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: _showSource ? 'Show diagram' : 'Show source',
                visualDensity: dense,
                iconSize: 16,
                color: muted,
                icon: Icon(
                  _showSource ? Icons.account_tree_outlined : Icons.code,
                ),
                onPressed: _toggle,
              ),
              if (!_showSource)
                IconButton(
                  tooltip: 'Expand diagram',
                  visualDensity: dense,
                  iconSize: 16,
                  color: muted,
                  icon: const Icon(Icons.open_in_full),
                  onPressed: () => showMermaidViewer(context, widget.graph),
                ),
            ],
          ),
        ),
        if (_showSource)
          widget.codeBlock
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: MermaidDiagram(graph: widget.graph),
          ),
      ],
    );
  }
}

class _CodeBlock extends StatefulWidget {
  const _CodeBlock({
    required this.span,
    required this.padding,
    required this.textStyle,
  });

  final TextSpan span;
  final EdgeInsetsGeometry padding;
  final TextStyle textStyle;

  @override
  State<_CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<_CodeBlock> {
  final SelectionListenerNotifier _selection = SelectionListenerNotifier();
  final GlobalKey _paragraphKey = GlobalKey();

  @override
  void dispose() {
    _selection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color accent = Theme.of(context).colorScheme.primary;
    return SelectionListener(
      selectionNotifier: _selection,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: widget.padding,
        child: Builder(
          builder: (BuildContext context) => CustomPaint(
            foregroundPainter: _CodeSelectionPainter(
              notifier: _selection,
              paragraphKey: _paragraphKey,
              color: accent.withValues(alpha: 0.35),
            ),
            child: RichText(
              key: _paragraphKey,
              text: TextSpan(
                style: widget.textStyle,
                children: <InlineSpan>[widget.span],
              ),
              selectionRegistrar: SelectionContainer.maybeOf(context),
              selectionColor: accent.withValues(alpha: 0.65),
            ),
          ),
        ),
      ),
    );
  }
}

class _CodeSelectionPainter extends CustomPainter {
  _CodeSelectionPainter({
    required this.notifier,
    required this.paragraphKey,
    required this.color,
  }) : super(repaint: notifier);

  final SelectionListenerNotifier notifier;
  final GlobalKey paragraphKey;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (!notifier.registered) return;
    final SelectedContentRange? range = notifier.selection.range;
    if (range == null || range.startOffset == range.endOffset) return;
    final RenderObject? object = paragraphKey.currentContext
        ?.findRenderObject();
    if (object is! RenderParagraph) return;
    final Paint paint = Paint()..color = color;
    final TextSelection selection = TextSelection(
      baseOffset: range.startOffset,
      extentOffset: range.endOffset,
    );
    for (final ui.TextBox box in object.getBoxesForSelection(selection)) {
      canvas.drawRect(box.toRect(), paint);
    }
  }

  @override
  bool shouldRepaint(_CodeSelectionPainter oldDelegate) =>
      oldDelegate.notifier != notifier ||
      oldDelegate.paragraphKey != paragraphKey ||
      oldDelegate.color != color;
}

/// Markdown lays list markers in a separate gutter. During a mobile handle
/// drag, Flutter otherwise leaves the selection on the previous block when
/// the finger is over that gutter, even though list text is on the same line.
class _MessageSelectionDelegate extends StaticSelectionContainerDelegate {
  static const double _maxGutterWidth = 48;
  static final RegExp _numberedMarker = RegExp(r'^\d+\.$');

  @override
  SelectionResult handleSelectionEdgeUpdate(SelectionEdgeUpdateEvent event) {
    final Offset position = event.globalPosition;
    double? nearestTextX;
    for (final Selectable selectable in selectables) {
      // Keep markers in copied ranges, but do not let one become the target
      // when a handle passes through the marker gutter.
      if (selectable is RenderParagraph) {
        final InlineSpan span = (selectable as RenderParagraph).text;
        if (span is TextSpan) {
          final String? label = span.text;
          if (label == '•' ||
              (label != null && _numberedMarker.hasMatch(label))) {
            continue;
          }
        }
      }
      final Matrix4 transform = selectable.getTransformTo(null);
      for (final Rect box in selectable.boundingBoxes) {
        final Rect bounds = MatrixUtils.transformRect(transform, box);
        if (position.dy < bounds.top || position.dy > bounds.bottom) continue;
        if (bounds.contains(position)) {
          return super.handleSelectionEdgeUpdate(event);
        }
        final double gap = bounds.left - position.dx;
        if (gap > 0 &&
            gap <= _maxGutterWidth &&
            (nearestTextX == null || bounds.left < nearestTextX)) {
          nearestTextX = bounds.left;
        }
      }
    }
    if (nearestTextX == null) return super.handleSelectionEdgeUpdate(event);
    final Offset adjusted = Offset(nearestTextX + 1, position.dy);
    return super.handleSelectionEdgeUpdate(
      event.type == SelectionEventType.endEdgeUpdate
          ? SelectionEdgeUpdateEvent.forEnd(
              globalPosition: adjusted,
              granularity: event.granularity,
            )
          : SelectionEdgeUpdateEvent.forStart(
              globalPosition: adjusted,
              granularity: event.granularity,
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

MarkdownStyleSheet? _cachedStyleSheet;
ThemeData? _cachedTheme;
TextStyle? _cachedBodyStyle;

MarkdownStyleSheet _styleSheetFor(BuildContext context, TextStyle? bodyStyle) {
  // Brightness switches midway through AnimatedTheme; colors keep changing
  // afterward. Never retain an intermediate frame's low-contrast palette.
  final ThemeData theme = Theme.of(context);
  if (_cachedStyleSheet == null ||
      _cachedTheme != theme ||
      _cachedBodyStyle != bodyStyle) {
    _cachedStyleSheet = MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: bodyStyle,
      code: context.speedDialColors.mono.copyWith(fontSize: 12.5),
      codeblockPadding: const EdgeInsets.all(10),
      codeblockDecoration: BoxDecoration(
        color: context.speedDialColors.codeBackground,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: context.speedDialColors.border),
      ),
      blockquotePadding: const EdgeInsets.symmetric(
        horizontal: 12,
        vertical: 4,
      ),
    );
    _cachedTheme = theme;
    _cachedBodyStyle = bodyStyle;
  }
  return _cachedStyleSheet!;
}

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
        expansionAnimationStyle: animateHistoryText(text)
            ? null
            : AnimationStyle.noAnimation,
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
