import 'dart:js_interop';
import 'dart:js_interop_unsafe';

@JS('navigator.clipboard')
external _Clipboard get _clipboard;

extension type _Clipboard(JSObject _) implements JSObject {
  external JSPromise<JSAny?> write(JSArray<_ClipboardItem> items);
}

@JS('ClipboardItem')
extension type _ClipboardItem._(JSObject _) implements JSObject {
  external factory _ClipboardItem(JSObject representations);
}

@JS('Blob')
extension type _Blob._(JSObject _) implements JSObject {
  external factory _Blob(JSArray<JSString> parts, _BlobOptions options);
}

extension type _BlobOptions._(JSObject _) implements JSObject {
  external factory _BlobOptions({String type});
}

Future<void> writeRichClipboard({
  required String text,
  required String html,
}) async {
  // Begin the write within the menu's user gesture (Safari requires transient
  // activation). One clipboard item carries both representations.
  final JSObject representations = JSObject()
    ..setProperty(
      'text/plain'.toJS,
      _Blob(<JSString>[text.toJS].toJS, _BlobOptions(type: 'text/plain')),
    )
    ..setProperty(
      'text/html'.toJS,
      _Blob(<JSString>[html.toJS].toJS, _BlobOptions(type: 'text/html')),
    );
  await _clipboard
      .write(<_ClipboardItem>[_ClipboardItem(representations)].toJS)
      .toDart;
}
