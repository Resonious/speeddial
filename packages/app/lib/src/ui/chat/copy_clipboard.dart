import 'package:flutter/services.dart';

import '../../clipboard/rich_clipboard.dart';
import 'copy_formats.dart';

Future<void> copyToClipboard(String source, CopyFormat format) {
  if (format == CopyFormat.slack) {
    final SlackCopy content = formatSlackCopy(source);
    return writeRichClipboard(text: content.text, html: content.html);
  }
  return Clipboard.setData(ClipboardData(text: formatCopy(source, format)));
}
