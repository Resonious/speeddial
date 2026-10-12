import 'dart:convert';
import 'dart:io';

import 'providers/provider_registry.dart';

/// Daemon settings shared by standalone and embedded startup.
class DaemonConfig {
  const DaemonConfig({this.autoArchiveHours = 72, this.autoArchiveKeep = 5});

  /// Inactivity timeout in whole hours; zero disables automatic archival.
  final int autoArchiveHours;

  /// Minimum unarchived, non-pinned sessions to retain in each project.
  /// Zero removes the minimum; the inactivity timeout still applies.
  final int autoArchiveKeep;

  Duration get autoArchiveAfter => Duration(hours: autoArchiveHours);

  factory DaemonConfig.fromJson(Map<String, Object?> json) {
    final Object? hours = json.containsKey('autoArchiveHours')
        ? json['autoArchiveHours']
        : 72;
    if (hours is! int || hours < 0 || Duration(hours: hours).inHours != hours) {
      throw const FormatException(
        'autoArchiveHours must be a non-negative whole number of hours '
        '(0 disables automatic archival).',
      );
    }
    final Object? keep = json.containsKey('autoArchiveKeep')
        ? json['autoArchiveKeep']
        : 5;
    if (keep is! int || keep < 0) {
      throw const FormatException(
        'autoArchiveKeep must be a non-negative whole number of sessions.',
      );
    }
    return DaemonConfig(autoArchiveHours: hours, autoArchiveKeep: keep);
  }

  /// Reads ~/.speeddial/config.json once at startup. Missing files use defaults;
  /// invalid settings fail startup before any sessions can be archived.
  static DaemonConfig load({
    String? path,
    int? autoArchiveHours,
    int? autoArchiveKeep,
  }) {
    final File file = File(path ?? ProviderRegistry.configFilePath());
    Map<String, Object?> json = const <String, Object?>{};
    if (file.existsSync()) {
      final Object? decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('Daemon config must be a JSON object.');
      }
      json = decoded;
    }
    return DaemonConfig.fromJson(<String, Object?>{
      ...json,
      'autoArchiveHours': ?autoArchiveHours,
      'autoArchiveKeep': ?autoArchiveKeep,
    });
  }
}
