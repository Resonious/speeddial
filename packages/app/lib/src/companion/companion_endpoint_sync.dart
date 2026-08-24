import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../scope.dart';

class CompanionEndpointSync {
  CompanionEndpointSync({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'sh.speeddial/companion';
  final MethodChannel _channel;
  ConnectionsStore? _publishedConnections;
  VoidCallback? _publishListener;
  String? _lastPublishedPayload;

  Future<void> startPhone(ConnectionsStore connections) async {
    _publishedConnections = connections;
    void listener() {
      unawaited(_publish(connections));
    }

    _publishListener = listener;
    connections.addListener(listener);
    await _publish(connections);
  }

  Future<void> startWatch(ConnectionsStore connections) async {
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method != 'endpointsChanged') return;
      await _applyPayload(connections, call.arguments);
    });
    await refreshWatch(connections);
  }

  Future<void> refreshWatch(ConnectionsStore connections) async {
    try {
      final Object? payload = await _channel.invokeMethod<Object?>(
        'getEndpoints',
      );
      await _applyPayload(connections, payload);
    } on MissingPluginException {
      return;
    } on PlatformException catch (error) {
      debugPrint('Wear endpoint refresh failed: $error');
    }
  }

  Future<void> _publish(ConnectionsStore connections) async {
    final String payload = jsonEncode(<Object?>[
      for (final DaemonEndpoint endpoint in connections.endpoints)
        if (!endpoint.embedded) endpoint.toJson(),
    ]);
    if (payload == _lastPublishedPayload) return;
    try {
      await _channel.invokeMethod<void>('publishEndpoints', <String, Object?>{
        'payload': payload,
        'revision': DateTime.now().microsecondsSinceEpoch,
      });
      _lastPublishedPayload = payload;
    } on MissingPluginException {
      return;
    } on PlatformException catch (error) {
      debugPrint('Wear endpoint publish failed: $error');
    }
  }

  Future<void> _applyPayload(
    ConnectionsStore connections,
    Object? rawPayload,
  ) async {
    if (rawPayload is! String || rawPayload.isEmpty) return;
    final Object? decoded = jsonDecode(rawPayload);
    if (decoded is! List<Object?>) {
      throw const FormatException('Companion endpoint payload must be a list');
    }
    await connections.replaceEndpoints(<DaemonEndpoint>[
      for (final Object? item in decoded)
        if (item is Map<Object?, Object?>)
          DaemonEndpoint.fromJson(item.cast<String, Object?>()),
    ]);
  }

  void dispose() {
    final ConnectionsStore? connections = _publishedConnections;
    final VoidCallback? listener = _publishListener;
    if (connections != null && listener != null) {
      connections.removeListener(listener);
    }
    _publishedConnections = null;
    _publishListener = null;
    _channel.setMethodCallHandler(null);
  }
}
