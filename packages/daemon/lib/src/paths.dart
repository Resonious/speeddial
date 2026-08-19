/// Path helpers shared by the daemon server and its CLI.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// The current user's home directory: `$HOME`, falling back to
/// `%USERPROFILE%` (Windows). Null when neither is set.
String? homeDir() {
  final String? home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  return (home == null || home.isEmpty) ? null : home;
}

/// Expands a leading `~` in [path] against [home] (defaults to [homeDir]).
///
/// Only a bare `~` and `~/…` (or `~\…`) expand; `~user/…` is returned
/// unchanged. Paths without a leading tilde pass through untouched, as does
/// a tilde path when no home directory is known — it then fails the usual
/// not-a-directory validation with the literal path in the message.
String expandTilde(String path, {String? home}) {
  if (path != '~' && !path.startsWith('~/') && !path.startsWith(r'~\')) {
    return path;
  }
  final String? resolved = home ?? homeDir();
  if (resolved == null) return path;
  if (path == '~') return resolved;
  return p.join(resolved, path.substring(2));
}
