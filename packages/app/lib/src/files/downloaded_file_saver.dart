/// Saves a daemon file through the system picker, or the browser on web.
library;

import 'dart:typed_data';

import 'downloaded_file_result.dart';
import 'downloaded_file_saver_stub.dart'
    if (dart.library.io) 'downloaded_file_saver_native.dart'
    if (dart.library.html) 'downloaded_file_saver_web.dart'
    as platform;

export 'downloaded_file_result.dart';

Future<DownloadedFileResult> saveDownloadedStream(
  String name,
  Stream<Uint8List> bytes,
) => platform.saveDownloadedStream(name, bytes);
