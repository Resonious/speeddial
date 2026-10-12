import 'dart:convert';
import 'dart:io';

import 'providers/provider_registry.dart';

/// Daemon settings shared by standalone and embedded startup.
class DaemonConfig {
  const DaemonConfig({this.autoArchiveHours = 72});

  /// Inactivity timeout in whole hours; zero disables automatic archival.
  final int autoArchiveHours;

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
    return DaemonConfig(autoArchiveHours: hours);
  }

  /// Reads ~/.speeddial/config.json once at startup. Missing files use defaults;
  /// invalid settings fail startup before any sessions can be archived.
  static DaemonConfig load({String? path}) {
    final File file = File(path ?? ProviderRegistry.configFilePath());
    if (!file.existsSync()) return const DaemonConfig();
    final Object? decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Daemon config must be a JSON object.');
    }
    return DaemonConfig.fromJson(decoded);
  }
}
