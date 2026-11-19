/// One bidirectional stream of daemon WebSocket text frames.
///
/// The normal implementation connects directly over a WebSocket (`dart:io` on
/// native platforms, `package:web_socket_channel` on web). The Wear OS target
/// injects a channel whose frames cross the Wear Data Layer and whose actual
/// WebSocket is opened by the paired phone. Keeping this boundary at raw text
/// frames preserves the protocol codec, authentication, reconnect, and
/// notification behavior in one place.
abstract interface class DaemonFrameChannel {
  Future<void> get ready;
  Stream<Object?> get stream;
  void add(Object? data);
  Future<void> close();
}

typedef DaemonFrameChannelFactory = DaemonFrameChannel Function(Uri uri);
