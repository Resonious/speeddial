import 'package:web_socket_channel/web_socket_channel.dart';

import 'daemon_frame_channel.dart';

DaemonFrameChannel connectWebSocketFrameChannel(
  Uri uri, {
  required Duration connectTimeout,
  Duration? pingInterval,
}) => _WebSocketDaemonFrameChannel(uri);

class _WebSocketDaemonFrameChannel implements DaemonFrameChannel {
  _WebSocketDaemonFrameChannel(Uri uri)
    : _channel = WebSocketChannel.connect(uri);

  final WebSocketChannel _channel;

  @override
  Future<void> get ready => _channel.ready;

  @override
  Stream<Object?> get stream => _channel.stream;

  @override
  void add(Object? data) => _channel.sink.add(data);

  @override
  Future<void> close() => _channel.sink.close();
}
