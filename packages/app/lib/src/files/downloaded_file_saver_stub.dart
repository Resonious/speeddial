library;

import 'dart:typed_data';

import 'downloaded_file_result.dart';

Future<DownloadedFileResult> saveDownloadedStream(
  String name,
  Stream<Uint8List> bytes,
) async => const DownloadedFileResult(DownloadedFileStatus.unsupported);
