import 'package:flutter/foundation.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../api/daemon_client.dart';

/// Lazily caches directory listings per (project, directory) pair.
///
/// [entriesFor] returns null until that directory was loaded, so panes can
/// render a placeholder and trigger [loadDir]. [readFile] is a pure pass-
/// through with no caching.
class FilesStore extends ChangeNotifier {
  FilesStore({required DaemonClient Function(String daemonId) clientFor})
      // ignore: prefer_initializing_formals
      : _clientFor = clientFor;

  final DaemonClient Function(String daemonId) _clientFor;

  final Map<(String, String), List<FileEntry>> _entries =
      <(String, String), List<FileEntry>>{};
  final Map<(String, String), Object> _dirErrors =
      <(String, String), Object>{};

  /// Null while `projectId/dirPath` has not been loaded yet.
  List<FileEntry>? entriesFor(String projectId, String dirPath) {
    final List<FileEntry>? entries = _entries[(projectId, dirPath)];
    return entries == null ? null : List<FileEntry>.unmodifiable(entries);
  }

  /// Error from the most recent [loadDir] for `projectId/dirPath`, if any.
  /// Panes render a retry row instead of an endless spinner.
  Object? dirErrorFor(String projectId, String dirPath) =>
      _dirErrors[(projectId, dirPath)];

  Future<void> loadDir(String daemonId, String projectId, String dirPath) async {
    try {
      final List<FileEntry> entries =
          await _clientFor(daemonId).listFiles(projectId, dirPath);
      _entries[(projectId, dirPath)] = entries;
      _dirErrors.remove((projectId, dirPath));
    } catch (error) {
      _dirErrors[(projectId, dirPath)] = error;
    } finally {
      notifyListeners();
    }
  }

  Future<FileReadResult> readFile(
          String daemonId, String projectId, String path) =>
      _clientFor(daemonId).readFile(projectId, path);
}
