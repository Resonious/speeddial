import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../files/downloaded_file_saver.dart';

/// All attachment sources use the same viewer and save the original image.
Future<void> showImageViewer(
  BuildContext context,
  Uint8List bytes,
  String name,
) => showDialog<void>(
  context: context,
  builder: (BuildContext context) => Dialog.fullscreen(
    child: _ImageViewer(bytes: bytes, name: name),
  ),
);

class _ImageViewer extends StatefulWidget {
  const _ImageViewer({required this.bytes, required this.name});

  final Uint8List bytes;
  final String name;

  @override
  State<_ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<_ImageViewer> {
  bool _saving = false;
  String? _notice;
  bool _failed = false;
  bool _saved = false;

  Future<void> _download() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _notice = 'Saving image…';
      _failed = false;
      _saved = false;
    });
    try {
      final DownloadedFileResult result = await saveDownloadedStream(
        widget.name,
        Stream<Uint8List>.value(widget.bytes),
      );
      if (!mounted) return;
      if (result.status == DownloadedFileStatus.unsupported) {
        throw UnsupportedError(
          'Saving images is not supported on this platform',
        );
      }
      setState(() {
        _saved = result.status == DownloadedFileStatus.saved;
        _notice = switch (result.status) {
          DownloadedFileStatus.saved => 'Image saved',
          DownloadedFileStatus.browserDownload =>
            'Sent to browser · Check your downloads',
          DownloadedFileStatus.cancelled => 'Download cancelled',
          DownloadedFileStatus.unsupported => null,
        };
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _notice = 'Download failed: $error';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(widget.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: <Widget>[
          IconButton(
            tooltip: _saving ? 'Saving image…' : 'Download image',
            onPressed: _saving ? null : _download,
            icon: const Icon(Icons.download_outlined),
          ),
          IconButton(
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: InteractiveViewer(
                child: Center(
                  child: Image.memory(
                    widget.bytes,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  ),
                ),
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: AnimatedSwitcher(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 150),
                child: _notice == null
                    ? const SizedBox.shrink()
                    : Padding(
                        key: ValueKey<String>(_notice!),
                        padding: const EdgeInsets.all(12),
                        child: Semantics(
                          liveRegion: true,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: <Widget>[
                              Icon(
                                _failed
                                    ? Icons.error_outline
                                    : _saving
                                    ? Icons.save_alt
                                    : _saved
                                    ? Icons.check
                                    : Icons.info_outline,
                                size: 18,
                                color: _failed
                                    ? theme.colorScheme.error
                                    : _saved
                                    ? theme.colorScheme.primary
                                    : null,
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  _notice!,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: _failed
                                        ? theme.colorScheme.error
                                        : null,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
