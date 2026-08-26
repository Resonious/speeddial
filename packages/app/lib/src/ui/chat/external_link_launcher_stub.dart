library;

import 'package:url_launcher/url_launcher.dart';

Future<bool> launchExternalLink(Uri uri) async {
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}
