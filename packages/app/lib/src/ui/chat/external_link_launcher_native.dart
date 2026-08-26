library;

import 'dart:io';

import 'package:url_launcher/url_launcher.dart';

Future<bool> launchExternalLink(Uri uri) async {
  if (Platform.isLinux) {
    if (await _run('xdg-open', <String>[uri.toString()]) ||
        await _run('gio', <String>['open', uri.toString()])) {
      return true;
    }
  }
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

Future<bool> _run(String executable, List<String> arguments) async {
  try {
    final ProcessResult result = await Process.run(executable, arguments);
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}
