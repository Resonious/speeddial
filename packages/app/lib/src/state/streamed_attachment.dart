import 'dart:typed_data';

import 'package:speeddial_protocol/speeddial_protocol.dart';

/// A local file too large to send inline. [ChatStore.send] uploads it in
/// chunks (PROTOCOL.md `uploads.*`) and sends the upload id in its place;
/// the bytes are never held in memory all at once.
class StreamedAttachment extends OutgoingAttachment {
  StreamedAttachment({
    required super.name,
    required super.mimeType,
    required this.size,
    required this.read,
    this.release,
  });

  /// Total file size in bytes.
  final int size;

  /// Reads up to `length` bytes at `offset`; returns fewer only at the end
  /// of the file.
  final Future<Uint8List> Function(int offset, int length) read;

  /// Frees the platform handle once the file is sent or dropped.
  final Future<void> Function()? release;
}
