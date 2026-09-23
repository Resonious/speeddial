library;

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'downloaded_file_result.dart';

Future<DownloadedFileResult> openDownloadedFile(
  String name,
  Uint8List bytes,
) async {
  await FilePicker.platform.saveFile(fileName: name, bytes: bytes);
  // Browsers return no local path: a successful call means the download was
  // handed to the browser. Opening that path is prohibited by the sandbox.
  return DownloadedFileResult.saved;
}
