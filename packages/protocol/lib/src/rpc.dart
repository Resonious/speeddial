/// JSON-RPC 2.0 peer over an abstract message stream.
///
/// The peer is transport-agnostic: [RpcPeer.incoming] yields decoded JSON
/// values (each a `Map<String, Object?>`), and the `send` callback is invoked
/// with encodable maps for every outbound message. It handles both sides of
/// the protocol: making calls/notifications (client role) and answering
/// registered methods (server role).
library;

import 'dart:async';

import 'errors.dart';

/// JSON-RPC code: no method matched the request.
const int _kErrMethodNotFound = -32601;

/// JSON-RPC code: internal error / application failure.
const int _kErrInternal = -32603;

/// An inbound notification (`{"method": "...", "params": {...}}`, no id).
class RpcNotification {
  const RpcNotification({required this.method, required this.params});

  final String method;
  final Map<String, Object?> params;
}

/// A JSON-RPC 2.0 endpoint bound to one message channel.
///
/// `incoming` must deliver decoded frames; `send` is called with frames to
/// write (including for responses to incoming requests). Malformed incoming
/// values are ignored and never fatal.
class RpcPeer {
  RpcPeer({
    required Stream<Object?> incoming,
    required void Function(Object? message) send,
  })  : _incoming = incoming, // ignore: prefer_initializing_formals — public API name
        _send = send { // ignore: prefer_initializing_formals — public API name
    _incomingSub = _incoming.listen(_handleIncoming);
  }

  final Stream<Object?> _incoming;
  final void Function(Object? message) _send;

  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};
  final Map<String, FutureOr<Object?> Function(Map<String, Object?>)> _handlers =
      <String, FutureOr<Object?> Function(Map<String, Object?>)>{};
  final StreamController<RpcNotification> _notificationController =
      StreamController<RpcNotification>(sync: true);

  late final StreamSubscription<Object?> _incomingSub;
  int _nextId = 1;
  bool _closed = false;
  Future<void>? _closedResult;

  /// Inbound notifications that have no registered handler. Emits done after
  /// [close].
  Stream<RpcNotification> get notifications => _notificationController.stream;

  /// Sends a request and completes with the JSON-RPC `result`, or throws
  /// [DaemonError] built from the response `error.code`/`message`/`data`.
  ///
  /// Ids are incrementing ints starting at 1.
  Future<Object?> call(String method, [Map<String, Object?> params = const {}]) {
    if (_closed) {
      return Future<Object?>.error(DaemonError(_kErrInternal, 'peer closed'));
    }
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _send(<String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });
    return completer.future;
  }

  /// Sends a one-way message; the remote side sees it on `notifications`
  /// (unless it registered a handler for [method]).
  void notify(String method, [Map<String, Object?> params = const {}]) {
    _send(<String, Object?>{
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
    });
  }

  /// Registers a handler answering requests for [method].
  ///
  /// A normal return becomes the `result`; a thrown [DaemonError] becomes the
  /// matching error with its code/message/data; any other throw becomes
  /// `-32603` "Internal error". Unregistered methods are answered with
  /// `-32601`.
  void registerHandler(
    String method,
    FutureOr<Object?> Function(Map<String, Object?>) handler,
  ) {
    _handlers[method] = handler;
  }

  /// Completes all pending calls with `DaemonError(-32603, 'peer closed')` and
  /// closes the notifications stream. Idempotent.
  ///
  /// Returns immediately: it never awaits the incoming stream (whose source
  /// may stay open indefinitely) or any other external event. The same
  /// completed future is returned on every subsequent call.
  Future<void> close() {
    if (_closed) return _closedResult!;
    _closed = true;
    final pending = _pending.values.toList(growable: false);
    _pending.clear();
    for (final completer in pending) {
      completer.completeError(DaemonError(_kErrInternal, 'peer closed'));
    }
    // Fire-and-forget teardown: do not await cancellation or closing, which
    // could never complete if the source stream stays open. `done` is still
    // emitted to notifications listeners.
    unawaited(_incomingSub.cancel());
    unawaited(_notificationController.close());
    return _closedResult = Future<void>.value();
  }

  void _handleIncoming(Object? message) {
    if (message is! Map) return; // Malformed: ignore.
    final id = message['id'];
    final method = message['method'];
    final isResponse =
        message.containsKey('result') || message.containsKey('error');

    if (id != null) {
      if (isResponse) {
        _completeCall(id, message);
      } else if (method is String) {
        _handleRequest(id, method, message['params']);
      }
      // Malformed request/response: ignore.
      return;
    }

    if (method is String) {
      final handler = _handlers[method];
      final paramsMap = _paramsMap(message['params']);
      if (handler != null) {
        // Notification routed to the registered handler; no reply is sent.
        unawaited(_runHandler(handler, paramsMap));
      } else {
        _emitNotification(method, paramsMap);
      }
    }
    // Else: malformed notification: ignore.
  }

  void _completeCall(Object? id, Map<dynamic, dynamic> message) {
    final completer = _pending.remove(id);
    if (completer == null) return; // Stale/unknown id: ignore.
    final error = message['error'];
    if (error is Map) {
      final code = error['code'];
      final errorMessage = error['message'];
      if (code is int && errorMessage is String) {
        completer.completeError(
            DaemonError(code, errorMessage, error['data']));
      } else {
        completer
            .completeError(DaemonError(_kErrInternal, 'malformed error', error));
      }
    } else if (message.containsKey('error')) {
      completer
          .completeError(DaemonError(_kErrInternal, 'malformed error', error));
    } else {
      completer.complete(message['result']);
    }
  }

  void _handleRequest(Object? id, String method, Object? params) {
    final handler = _handlers[method];
    if (handler == null) {
      _sendResponse(
          id, code: _kErrMethodNotFound, message: 'Method not found');
      return;
    }
    unawaited(_runHandler(handler, _paramsMap(params), responseTo: id));
  }

  /// Coerces a decoded `params` field to `Map<String, Object?>`; anything that
  /// is not a JSON object/Map becomes an empty map.
  static Map<String, Object?> _paramsMap(Object? params) =>
      params is Map ? Map<String, Object?>.from(params) : <String, Object?>{};

  Future<void> _runHandler(
    FutureOr<Object?> Function(Map<String, Object?>) handler,
    Map<String, Object?> params, {
    Object? responseTo,
  }) async {
    try {
      final result = await handler(params);
      if (responseTo != null) _sendResponse(responseTo, result: result);
    } on DaemonError catch (e) {
      if (responseTo != null) {
        _sendResponse(responseTo, code: e.code, message: e.message, data: e.data);
      }
    } catch (_) {
      if (responseTo != null) {
        _sendResponse(responseTo, code: _kErrInternal, message: 'Internal error');
      }
    }
  }

  void _emitNotification(String method, Object? params) {
    _notificationController
        .add(RpcNotification(method: method, params: _paramsMap(params)));
  }

  void _sendResponse(
    Object? id, {
    Object? result,
    int? code,
    String? message,
    Object? data,
  }) {
    if (code != null) {
      _send(<String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'error': <String, Object?>{
          'code': code,
          'message': message!,
          'data': ?data,
        },
      });
    } else {
      _send(<String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'result': result,
      });
    }
  }
}
