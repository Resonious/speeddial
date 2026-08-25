import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../scope.dart';
import '../state/sessions_store.dart';

enum WearLaunchDestination { attention, session }

@immutable
class WearLaunchTarget {
  const WearLaunchTarget.attention()
    : destination = WearLaunchDestination.attention,
      daemonId = null,
      projectId = null,
      sessionId = null;

  const WearLaunchTarget.session({
    required this.daemonId,
    required this.projectId,
    required this.sessionId,
  }) : destination = WearLaunchDestination.session;

  final WearLaunchDestination destination;
  final String? daemonId;
  final String? projectId;
  final String? sessionId;

  static WearLaunchTarget? tryParse(Object? value) {
    if (value is! Map<Object?, Object?>) return null;
    final Object? destination = value['wearDestination'];
    if (destination == 'attention') {
      return const WearLaunchTarget.attention();
    }
    if (destination != 'session') return null;
    final Object? daemonId = value['daemonId'];
    final Object? projectId = value['projectId'];
    final Object? sessionId = value['sessionId'];
    if (daemonId is! String ||
        daemonId.isEmpty ||
        projectId is! String ||
        projectId.isEmpty ||
        sessionId is! String ||
        sessionId.isEmpty) {
      return null;
    }
    return WearLaunchTarget.session(
      daemonId: daemonId,
      projectId: projectId,
      sessionId: sessionId,
    );
  }
}

String buildCompanionSessionPayload(
  SessionsStore sessions, {
  Set<String>? daemonIds,
}) => jsonEncode(<String, Object?>{
  'version': 1,
  if (daemonIds != null) 'daemonIds': daemonIds.toList()..sort(),
  'sessions': <Object?>[
    for (final RecentSession recent in sessions.recentSessions(
      daemonIds: daemonIds,
    ))
      <String, Object?>{
        'daemonId': recent.daemonId,
        'sessionId': recent.session.id,
        'projectId': recent.session.projectId,
        'title': recent.session.title,
        'status': recent.session.status.wire,
        'lastActivityAtMs':
            recent.session.lastActivityAt.millisecondsSinceEpoch,
        'done': recent.done,
      },
  ],
});

