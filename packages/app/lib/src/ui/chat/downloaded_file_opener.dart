/// Materializes a daemon file payload on the client device and asks the host
/// operating system to open it. Web builds trigger the browser's download
/// flow because browser sandboxes do not expose a launchable local path.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:speeddial_protocol/speeddial_protocol.dart';

import 'downloaded_file_opener_stub.dart'
    if (dart.library.io) 'downloaded_file_opener_native.dart'
    if (dart.library.html) 'downloaded_file_opener_web.dart'
    as platform;

Future<bool> openDownloadedFile(FileDownload download) async {
  final Uint8List bytes = base64Decode(download.data);
  if (bytes.length != download.size) {
    throw const FormatException('Downloaded file size does not match payload');
  }
  return platform.openDownloadedFile(download.name, bytes);
}
