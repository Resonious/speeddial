library;

import 'dart:io';

import 'package:url_launcher/url_launcher.dart';

Future<bool> launchExternalLink(
  Uri uri, {
  bool? isLinux,
  bool? isContainer,
  Future<ProcessResult> Function(String, List<String>)? runProcess,
  Future<bool> Function(Uri)? fallback,
}) async {
  final run = runProcess ?? Process.run;
  if (isLinux ?? Platform.isLinux) {
    if (await _run(run, 'xdg-open', <String>[uri.toString()])) {
      return true;
    }
    // Container-local launchers may not see the host browser. Try the host
    // before gio, which can report success without opening a browser here.
    final container =
        isContainer ??
        (await File('/run/.containerenv').exists() ||
            await File('/.dockerenv').exists() ||
            await File('/.flatpak-info').exists());
    if (container &&
        await _run(run, 'flatpak-spawn', <String>[
          '--host',
          'xdg-open',
          uri.toString(),
        ])) {
      return true;
    }
    if (await _run(run, 'gio', <String>['open', uri.toString()])) {
      return true;
    }
  }
  try {
    return await (fallback ?? _launchWithPlugin)(uri);
  } catch (_) {
    return false;
  }
}

Future<bool> _launchWithPlugin(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

Future<bool> _run(
  Future<ProcessResult> Function(String, List<String>) run,
  String executable,
  List<String> arguments,
) async {
  try {
    final ProcessResult result = await run(executable, arguments);
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}
