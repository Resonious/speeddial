library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'downloaded_file_result.dart';

const MethodChannel _downloads = MethodChannel('sh.speeddial/downloads');

String _safeFileName(String name) {
  final String basename = name.split(RegExp(r'[/\\]')).last;
  final String sanitized = basename
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
      .trim();
  return sanitized.isEmpty || sanitized == '.' || sanitized == '..'
      ? 'download'
      : sanitized;
}

Future<DownloadedFileResult> saveDownloadedStream(
  String name,
  Stream<Uint8List> bytes,
) async {
  final bool mobile =
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
  final String safeName = _safeFileName(name);
  final String? destination;
  if (mobile) {
    destination = null;
  } else {
    destination = await FilePicker.platform.saveFile(
      dialogTitle: 'Download file',
      fileName: safeName,
      lockParentWindow: true,
    );
    if (destination == null) {
      return const DownloadedFileResult(DownloadedFileStatus.cancelled);
    }
  }

  // Stage beside the destination on desktop so a completed transfer can be
  // renamed into place. Cancellation or an RPC error must not truncate an
  // existing file selected in the picker.
  final Directory parent;
  if (defaultTargetPlatform == TargetPlatform.android) {
    // Use the same cache root the native saver validates. Dart's system temp
    // directory is not guaranteed to be Android's Context.cacheDir.
    final String? cachePath = await _downloads.invokeMethod<String>(
      'getCacheDirectory',
    );
    if (cachePath == null || cachePath.isEmpty) {
      throw StateError('Android download cache directory is unavailable');
    }
    parent = Directory(cachePath);
  } else {
    parent = destination == null
        ? Directory.systemTemp
        : File(destination).parent;
  }
  final Directory directory = await parent.createTemp('.speeddial-download-');
  final File file = File('${directory.path}${Platform.pathSeparator}$safeName');
  try {
    final RandomAccessFile output = await file.open(mode: FileMode.write);
    try {
      await for (final Uint8List chunk in bytes) {
        await output.writeFrom(chunk);
      }
      await output.flush();
    } finally {
      await output.close();
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      final bool? saved = await _downloads.invokeMethod<bool>(
        'save',
        <String, Object?>{'path': file.path, 'name': safeName},
      );
      return DownloadedFileResult(
        saved == true
            ? DownloadedFileStatus.saved
            : DownloadedFileStatus.cancelled,
      );
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final String? path = await FilePicker.platform.saveFile(
        fileName: safeName,
        bytes: await file.readAsBytes(),
      );
      return DownloadedFileResult(
        path == null
            ? DownloadedFileStatus.cancelled
            : DownloadedFileStatus.saved,
        path: path,
      );
    }
    await file.rename(destination!);
    return DownloadedFileResult(DownloadedFileStatus.saved, path: destination);
  } finally {
    await directory.delete(recursive: true);
  }
}