class CompanionEndpointSync {
  CompanionEndpointSync({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'sh.speeddial/companion';
  final MethodChannel _channel;
  ConnectionsStore? _publishedConnections;
  SessionsStore? _publishedSessions;
  VoidCallback? _endpointListener;
  VoidCallback? _sessionListener;
  String? _lastEndpointPayload;
  String? _lastSessionPayload;
  Future<void> Function()? _sessionSyncAction;
  bool _sessionSyncPending = false;
  bool _sessionSyncInFlight = false;
  Set<String> _authoritativeWatchDaemonIds = <String>{};
  final StreamController<WearLaunchTarget> _launchTargets =
      StreamController<WearLaunchTarget>.broadcast(sync: true);

  Stream<WearLaunchTarget> get launchTargets => _launchTargets.stream;

  Future<void> startPhone(
    ConnectionsStore connections,
    SessionsStore sessions,
  ) async {
    _publishedConnections = connections;
    _publishedSessions = sessions;
    _sessionSyncAction = () => _publishSessions(connections, sessions);
    void endpointListener() {
      final String payload = _buildEndpointPayload(connections);
      final bool definitionsChanged = payload != _lastEndpointPayload;
      unawaited(_publishEndpoints(connections, payload: payload));
      if (definitionsChanged ||
          _lastSessionPayload != null ||
          connections.endpoints.isEmpty) {
        _queueSessionSync();
      }
    }

    void sessionListener() {
      _queueSessionSync();
    }

    _endpointListener = endpointListener;
    _sessionListener = sessionListener;
    connections.addListener(endpointListener);
    sessions.addListener(sessionListener);
    await _publishEndpoints(connections);
    if (connections.endpoints.isEmpty) {
      await _publishSessions(connections, sessions);
    }
  }

  Future<void> startWatch(
    ConnectionsStore connections,
    SessionsStore sessions,
  ) async {
    _publishedSessions = sessions;
    _sessionSyncAction = () =>
        _cacheWatchSessions(sessions, daemonIds: _authoritativeWatchDaemonIds);
    void sessionListener() {
      _queueSessionSync();
    }

    _sessionListener = sessionListener;
    sessions.addListener(sessionListener);
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'endpointsChanged') {
        await _applyPayload(connections, call.arguments);
        return;
      }
      if (call.method == 'launchTarget') {
        final WearLaunchTarget? target = WearLaunchTarget.tryParse(
          call.arguments,
        );
        if (target != null) _launchTargets.add(target);
      }
    });
    await refreshWatch(connections);
  }

  Future<WearLaunchTarget?> takeLaunchTarget() async {
    try {
      final Object? value = await _channel.invokeMethod<Object?>(
        'takeLaunchTarget',
      );
      return WearLaunchTarget.tryParse(value);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      debugPrint('Wear launch target read failed: $error');
      return null;
    }
  }

  /// Loads the complete all-project session listing for every reachable watch
  /// endpoint, then marks those daemon slices as authoritative for the native
  /// Tile/complication cache. A failed daemon is deliberately omitted from the
  /// authoritative set so its last phone snapshot remains available offline.
  Future<void> refreshWatchSessions(AppData data) async {
    await data.connectAll();
    final Set<String> refreshedDaemonIds = <String>{};
    for (final DaemonEndpoint endpoint in data.connections.endpoints) {
      try {
        await data.sessions.refresh(endpoint.id);
        refreshedDaemonIds.add(endpoint.id);
      } on Object catch (error) {
        debugPrint(
          'Wear all-project session refresh failed for ${endpoint.id}: $error',
        );
      }
    }
    _authoritativeWatchDaemonIds = refreshedDaemonIds;
    await _cacheWatchSessions(
      data.sessions,
      daemonIds: _authoritativeWatchDaemonIds,
    );
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

  String _buildEndpointPayload(ConnectionsStore connections) =>
      jsonEncode(<Object?>[
        for (final DaemonEndpoint endpoint in connections.endpoints)
          if (!endpoint.embedded) endpoint.toJson(),
      ]);

  Future<void> _publishEndpoints(
    ConnectionsStore connections, {
    String? payload,
  }) async {
    payload ??= _buildEndpointPayload(connections);
    if (payload == _lastEndpointPayload) return;
    try {
      await _channel.invokeMethod<void>('publishEndpoints', <String, Object?>{
        'payload': payload,
        'revision': DateTime.now().microsecondsSinceEpoch,
      });
      _lastEndpointPayload = payload;
    } on MissingPluginException {
      return;
    } on PlatformException catch (error) {
      debugPrint('Wear endpoint publish failed: $error');
    }
  }

  Future<void> _publishSessions(
    ConnectionsStore connections,
    SessionsStore sessions,
  ) async {
    final Set<String> daemonIds = <String>{
      for (final DaemonEndpoint endpoint in connections.endpoints)
        if (!endpoint.embedded) endpoint.id,
    };
    final String payload = buildCompanionSessionPayload(
      sessions,
      daemonIds: daemonIds,
    );
    if (payload == _lastSessionPayload) return;
    try {
      await _channel.invokeMethod<void>('publishSessions', <String, Object?>{
        'payload': payload,
        'revision': DateTime.now().microsecondsSinceEpoch,
      });
      _lastSessionPayload = payload;
    } on MissingPluginException {
      return;
    } on PlatformException catch (error) {
      debugPrint('Wear session publish failed: $error');
    }
  }

  Future<void> _cacheWatchSessions(
    SessionsStore sessions, {
    required Set<String> daemonIds,
  }) async {
    final String payload = buildCompanionSessionPayload(
      sessions,
      daemonIds: daemonIds,
    );
    if (payload == _lastSessionPayload) return;
    try {
      await _channel.invokeMethod<void>('cacheSessions', payload);
      _lastSessionPayload = payload;
    } on MissingPluginException {
      return;
    } on PlatformException catch (error) {
      debugPrint('Wear session cache failed: $error');
    }
  }

  void _queueSessionSync() {
    _sessionSyncPending = true;
    if (_sessionSyncInFlight) return;
    _sessionSyncInFlight = true;
    unawaited(_drainSessionSync());
  }

  Future<void> _drainSessionSync() async {
    try {
      while (_sessionSyncPending) {
        _sessionSyncPending = false;
        await _sessionSyncAction?.call();
      }
    } finally {
      _sessionSyncInFlight = false;
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
    final VoidCallback? endpointListener = _endpointListener;
    if (connections != null && endpointListener != null) {
      connections.removeListener(endpointListener);
    }
    final SessionsStore? sessions = _publishedSessions;
    final VoidCallback? sessionListener = _sessionListener;
    if (sessions != null && sessionListener != null) {
      sessions.removeListener(sessionListener);
    }
    _publishedConnections = null;
    _publishedSessions = null;
    _endpointListener = null;
    _sessionListener = null;
    _sessionSyncAction = null;
    _sessionSyncPending = false;
    _authoritativeWatchDaemonIds = <String>{};
    _channel.setMethodCallHandler(null);
    unawaited(_launchTargets.close());
  }
}
