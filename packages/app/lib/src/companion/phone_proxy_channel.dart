import 'dart:async';

import 'package:flutter/services.dart';

import '../api/ws_daemon_client.dart';

/// Creates daemon frame channels that ask the paired Android phone to open
/// the real WebSocket.
///
/// The phone-side native service owns the socket, so its traffic follows the
/// phone's active network and VPN routes (including Tailscale). Frames cross
/// the Wear Data Layer's bidirectional ChannelClient stream.
class PhoneProxyChannelFactory {
  PhoneProxyChannelFactory({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName) {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  static const String _channelName = 'sh.speeddial/phone_proxy';

  final MethodChannel _channel;
  final Map<String, _PhoneProxyDaemonFrameChannel> _connections =
      <String, _PhoneProxyDaemonFrameChannel>{};
  int _nextId = 0;
  bool _disposed = false;

  DaemonFrameChannel connect(Uri uri) {
    if (_disposed) {
      throw StateError('Phone proxy channel factory is disposed');
    }
    final String id = 'proxy-${_nextId++}';
    final _PhoneProxyDaemonFrameChannel connection =
        _PhoneProxyDaemonFrameChannel(
          id: id,
          uri: uri,
          channel: _channel,
          onClosed: () => _connections.remove(id),
        );
    _connections[id] = connection;
    return connection;
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    final Object? rawArguments = call.arguments;
    if (rawArguments is! Map<Object?, Object?>) return;
    final String? id = rawArguments['id'] as String?;
    if (id == null) return;
    final _PhoneProxyDaemonFrameChannel? connection = _connections[id];
    if (connection == null) return;
    switch (call.method) {
      case 'proxyFrame':
        final String? payload = rawArguments['payload'] as String?;
        if (payload != null) connection.addIncoming(payload);
      case 'proxyClosed':
        connection.remoteClosed(rawArguments['error'] as String?);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _channel.setMethodCallHandler(null);
    final List<_PhoneProxyDaemonFrameChannel> connections = _connections.values
        .toList(growable: false);
    _connections.clear();
    await Future.wait<void>(<Future<void>>[
      for (final connection in connections) connection.close(),
    ]);
  }
}

class _PhoneProxyDaemonFrameChannel implements DaemonFrameChannel {
  _PhoneProxyDaemonFrameChannel({
    required this.id,
    required Uri uri,
    required this._channel,
    required this._onClosed,
  }) {
    unawaited(_open(uri));
  }

  final String id;
  final MethodChannel _channel;
  final VoidCallback _onClosed;
  final Completer<void> _ready = Completer<void>();
  final StreamController<Object?> _incoming = StreamController<Object?>();
  bool _closed = false;

  Future<void> _open(Uri uri) async {
    try {
      await _channel.invokeMethod<void>('openProxy', <String, Object?>{
        'id': id,
        'url': uri.toString(),
      });
      if (!_closed && !_ready.isCompleted) _ready.complete();
    } on Object catch (error, stackTrace) {
      _fail(error, stackTrace);
    }
  }

  @override
  Future<void> get ready => _ready.future;

  @override
  Stream<Object?> get stream => _incoming.stream;

  @override
  void add(Object? data) {
    if (_closed) return;
    if (data is! String) {
      throw UnsupportedError(
        'The phone proxy supports daemon text frames only',
      );
    }
    unawaited(
      _channel
          .invokeMethod<void>('sendProxyFrame', <String, Object?>{
            'id': id,
            'payload': data,
          })
          .catchError((Object error, StackTrace stackTrace) {
            _fail(error, stackTrace);
          }),
    );
  }

  void addIncoming(String payload) {
    if (!_closed) _incoming.add(payload);
  }

  void remoteClosed(String? error) {
    if (_closed) return;
    if (error != null && error.isNotEmpty) {
      _fail(PlatformException(code: 'phone_proxy_closed', message: error));
    } else {
      unawaited(_finish(notifyNative: false));
    }
  }

  void _fail(Object error, [StackTrace? stackTrace]) {
    if (_closed) return;
    if (!_ready.isCompleted) _ready.completeError(error, stackTrace);
    _incoming.addError(error, stackTrace);
    unawaited(_finish(notifyNative: false));
  }

  @override
  Future<void> close() => _finish();

  Future<void> _finish({bool notifyNative = true}) async {
    if (_closed) return;
    _closed = true;
    _onClosed();
    if (!_ready.isCompleted) {
      _ready.completeError(
        StateError('Phone proxy closed before it was ready'),
      );
    }
    if (notifyNative) {
      try {
        await _channel.invokeMethod<void>('closeProxy', <String, Object?>{
          'id': id,
        });
      } on Object {
        // The phone link is already gone; local teardown is still complete.
      }
    }
    await _incoming.close();
  }
}
