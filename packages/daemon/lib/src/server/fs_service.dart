/// Filesystem access for UI clients, confined to a project root.
///
/// Implements PROTOCOL.md `fs.list` / `fs.read` / `fs.download`. Browsing
/// paths are relative to the project root; downloads may use absolute paths
/// inside a session cwd. Anything resolving outside its root is an
/// invalid-params error (`-32602`) — never a path traversal.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_protocol/speeddial_protocol.dart';

/// JSON-RPC code: invalid params (missing path, not a directory, escape, …).
const int _kErrInvalidParams = -32602;

/// Default cap on returned file bytes when the client does not set
/// `fs.read.maxBytes`.
const int kFsReadDefaultMaxBytes = 512 * 1024; // 512 KiB

/// Hard cap on returned file bytes regardless of the client's `maxBytes`.
const int kFsReadHardCapBytes = 4 * 1024 * 1024; // 4 MiB

/// Hard cap on a complete binary payload returned through `fs.download`.
const int kFsDownloadHardCapBytes = 64 * 1024 * 1024; // 64 MiB

/// Number of leading bytes probed for a NUL byte (binary detection).
const int _kFsBinaryProbeBytes = 8 * 1024;

/// Serving helpers for `fs.list` / `fs.read`.
class FsService {
  /// Lists one directory under [rootPath], relative [path] (default `"."`).
  ///
  /// Skips `.git` entries, orders directories first then by name ascending,
  /// and reports every entry as a [FileEntry] with a root-relative path.
  List<FileEntry> list({required String rootPath, String? path}) {
    final target = resolveInRoot(rootPath, path ?? '.');
    final type = FileSystemEntity.typeSync(target, followLinks: true);
    if (type != FileSystemEntityType.directory) {
      throw DaemonError(
        _kErrInvalidParams,
        'Not a directory: ${path ?? '.'}',
      );
    }
    final root = p.canonicalize(rootPath);
    final relPrefix = p.relative(target, from: root);
    final entries = <FileEntry>[];
    for (final entity in Directory(target).listSync(followLinks: true)) {
      final name = p.basename(entity.path);
      final isDir = FileSystemEntity.isDirectorySync(entity.path);
      if (isDir && name == '.git') continue; // Skip `.git` internals.
      final stat = entity.statSync();
      entries.add(FileEntry(
        name: name,
        path: relPrefix == '.' ? name : p.join(relPrefix, name),
        isDir: isDir,
        size: isDir ? 0 : stat.size,
        modifiedAt: stat.modified.toUtc(),
      ));
    }
    entries.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.compareTo(b.name);
    });
    return entries;
  }

  /// Reads one file under [rootPath], relative [path].
  ///
  /// [maxBytes] defaults to 512 KiB and is hard-capped at 4 MiB. A NUL byte
  /// within the first 8 KiB marks the file binary (`content: ''`,
  /// `truncated: false`); otherwise the content is the UTF-8 (lossy) decode
  /// of the first `maxBytes` bytes, `truncated` reflecting a longer file.
  FileReadResult read({
    required String rootPath,
    required String path,
    int? maxBytes,
  }) {
    final target = resolveInRoot(rootPath, path);
    final type = FileSystemEntity.typeSync(target, followLinks: true);
    if (type == FileSystemEntityType.notFound) {
      throw DaemonError(_kErrInvalidParams, 'No such file: $path');
    }
    if (type != FileSystemEntityType.file) {
      throw DaemonError(_kErrInvalidParams, 'Not a file: $path');
    }
    final file = File(target);
    final length = file.lengthSync();
    // NUL-byte probe on the first 8 KiB: binary shortcut.
    final probe = file.openSync();
    try {
      final probeBytes = probe.readSync(_kFsBinaryProbeBytes);
      if (probeBytes.contains(0)) {
        return const FileReadResult(
          content: '',
          truncated: false,
          isBinary: true,
        );
      }
      final effectiveMax = maxBytes == null || maxBytes <= 0
          ? kFsReadDefaultMaxBytes
          : maxBytes > kFsReadHardCapBytes
              ? kFsReadHardCapBytes
              : maxBytes;
      if (length <= effectiveMax) {
        final bytes = file.readAsBytesSync();
        return FileReadResult(
          content: utf8.decode(bytes, allowMalformed: true),
          truncated: false,
          isBinary: false,
        );
      }
      probe.setPositionSync(0);
      final bytes = probe.readSync(effectiveMax);
      return FileReadResult(
        content: utf8.decode(bytes, allowMalformed: true),
        truncated: true,
        isBinary: false,
      );
    } finally {
      probe.closeSync();
    }
  }

  /// Reads a complete file for a chat-link download.
  ///
  /// Unlike [read], this is binary-safe and accepts an absolute [path] when
  /// it remains inside [rootPath]. Relative paths resolve from [rootPath].
  FileDownload download({required String rootPath, required String path}) {
    final target = resolveInRoot(rootPath, path, allowAbsolute: true);
    final type = FileSystemEntity.typeSync(target, followLinks: true);
    if (type == FileSystemEntityType.notFound) {
      throw DaemonError(_kErrInvalidParams, 'No such file: $path');
    }
    if (type != FileSystemEntityType.file) {
      throw DaemonError(_kErrInvalidParams, 'Not a file: $path');
    }
    final file = File(target);
    final size = file.lengthSync();
    if (size > kFsDownloadHardCapBytes) {
      throw DaemonError(
        _kErrInvalidParams,
        'File is too large to download (maximum 64 MiB): $path',
      );
    }
    return FileDownload(
      name: p.basename(target),
      size: size,
      data: base64Encode(file.readAsBytesSync()),
    );
  }

  /// Resolves [requested] against [rootPath], rejecting absolute paths unless
  /// [allowAbsolute] is true, and rejecting anything that escapes the root
  /// (after canonicalization) with `-32602`.
  ///
  /// The lexical check alone is not a confinement boundary: subsequent I/O
  /// follows symlinks (`followLinks` is on), so a symlink inside the root
  /// pointing outside it would smuggle reads out of the sandbox. The real
  /// (symlink-resolved) path of the deepest existing ancestor of the target —
  /// or of the target itself when it exists — is therefore verified against
  /// the symlink-resolved root, and only paths that remain inside are
  /// accepted.
  String resolveInRoot(
    String rootPath,
    String requested, {
    bool allowAbsolute = false,
  }) {
    final absolute = p.isAbsolute(requested);
    if (absolute && !allowAbsolute) {
      throw DaemonError(_kErrInvalidParams, 'Absolute paths are not allowed');
    }
    final root = p.canonicalize(rootPath);
    final candidate = p.canonicalize(
      absolute ? requested : p.join(root, requested),
    );
    final prefix = root.endsWith(p.separator)
        ? root
        : '$root${p.separator}';
    if (candidate == root || candidate.startsWith(prefix)) {
      final realRoot = _realPathOfDeepestExisting(root);
      final realCandidate = _realPathOfDeepestExisting(candidate);
      final realPrefix = realRoot.endsWith(p.separator)
          ? realRoot
          : '$realRoot${p.separator}';
      if (realCandidate == realRoot ||
          realCandidate.startsWith(realPrefix)) {
        return candidate;
      }
    }
    throw DaemonError(_kErrInvalidParams, 'Path escapes the project root');
  }

  /// The symlink-resolved real path of [path], or of its deepest existing
  /// ancestor when [path] itself does not exist yet (targets may be missing,
  /// e.g. `fs.read` of a path whose sibling ancestors are symlinks).
  String _realPathOfDeepestExisting(String path) {
    var current = path;
    while (true) {
      try {
        return File(current).resolveSymbolicLinksSync();
      } on FileSystemException {
        final parent = p.dirname(current);
        if (parent == current) rethrow; // Reached the filesystem root.
        current = parent;
      }
    }
  }
}
