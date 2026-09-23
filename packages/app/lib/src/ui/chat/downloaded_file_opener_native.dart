library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import 'downloaded_file_result.dart';

Future<DownloadedFileResult> openDownloadedFile(
  String name,
  Uint8List bytes,
) async {
  final String safeName = _safeFileName(name);
  if (defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS) {
    final String? path = await FilePicker.platform.saveFile(
      fileName: safeName,
      bytes: bytes,
    );
    // The picker has already written the bytes. Android document-provider
    // locations are not filesystem paths and must never become file:// URLs.
    return path == null
        ? DownloadedFileResult.cancelled
        : DownloadedFileResult.saved;
  }

  final Directory directory = Directory(
    '${Directory.systemTemp.path}${Platform.pathSeparator}speeddial-downloads',
  );
  await directory.create(recursive: true);
  final String prefix = DateTime.now().microsecondsSinceEpoch.toString();
  final File file = File(
    '${directory.path}${Platform.pathSeparator}$prefix-$safeName',
  );
  await file.writeAsBytes(bytes, flush: true);
  final bool opened = await launchUrl(
    Uri.file(file.path),
    mode: LaunchMode.externalApplication,
  );
  return opened
      ? DownloadedFileResult.opened
      : DownloadedFileResult.unsupported;
}

String _safeFileName(String name) {
  final String basename = name.split(RegExp(r'[/\\]')).last;
  final String sanitized = basename
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
      .trim();
  return sanitized.isEmpty || sanitized == '.' || sanitized == '..'
      ? 'download'
      : sanitized;
}
