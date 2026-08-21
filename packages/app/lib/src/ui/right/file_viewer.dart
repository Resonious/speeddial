import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:syntax_highlight/syntax_highlight.dart';

import '../../scope.dart';
import '../../state/files_store.dart';
import '../../theme.dart';

/// Languages with a bundled TextMate grammar (syntax_highlight 0.4.0 ships
/// grammars for these ids).
const Set<String> kHighlightLanguages = <String>{'dart', 'yaml', 'sql', 'json'};

/// Maps a lowercased file extension (without the dot) to a highlighter
/// language id. Extensions absent from this map fall back to plain text.
const Map<String, String> kLanguageByExtension = <String, String>{
  'dart': 'dart',
  'yaml': 'yaml',
  'yml': 'yaml',
  'sql': 'sql',
  'json': 'json',
};

/// Reads a project file and renders it with syntax highlighting. Capped
/// reads show a truncation banner; binary files show a placeholder. All
/// highlight work happens once per file load, never in `build`.
class FileViewer extends StatefulWidget {
  const FileViewer({
    super.key,
    required this.daemonId,
    required this.projectId,
    required this.file,
    this.onClose,
  });

  final String daemonId;
  final String projectId;
  final FileEntry file;
  final VoidCallback? onClose;

  @override
  State<FileViewer> createState() => _FileViewerState();
}

class _FileViewerState extends State<FileViewer> {
  late FilesStore _files;
  FileReadResult? _result;
  Object? _error;
  TextSpan? _highlighted;
  bool _loading = false;
  Brightness _brightness = Brightness.dark;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _files = AppScope.of(context).files;
    final Brightness brightness = Theme.of(context).brightness;
    if (_brightness != brightness) {
      // Theme switch: re-highlight the loaded content in the new brightness
      // without refetching the file.
      _brightness = brightness;
      final FileReadResult? result = _result;
      if (result != null && !result.isBinary) {
        _highlighted = null;
        unawaited(_applyHighlight(result.content, widget.file.path));
      }
    }
    _load();
  }

  @override
  void didUpdateWidget(FileViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path) {
      _loading = false;
      _result = null;
      _error = null;
      _highlighted = null;
      _load();
    }
  }

  Future<void> _load() async {
    if (_loading || _result != null) return;
    _loading = true;
    final FilesStore files = _files;
    final String path = widget.file.path;
    try {
      final FileReadResult result =
          await files.readFile(widget.daemonId, widget.projectId, path);
      if (!mounted || widget.file.path != path) return;
      // Render the content immediately; the highlight (grammar/theme assets
      // load asynchronously) upgrades the span when ready and falls back to
      // plain text on any failure.
      setState(() {
        _result = result;
        _highlighted = null;
      });
      if (!result.isBinary) {
        await _applyHighlight(result.content, path);
      }
    } on DaemonError catch (error) {
      if (!mounted || widget.file.path != path) return;
      setState(() => _error = error.message);
    } catch (_) {
      if (!mounted || widget.file.path != path) return;
      setState(() => _error = 'Failed to read $path');
    } finally {
      _loading = false;
    }
  }

  Future<void> _applyHighlight(String content, String path) async {
    final Brightness brightness = _brightness;
    final TextSpan? highlighted = await _highlight(content, path, brightness);
    // A theme switch during the await restarts highlighting with the new
    // brightness; drop this stale span.
    if (!mounted || widget.file.path != path || _brightness != brightness) {
      return;
    }
    setState(() => _highlighted = highlighted);
  }

  Future<TextSpan?> _highlight(
      String content, String path, Brightness brightness) async {
    final String? language = _languageFor(path);
    if (language == null) return null;
    try {
      final Highlighter highlighter =
          await _highlighterFor(language, brightness);
      return highlighter.highlight(content);
    } catch (_) {
      // Missing grammar/theme assets: fall back to plain rendering.
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final SpeedDialColors colors = context.speedDialColors;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  widget.file.path,
                  style: colors.mono.copyWith(color: scheme.onSurfaceVariant),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (widget.onClose != null)
                IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  tooltip: 'Close file',
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onClose,
                ),
            ],
          ),
        ),
        const Divider(height: 1, thickness: 1),
        Expanded(child: _body(colors, scheme)),
      ],
    );
  }

  Widget _body(SpeedDialColors colors, ColorScheme scheme) {
    final FileReadResult? result = _result;
    final Object? error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            error.toString(),
            style: colors.mono.copyWith(color: scheme.error),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (result == null) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (result.isBinary) {
      return Center(
        child: Text(
          'Binary file',
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (result.truncated)
          Container(
            color: scheme.surfaceContainerHighest,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              'Truncated at ${utf8.encode(result.content).length} bytes',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        Expanded(
          child: SelectionArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Text.rich(
                _highlighted ?? TextSpan(text: result.content),
                style: colors.mono,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

String? _languageFor(String path) {
  final int dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) return null;
  return kLanguageByExtension[path.substring(dot + 1).toLowerCase()];
}

// Highlighter construction is async (grammar + theme assets) and cached for
// the app lifetime: one instantiated Highlighter per language and brightness.
final Map<(String, Brightness), Future<Highlighter>> _highlighterCache =
    <(String, Brightness), Future<Highlighter>>{};

Future<Highlighter> _highlighterFor(String language, Brightness brightness) {
  return _highlighterCache.putIfAbsent((language, brightness), () async {
    await Highlighter.initialize(<String>[language]);
    final HighlighterTheme theme =
        await HighlighterTheme.loadForBrightness(brightness);
    return Highlighter(language: language, theme: theme);
  });
}
