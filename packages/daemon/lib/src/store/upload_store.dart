/// Staging area for chunked attachment uploads (PROTOCOL.md `uploads.*`).
///
/// Each upload is a file under `uploads/` in the store's files directory,
/// appended strictly in order. `sessions.send` consumes a complete upload
/// with [take]. Staged files do not survive a daemon restart, and an upload
/// with no activity for [idleTimeout] is discarded.
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:uuid/uuid.dart';

const int _kErrInvalidParams = -32602;

class _Upload {
  _Upload(this.path, this.size, this.touchedAt);

  final String path;
  final int size;
  int received = 0;
  DateTime touchedAt;

  /// Serializes appends so a write finishes before the next offset check.
  Future<void> writing = Future<void>.value();
}

class UploadStore {
  UploadStore(
    String filesPath, {
    this.idleTimeout = const Duration(hours: 1),
    DateTime Function()? now,
  }) : _directory = Directory(p.join(filesPath, 'uploads')),
       _now = now ?? DateTime.now {
    if (_directory.existsSync()) _directory.deleteSync(recursive: true);
    _directory.createSync(recursive: true);
  }

  final Directory _directory;
  final Duration idleTimeout;
  final DateTime Function() _now;
  final Map<String, _Upload> _uploads = <String, _Upload>{};
  static const Uuid _uuid = Uuid();

  /// Starts an upload of exactly [size] bytes and returns its id.
  String begin(int size) {
    if (size < 0 || size > kMaxUploadBytes) {
      throw DaemonError(
        _kErrInvalidParams,
        'Upload size must be between 0 and $kMaxUploadBytes bytes',
      );
    }
    _expire();
    final String id = _uuid.v4();
    final String path = p.join(_directory.path, id);
    File(path).writeAsBytesSync(const <int>[]);
    _uploads[id] = _Upload(path, size, _now());
    return id;
  }

  /// Appends [bytes] at [offset], which must equal the bytes received so
  /// far. Returns the new received count.
  Future<int> append(String id, int offset, List<int> bytes) async {
    final _Upload upload = _require(id);
    final Completer<void> done = Completer<void>();
    final Future<void> previous = upload.writing;
    upload.writing = done.future;
    try {
      await previous;
      if (!identical(_uploads[id], upload)) {
        throw DaemonError(kErrNotFound, 'Unknown upload: $id');
      }
      if (bytes.length > kMaxUploadChunkBytes) {
        throw DaemonError(
          _kErrInvalidParams,
          'Upload chunks must be at most $kMaxUploadChunkBytes bytes',
        );
      }
      if (offset != upload.received) {
        throw DaemonError(
          _kErrInvalidParams,
          'Upload $id expects offset ${upload.received}, got $offset',
        );
      }
      if (upload.received + bytes.length > upload.size) {
        throw DaemonError(
          _kErrInvalidParams,
          'Upload $id exceeds its declared size of ${upload.size} bytes',
        );
      }
      await File(upload.path).writeAsBytes(bytes, mode: FileMode.append);
      if (!identical(_uploads[id], upload)) {
        // Cancelled or expired while writing.
        _delete(upload.path);
        throw DaemonError(kErrNotFound, 'Unknown upload: $id');
      }
      upload.received += bytes.length;
      upload.touchedAt = _now();
      return upload.received;
    } finally {
      done.complete();
    }
  }

  /// Size of a complete upload, or a -32602 error naming what is missing.
  int completedSize(String id) {
    final _Upload upload = _require(id);
    if (upload.received != upload.size) {
      throw DaemonError(
        _kErrInvalidParams,
        'Upload $id is incomplete: ${upload.received} of ${upload.size} bytes',
      );
    }
    return upload.size;
  }

  /// Removes a complete upload from staging and returns its file, which the
  /// caller now owns.
  ({String path, int size}) take(String id) {
    final int size = completedSize(id);
    final _Upload upload = _uploads.remove(id)!;
    return (path: upload.path, size: size);
  }

  /// Discards an upload. Unknown ids are ignored.
  void cancel(String id) {
    final _Upload? upload = _uploads.remove(id);
    if (upload != null) _delete(upload.path);
  }

  void dispose() {
    for (final _Upload upload in _uploads.values) {
      _delete(upload.path);
    }
    _uploads.clear();
  }

  _Upload _require(String id) {
    _expire();
    final _Upload? upload = _uploads[id];
    if (upload == null) {
      throw DaemonError(kErrNotFound, 'Unknown upload: $id');
    }
    return upload;
  }

  void _expire() {
    final DateTime cutoff = _now().subtract(idleTimeout);
    _uploads.removeWhere((String _, _Upload upload) {
      if (!upload.touchedAt.isBefore(cutoff)) return false;
      _delete(upload.path);
      return true;
    });
  }

  static void _delete(String path) {
    final File file = File(path);
    if (file.existsSync()) file.deleteSync();
  }
}
