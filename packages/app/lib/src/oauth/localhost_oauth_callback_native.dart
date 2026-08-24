import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'localhost_oauth_callback_contract.dart';

const bool localhostOAuthCallbackSupported = true;

Future<LocalhostOAuthCallback> startLocalhostOAuthCallback() async {
  final HttpServer server = await HttpServer.bind(
    InternetAddress.loopbackIPv4,
    0,
  );
  return _NativeLocalhostOAuthCallback(server);
}

class _NativeLocalhostOAuthCallback implements LocalhostOAuthCallback {
  _NativeLocalhostOAuthCallback(this._server) {
    _subscription = _server.listen(_handleRequest);
  }

  final HttpServer _server;
  final Completer<Uri> _callback = Completer<Uri>();
  late final StreamSubscription<HttpRequest> _subscription;
  String? _expectedState;
  HttpRequest? _pendingRequest;
  bool _closed = false;

  @override
  Uri get redirectUri => Uri(
    scheme: 'http',
    host: 'localhost',
    port: _server.port,
    path: '/oauth/callback',
  );

  @override
  Future<Uri> waitForCallback(String flowId) {
    if (_closed) {
      return Future<Uri>.error(
        StateError('The localhost OAuth listener is closed'),
      );
    }
    _expectedState = flowId;
    return _callback.future;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (request.method != 'GET' || request.uri.path != '/oauth/callback') {
      await _writePage(
        request,
        HttpStatus.notFound,
        'Not found',
        'This listener accepts only the SpeedDial OAuth callback.',
      );
      return;
    }
    final String? expectedState = _expectedState;
    if (expectedState == null ||
        request.uri.queryParameters['state'] != expectedState) {
      await _writePage(
        request,
        HttpStatus.badRequest,
        'Authorization failed',
        'The OAuth state did not match the active SpeedDial request.',
      );
      return;
    }
    if (_pendingRequest != null || _callback.isCompleted) {
      await _writePage(
        request,
        HttpStatus.conflict,
        'Authorization already received',
        'Return to SpeedDial to see the result.',
      );
      return;
    }
    _pendingRequest = request;
    _callback.complete(redirectUri.replace(query: request.uri.query));
  }

  @override
  Future<void> respondSuccess() => _respond(
    HttpStatus.ok,
    'Authorization complete',
    'SpeedDial can now use this MCP server. You may close this tab.',
  );

  @override
  Future<void> respondError(String message) =>
      _respond(HttpStatus.badRequest, 'Authorization failed', message);

  Future<void> _respond(int status, String title, String message) async {
    final HttpRequest? request = _pendingRequest;
    _pendingRequest = null;
    if (request == null) return;
    await _writePage(request, status, title, message);
  }

  Future<void> _writePage(
    HttpRequest request,
    int status,
    String title,
    String message,
  ) async {
    const HtmlEscape escape = HtmlEscape();
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.html
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
      ..headers.set('X-Content-Type-Options', 'nosniff')
      ..write('''<!doctype html>
<html><head><meta charset="utf-8"><title>${escape.convert(title)}</title></head>
<body style="font:16px system-ui;max-width:640px;margin:64px auto;padding:0 24px">
<h1>${escape.convert(title)}</h1><p>${escape.convert(message)}</p>
</body></html>''');
    await request.response.close();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final HttpRequest? request = _pendingRequest;
    _pendingRequest = null;
    if (request != null) {
      await _writePage(
        request,
        HttpStatus.badRequest,
        'Authorization cancelled',
        'The SpeedDial authorization window was closed.',
      );
    }
    if (!_callback.isCompleted && _expectedState != null) {
      _callback.completeError(
        StateError('The localhost OAuth listener was closed'),
      );
    }
    await _subscription.cancel();
    await _server.close(force: true);
  }
}
