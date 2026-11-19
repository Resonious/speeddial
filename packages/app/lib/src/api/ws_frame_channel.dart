import 'daemon_frame_channel.dart';
import 'ws_frame_channel_web.dart'
    if (dart.library.io) 'ws_frame_channel_io.dart'
    as platform;

/// Opens a WebSocket [DaemonFrameChannel] for [uri].
///
/// On native platforms (`dart:io`), each attempt uses its own [HttpClient] with
/// [connectTimeout] so an aborted or timed-out handshake immediately tears down
/// the underlying TCP/TLS socket instead of stalling on a shared client, and
/// applies [pingInterval] once connected to catch silently dropped sockets.
/// On web, connects through `package:web_socket_channel`.
DaemonFrameChannel connectWebSocketFrameChannel(
  Uri uri, {
  required Duration connectTimeout,
  Duration? pingInterval,
}) => platform.connectWebSocketFrameChannel(
  uri,
  connectTimeout: connectTimeout,
  pingInterval: pingInterval,
);
