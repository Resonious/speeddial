import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/oauth/localhost_oauth_callback.dart';

void main() {
  test(
    'receives one matching localhost callback and renders success',
    () async {
      final LocalhostOAuthCallback callback =
          await startLocalhostOAuthCallback();
      addTearDown(callback.close);
      expect(callback.redirectUri.scheme, 'http');
      expect(callback.redirectUri.host, 'localhost');
      expect(callback.redirectUri.path, '/oauth/callback');
      expect(callback.redirectUri.hasPort, isTrue);

      final Future<Uri> received = callback.waitForCallback('flow-1');
      final HttpClient browser = HttpClient();
      addTearDown(() => browser.close(force: true));
      final Uri requestUri = callback.redirectUri.replace(
        host: '127.0.0.1',
        queryParameters: const <String, String>{
          'code': 'authorization-code',
          'state': 'flow-1',
        },
      );
      final Future<HttpClientResponse> responseFuture = browser
          .getUrl(requestUri)
          .then((HttpClientRequest request) => request.close());

      final Uri callbackUri = await received;
      expect(callbackUri.host, 'localhost');
      expect(callbackUri.queryParameters['code'], 'authorization-code');
      expect(callbackUri.queryParameters['state'], 'flow-1');
      await callback.respondSuccess();

      final HttpClientResponse response = await responseFuture;
      final String body = await utf8.decoder.bind(response).join();
      expect(response.statusCode, HttpStatus.ok);
      expect(body, contains('Authorization complete'));
    },
  );

  test('rejects a callback with the wrong OAuth state', () async {
    final LocalhostOAuthCallback callback = await startLocalhostOAuthCallback();
    addTearDown(callback.close);
    callback.waitForCallback('expected-flow').ignore();
    final HttpClient browser = HttpClient();
    addTearDown(() => browser.close(force: true));
    final HttpClientResponse response = await browser
        .getUrl(
          callback.redirectUri.replace(
            host: '127.0.0.1',
            queryParameters: const <String, String>{
              'code': 'authorization-code',
              'state': 'wrong-flow',
            },
          ),
        )
        .then((HttpClientRequest request) => request.close());
    final String body = await utf8.decoder.bind(response).join();

    expect(response.statusCode, HttpStatus.badRequest);
    expect(body, contains('state did not match'));
  });
}
