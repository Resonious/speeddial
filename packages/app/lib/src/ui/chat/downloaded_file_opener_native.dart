library;

import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';

Future<bool> openDownloadedFile(String name, Uint8List bytes) async {
  final String safeName = _safeFileName(name);
  if (Platform.isAndroid || Platform.isIOS) {
    final String? path = await FilePicker.platform.saveFile(
      fileName: safeName,
      bytes: bytes,
    );
    if (path == null) return false;
    return launchUrl(Uri.file(path), mode: LaunchMode.externalApplication);
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
  return launchUrl(Uri.file(file.path), mode: LaunchMode.externalApplication);
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
