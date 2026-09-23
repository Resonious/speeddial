/// Saves a daemon file payload on mobile, opens a temporary copy on desktop,
/// or hands the download to the browser on web.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:speeddial_protocol/speeddial_protocol.dart';

import 'downloaded_file_result.dart';
import 'downloaded_file_opener_stub.dart'
    if (dart.library.io) 'downloaded_file_opener_native.dart'
    if (dart.library.html) 'downloaded_file_opener_web.dart'
    as platform;

export 'downloaded_file_result.dart';

Future<DownloadedFileResult> openDownloadedFile(FileDownload download) async {
  final Uint8List bytes = base64Decode(download.data);
  if (bytes.length != download.size) {
    throw const FormatException('Downloaded file size does not match payload');
  }
  return platform.openDownloadedFile(download.name, bytes);
}
