import 'dart:convert';
import 'dart:typed_data';

import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../api/daemon_client.dart';

class DownloadCancelled implements Exception {
  const DownloadCancelled();
}

/// Pull-based transfer: the next RPC starts only after the sink accepts bytes.
class FileDownloadTransfer {
  FileDownloadTransfer(this.client, this.sessionId, this.path);

  final DaemonClient client;
  final String sessionId;
  final String path;
  bool cancelled = false;
  bool completed = false;
  late String name;
  late int size;
  FileDownloadChunk? _first;
  FileDownload? _legacy;

  Future<void> prepare() async {
    _checkCancelled();
    try {
      _first = await client.downloadFileChunk(sessionId, path, offset: 0);
      name = _first!.name;
      size = _first!.size;
    } on DaemonError catch (error) {
      if (error.code != -32601) rethrow;
      _legacy = await client.downloadFile(sessionId, path);
      name = _legacy!.name;
      size = _legacy!.size;
    }
    _checkCancelled();
    if (size < 0) throw const FormatException('Invalid download size');
  }

  void _checkCancelled() {
    if (cancelled) throw const DownloadCancelled();
  }

  Stream<Uint8List> bytes(
    void Function(int received, int total) progress,
  ) async* {
    _checkCancelled();
    final FileDownload? legacy = _legacy;
    if (legacy != null) {
      final Uint8List decoded = base64Decode(legacy.data);
      if (decoded.length != size) {
        throw const FormatException(
          'Downloaded file size does not match payload',
        );
      }
      yield decoded;
      _checkCancelled();
      completed = true;
      progress(size, size);
      return;
    }
    FileDownloadChunk chunk = _first!;
    _first = null;
    final String revision = chunk.revision;
    int offset = 0;
    while (true) {
      _checkCancelled();
      final Uint8List decoded = base64Decode(chunk.data);
      if (chunk.offset != offset ||
          chunk.size != size ||
          chunk.name != name ||
          chunk.revision != revision ||
          decoded.length > 256 * 1024 ||
          offset + decoded.length > size ||
          (decoded.isEmpty && offset < size)) {
        throw const FormatException('Invalid or changed download chunk');
      }
      yield decoded;
      _checkCancelled();
      offset += decoded.length;
      completed = offset == size;
      progress(offset, size);
      if (offset == size) return;
      chunk = await client.downloadFileChunk(
        sessionId,
        path,
        offset: offset,
        revision: revision,
      );
    }
  }
}
