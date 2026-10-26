import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/ui/chat/external_link_launcher_native.dart';

void main() {
  final uri = Uri.parse('https://example.test/auth?state=a%26b&scope=read');

  for (final scenario
      in <
        ({
          String name,
          bool container,
          String? success,
          bool missingHost,
          List<String> commands,
        })
      >[
        (
          name: 'local success stops fallback',
          container: true,
          success: 'xdg-open',
          missingHost: false,
          commands: ['xdg-open'],
        ),
        (
          name: 'host runs before gio',
          container: true,
          success: 'flatpak-spawn',
          missingHost: false,
          commands: ['xdg-open', 'flatpak-spawn'],
        ),
        (
          name: 'host failure falls through to gio',
          container: true,
          success: 'gio',
          missingHost: false,
          commands: ['xdg-open', 'flatpak-spawn', 'gio'],
        ),
        (
          name: 'missing host launcher falls through to gio',
          container: true,
          success: 'gio',
          missingHost: true,
          commands: ['xdg-open', 'flatpak-spawn', 'gio'],
        ),
        (
          name: 'native host skips flatpak-spawn',
          container: false,
          success: 'gio',
          missingHost: false,
          commands: ['xdg-open', 'gio'],
        ),
        (
          name: 'all commands failing uses plugin',
          container: true,
          success: null,
          missingHost: false,
          commands: ['xdg-open', 'flatpak-spawn', 'gio'],
        ),
      ]) {
    test(scenario.name, () async {
      final commands = <String>[];
      var pluginCalls = 0;
      final result = await launchExternalLink(
        uri,
        isLinux: true,
        isContainer: scenario.container,
        runProcess: (executable, arguments) async {
          commands.add(executable);
          expect(arguments, switch (executable) {
            'flatpak-spawn' => ['--host', 'xdg-open', uri.toString()],
            'gio' => ['open', uri.toString()],
            _ => [uri.toString()],
          });
          if (scenario.missingHost && executable == 'flatpak-spawn') {
            throw ProcessException(executable, arguments);
          }
          return ProcessResult(
            1,
            executable == scenario.success ? 0 : 1,
            '',
            '',
          );
        },
        fallback: (value) async {
          expect(value, uri);
          pluginCalls++;
          return true;
        },
      );
      expect(result, isTrue);
      expect(commands, scenario.commands);
      expect(pluginCalls, scenario.success == null ? 1 : 0);
    });
  }

  test('non-Linux uses plugin without spawning commands', () async {
    expect(
      await launchExternalLink(
        uri,
        isLinux: false,
        isContainer: true,
        runProcess: (_, _) async => throw StateError('must not spawn'),
        fallback: (_) async => false,
      ),
      isFalse,
    );
  });

  test('missing commands and plugin exception return false', () async {
    expect(
      await launchExternalLink(
        uri,
        isLinux: true,
        isContainer: true,
        runProcess: (executable, arguments) async =>
            throw ProcessException(executable, arguments),
        fallback: (_) async => throw StateError('plugin unavailable'),
      ),
      isFalse,
    );
  });
}
