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
  test('discovers metadata whose issuer is an upstream provider', () async {
    final Directory tempDir = await Directory.systemTemp.createTemp(
      'mcp_oauth_issuer_test',
    );
    final DaemonStore store = DaemonStore(p.join(tempDir.path, 'speeddial.db'));
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final Uri base = Uri.parse('http://127.0.0.1:${server.port}');
    final StreamSubscription<HttpRequest> requests = server.listen((
      HttpRequest request,
    ) {
      unawaited(() async {
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        switch (request.uri.path) {
          case '/mcp':
            request.response
              ..statusCode = HttpStatus.unauthorized
              ..headers.set(
                HttpHeaders.wwwAuthenticateHeader,
                'Bearer resource_metadata="'
                '${base.resolve('/.well-known/oauth-protected-resource')}"',
              );
          case '/.well-known/oauth-protected-resource':
            request.response.write(
              jsonEncode(<String, Object?>{
                'resource': base.resolve('/mcp').toString(),
                'authorization_servers': <String>[
                  base.resolve('/auth0-proxy').toString(),
                ],
              }),
            );
          case '/auth0-proxy/.well-known/openid-configuration':
            request.response.write(
              jsonEncode(<String, Object?>{
                'issuer': base.resolve('/auth0-tenant/').toString(),
                'authorization_endpoint': base
                    .resolve('/auth0-proxy/authorize')
                    .toString(),
                'token_endpoint': base
                    .resolve('/auth0-tenant/oauth/token')
                    .toString(),
                'registration_endpoint': base
                    .resolve('/auth0-tenant/oidc/register')
                    .toString(),
                'code_challenge_methods_supported': const <String>['S256'],
              }),
            );
          case '/auth0-tenant/oidc/register':
            request.response.write(
              jsonEncode(<String, Object?>{
                'client_id': 'dynamic-client-id',
                'token_endpoint_auth_method': 'none',
              }),
            );
          default:
            request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      }());
    });
    final McpOAuthService service = McpOAuthService(
      store: store,
      onChanged: (String _) async {},
    );
    addTearDown(() async {
      service.close();
      await requests.cancel();
      await server.close(force: true);
      store.dispose();
      await tempDir.delete(recursive: true);
    });

    const String serverId = 'proxied-server';
    final DateTime now = DateTime.now().toUtc();
    store.insertMcpServer(
      McpServerProfile(
        id: serverId,
        name: 'Proxied OAuth server',
        transport: McpTransport.http,
        enabled: true,
        url: base.resolve('/mcp').toString(),
        authType: McpAuthType.oauth,
        secretNames: const <String>[],
        createdAt: now,
        updatedAt: now,
      ),
      const <String, String>{},
    );

    final McpOAuthFlow flow = await service.begin(
      serverId,
      Uri.parse('http://127.0.0.1:7331/oauth/callback'),
    );

    final Uri authorizationUrl = Uri.parse(flow.authorizationUrl);
    expect(
      '${authorizationUrl.scheme}://${authorizationUrl.authority}'
      '${authorizationUrl.path}',
      base.resolve('/auth0-proxy/authorize').toString(),
    );
    expect(
      authorizationUrl.queryParameters['client_id'],
      'dynamic-client-id',
    );
    expect(
      authorizationUrl.queryParameters['resource'],
      base.resolve('/mcp').toString(),
    );
    final StoredMcpOAuth oauth = store.getMcpOAuth(serverId)!;
    expect(oauth.status, McpOAuthStatus.authorizing);
    expect(
      oauth.tokenEndpoint,
      base.resolve('/auth0-tenant/oauth/token').toString(),
    );
  });

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
