import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../api/daemon_client.dart';
import '../files/downloaded_file_saver.dart';
import '../files/file_download_transfer.dart';
import 'share_store.dart';

enum FileAction { download, float }

@immutable
class FileTransferNotice {
  const FileTransferNotice(
    this.title,
    this.detail, {
    this.error = false,
    this.complete = false,
  });

  final String title;
  final String detail;
  final bool error;
  final bool complete;
}

/// Transfers and their receipts outlive the session that initiated them.
class FileTransferStore extends ChangeNotifier {
  FileTransferStore(this.shares);

  final ShareStore shares;
  final List<FileTransferNotice> _finished = <FileTransferNotice>[];
  late final List<FileTransferNotice> finished = UnmodifiableListView(
    _finished,
  );
  FileDownloadTransfer? _transfer;
  FileTransferNotice? _active;
  bool _disposed = false;
  String? _lastError;

  FileTransferNotice? get active => _active;
  String? get lastError => _lastError;
  bool get busy => _transfer != null;
  bool get canCancel =>
      _transfer != null && !_transfer!.completed && !_transfer!.cancelled;

  void dismiss(FileTransferNotice notice) {
    if (_finished.remove(notice)) notifyListeners();
  }

  void cancel() {
    if (!canCancel) return;
    _transfer!.cancelled = true;
    _active = FileTransferNotice('Cancelling…', _active?.detail ?? '');
    notifyListeners();
  }

  Future<void> start(
    DaemonClient client,
    String sessionId,
    String path,
    FileAction action,
  ) async {
    if (busy || _disposed) return;
    final bool floating = action == FileAction.float;
    final FileDownloadTransfer transfer = FileDownloadTransfer(
      client,
      sessionId,
      path,
    );
    _transfer = transfer;
    _lastError = null;
    _active = FileTransferNotice(
      floating ? 'Preparing to float…' : 'Preparing download…',
      path,
    );
    notifyListeners();
    try {
      await transfer.prepare();
      if (_disposed) return;
      if (floating && transfer.size > kMaxAttachmentBytes) {
        throw const DaemonError(
          -32602,
          'Files larger than 8 MiB cannot be attached to a session. Choose Download to save this file.',
        );
      }
      final Stream<Uint8List> bytes = transfer.bytes((received, total) {
        if (_disposed) return;
        _active = FileTransferNotice(
          received == total
              ? (floating ? 'Floating file…' : 'Saving file…')
              : '${floating ? 'Loading' : 'Downloading'} '
                    '${total == 0 ? 100 : (received * 100 / total).floor()}%'
                    ' (${(received / 1048576).toStringAsFixed(1)} / '
                    '${(total / 1048576).toStringAsFixed(1)} MiB)',
          transfer.name,
        );
        notifyListeners();
      });
      if (floating) {
        final BytesBuilder content = BytesBuilder(copy: false);
        await for (final Uint8List chunk in bytes) {
          content.add(chunk);
        }
        if (_disposed) return;
        shares.floatFile(
          OutgoingAttachment(
            name: transfer.name,
            mimeType: mimeTypeForFileName(transfer.name),
            data: base64Encode(content.takeBytes()),
          ),
        );
      } else {
        final DownloadedFileResult result = await saveDownloadedStream(
          transfer.name,
          bytes,
        );
        if (_disposed) return;
        switch (result.status) {
          case DownloadedFileStatus.saved:
            _finished.add(
              FileTransferNotice(
                'Download complete',
                result.path == null
                    ? '${transfer.name} · Saved to your chosen location'
                    : '${transfer.name}\nSaved to ${result.path}',
                complete: true,
              ),
            );
          case DownloadedFileStatus.browserDownload:
            _finished.add(
              FileTransferNotice(
                'Sent to browser',
                '${transfer.name}\nCheck your browser’s downloads for the saved file.',
              ),
            );
          case DownloadedFileStatus.cancelled:
            _finished.add(
              FileTransferNotice('Download cancelled', transfer.name),
            );
          case DownloadedFileStatus.unsupported:
            throw UnsupportedError(
              'Saving files is not supported on this platform',
            );
        }
      }
    } on DownloadCancelled {
      if (!_disposed) {
        _finished.add(
          FileTransferNotice(
            floating ? 'Float cancelled' : 'Download cancelled',
            path,
          ),
        );
      }
    } on Object catch (error) {
      if (!_disposed) {
        _lastError = error is DaemonError ? error.message : error.toString();
        _finished.add(
          FileTransferNotice(
            floating ? 'Could not float file' : 'Download failed',
            _lastError!,
            error: true,
          ),
        );
      }
      rethrow;
    } finally {
      _transfer = null;
      _active = null;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _transfer?.cancelled = true;
    super.dispose();
  }
}
