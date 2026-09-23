library;

import 'dart:typed_data';

import 'downloaded_file_result.dart';

Future<DownloadedFileResult> openDownloadedFile(
  String name,
  Uint8List bytes,
) async => DownloadedFileResult.unsupported;
