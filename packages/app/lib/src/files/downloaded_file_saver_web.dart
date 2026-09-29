// Browser-only implementation selected by conditional import.
// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
library;

import 'dart:html' as html;

import 'dart:typed_data';

import 'downloaded_file_result.dart';

Future<DownloadedFileResult> saveDownloadedStream(
  String name,
  Stream<Uint8List> bytes,
) async {
  // Browser Blob storage avoids concatenating the file into one Dart buffer.
  final List<html.Blob> parts = <html.Blob>[];
  await for (final Uint8List chunk in bytes) {
    parts.add(html.Blob(<Object>[chunk]));
  }
  final html.Blob blob = html.Blob(parts);
  final String url = html.Url.createObjectUrlFromBlob(blob);
  final html.AnchorElement anchor = html.AnchorElement(href: url)
    ..download = name;
  anchor.click();
  // Give the browser time to start consuming its own Blob URL.
  Future<void>.delayed(
    const Duration(minutes: 1),
    () => html.Url.revokeObjectUrl(url),
  );
  return const DownloadedFileResult(DownloadedFileStatus.browserDownload);
}
