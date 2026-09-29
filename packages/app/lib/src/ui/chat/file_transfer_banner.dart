import 'package:flutter/material.dart';

import '../../scope.dart';
import '../../state/file_transfer_store.dart';

class FileTransferBanner extends StatelessWidget {
  const FileTransferBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final FileTransferStore store = AppScope.of(context).fileTransfers;
    // Keep the scrolling banner's layer separate from the chat. Collapsing
    // its last receipt must not leave the web timeline waiting for a repaint.
    return RepaintBoundary(
      child: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final FileTransferNotice? active = store.active;
          final List<FileTransferNotice> finished = store.finished;
          if (active == null && finished.isEmpty) {
            return const SizedBox.shrink();
          }
          return ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.3,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (active != null)
                    _Notice(
                      notice: active,
                      busy: true,
                      action: store.canCancel ? store.cancel : null,
                    ),
                  for (final FileTransferNotice notice in finished)
                    _Notice(
                      notice: notice,
                      action: () => store.dismiss(notice),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.notice,
    required this.action,
    this.busy = false,
  });

  final FileTransferNotice notice;
  final VoidCallback? action;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Material(
        color: notice.error ? colors.errorContainer : colors.surfaceContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: busy
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        notice.error
                            ? Icons.error_outline
                            : notice.complete
                            ? Icons.check_circle_outline
                            : Icons.info_outline,
                        size: 20,
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      notice.title,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    SelectableText(
                      notice.detail,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: action,
                child: Text(busy ? 'Cancel' : 'Dismiss'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
