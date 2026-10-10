import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:speeddial_protocol/speeddial_protocol.dart';

/// Publishes completed turns through ntfy's JSON API, preserving Unicode
/// titles and replies without placing agent text in HTTP headers.
class NtfyNotifier {
  NtfyNotifier({
    required this.topic,
    this.appUrl,
    this.timeout = const Duration(seconds: 10),
    HttpClient Function()? httpClientFactory,
  }) : _httpClientFactory = httpClientFactory ?? HttpClient.new;

  final String topic;
  final Uri? appUrl;
  final Duration timeout;
  final HttpClient Function() _httpClientFactory;

  static bool isValidTopic(String topic) => _topic.stringMatch(topic) == topic;
  static final RegExp _topic = RegExp(r'^[-_A-Za-z0-9]{1,64}$');

  Future<void> publish(Session session, String finalText) async {
    if (finalText.trim().isEmpty) return;
    final String link = SessionLink(
      sessionId: session.id,
      projectId: session.projectId,
    ).toUri(appUrl: appUrl).toString();
    final Map<String, Object?> payload = <String, Object?>{
      'topic': topic,
      'title': _limitUtf8(session.title, 1024),
      'message': _limitUtf8(finalText, 4096),
      'tags': <String>['heavy_check_mark'],
      'priority': 3,
      'markdown': true,
      'click': link,
      'actions': <Object?>[
        <String, Object?>{
          'action': 'view',
          'label': 'Open SpeedDial',
          'url': link,
        },
      ],
    };
    final HttpClient client = _httpClientFactory();
    client.connectionTimeout = timeout;
    try {
      await _post(client, payload).timeout(timeout);
    } finally {
      // Also aborts a stalled request when the whole exchange times out.
      client.close(force: true);
    }
  }

  Future<void> _post(HttpClient client, Map<String, Object?> payload) async {
    final HttpClientRequest request = await client.postUrl(
      Uri.https('ntfy.sh', '/'),
    );
    request.followRedirects = false;
    request.headers.contentType = ContentType.json;
    final List<int> body = utf8.encode(jsonEncode(payload));
    request.contentLength = body.length;
    request.add(body);
    final HttpClientResponse response = await request.close();
    await response.drain<void>();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('ntfy returned HTTP ${response.statusCode}');
    }
  }
}

/// ntfy limits messages to 4 KiB and titles to 1 KiB. Cut at a Unicode
/// boundary and leave a visible ellipsis rather than becoming an attachment.
String _limitUtf8(String text, int maxBytes) {
  if (utf8.encode(text).length <= maxBytes) return text;
  final StringBuffer prefix = StringBuffer();
  int bytes = 0;
  for (final int rune in text.runes) {
    final String character = String.fromCharCode(rune);
    final int length = utf8.encode(character).length;
    if (bytes + length > maxBytes - 3) break;
    prefix.write(character);
    bytes += length;
  }
  return '$prefix…';
}
