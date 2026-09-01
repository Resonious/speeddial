@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_daemon/src/server/mcp_oauth_service.dart';
import 'package:speeddial_daemon/src/store/daemon_store.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('identical OAuth refresh failures notify only once', () async {
    final Directory tempDir = await Directory.systemTemp.createTemp(
      'mcp_oauth_service_test',
    );
    final DaemonStore store = DaemonStore(p.join(tempDir.path, 'speeddial.db'));
    final HttpServer tokenServer = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    var refreshAttempts = 0;
    final StreamSubscription<HttpRequest> requests = tokenServer.listen((
      HttpRequest request,
    ) {
      unawaited(() async {
        refreshAttempts++;
        await request.drain<void>();
        request.response
          ..statusCode = HttpStatus.badRequest
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode(<String, String>{
              'error': 'invalid_grant',
              'error_description':
                  'refresh token is expired, revoked, or already rotated',
            }),
          );
        await request.response.close();
      }());
    });
    var changes = 0;
    final McpOAuthService service = McpOAuthService(
      store: store,
      onChanged: (String _) async {
        changes++;
      },
    );
    addTearDown(() async {
      service.close();
      await requests.cancel();
      await tokenServer.close(force: true);
      store.dispose();
      await tempDir.delete(recursive: true);
    });

    final Uri tokenEndpoint = Uri.parse(
      'http://127.0.0.1:${tokenServer.port}/token',
    );
    final DateTime now = DateTime.now().toUtc();
    const String serverId = 'oauth-server';
    store.insertMcpServer(
      McpServerProfile(
        id: serverId,
        name: 'OAuth server',
        transport: McpTransport.http,
        enabled: true,
        url: 'http://127.0.0.1:${tokenServer.port}/mcp',
        authType: McpAuthType.oauth,
        secretNames: const <String>[],
        createdAt: now,
        updatedAt: now,
      ),
      const <String, String>{},
    );
    store.setMcpOAuthDiscovery(
      serverId,
      authorizationServer: 'http://127.0.0.1:${tokenServer.port}',
      authorizationEndpoint: 'http://127.0.0.1:${tokenServer.port}/authorize',
      tokenEndpoint: tokenEndpoint.toString(),
      resource: 'http://127.0.0.1:${tokenServer.port}/mcp',
    );
    store.setMcpOAuthClient(
      serverId,
      clientId: 'client-id',
      tokenEndpointAuthMethod: 'none',
      redirectUri: 'http://127.0.0.1:7331/oauth/callback',
    );
    store.setMcpOAuthTokens(
      serverId,
      accessToken: 'expired-access-token',
      refreshToken: 'expired-refresh-token',
      expiresAt: now.subtract(const Duration(minutes: 1)),
      scopes: const <String>['mcp:tools'],
    );

    await service.refreshEnabled();
    await service.refreshEnabled();

    expect(refreshAttempts, 2, reason: 'transient failures remain retryable');
    expect(changes, 1, reason: 'unchanged failures must not reload sessions');
    final StoredMcpOAuth oauth = store.getMcpOAuth(serverId)!;
    expect(oauth.status, McpOAuthStatus.error);
    expect(
      oauth.error,
      'Token refresh failed: '
      'refresh token is expired, revoked, or already rotated',
    );
  });
}
