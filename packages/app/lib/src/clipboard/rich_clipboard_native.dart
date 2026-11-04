import 'package:flutter/services.dart';

const MethodChannel richClipboardChannel = MethodChannel(
  'sh.speeddial/clipboard',
);

Future<void> writeRichClipboard({required String text, required String html}) =>
    richClipboardChannel.invokeMethod<void>('writeHtml', <String, String>{
      'text': text,
      'html': html,
    });
