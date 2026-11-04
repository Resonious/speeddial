import 'rich_clipboard_native.dart'
    if (dart.library.html) 'rich_clipboard_web.dart'
    as platform;

/// Publishes both representations in one clipboard operation. Never follows
/// this with Clipboard.setData: that would erase the HTML representation.
Future<void> writeRichClipboard({required String text, required String html}) =>
    platform.writeRichClipboard(text: text, html: html);
