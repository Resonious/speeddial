import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:speeddial_daemon/src/store/daemon_store.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

const Duration _requestTimeout = Duration(seconds: 15);
const Duration _flowLifetime = Duration(minutes: 10);
const Duration _refreshSkew = Duration(minutes: 1);
const int _maxResponseBytes = 1024 * 1024;

/// OAuth 2.1 authorization-code + PKCE lifecycle for HTTP MCP profiles.
///
/// Discovery follows MCP 2025-11-25: RFC 9728 protected-resource metadata,
/// RFC 8414 / OIDC authorization-server metadata, S256 PKCE, RFC 8707
/// resource indicators, pre-registered clients, and RFC 7591 dynamic client
/// registration. Tokens remain in [DaemonStore] and are surfaced only as an
/// injected Authorization header when an ACP session is created or resumed.
class McpOAuthService {
  McpOAuthService({
    required DaemonStore store,
    required Future<void> Function(String serverId) onChanged,
    HttpClient? httpClient,
  }) : _store = store, // ignore: prefer_initializing_formals
       _onChanged = onChanged, // ignore: prefer_initializing_formals
       _http = httpClient ?? HttpClient(),
       _ownsHttpClient = httpClient == null {
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 30),
      (Timer _) => unawaited(refreshEnabled()),
    );
  }

  final DaemonStore _store;
  final Future<void> Function(String serverId) _onChanged;
  final HttpClient _http;
  final bool _ownsHttpClient;
  final Random _random = Random.secure();
  final Map<String, _OAuthFlow> _flows = <String, _OAuthFlow>{};
  late final Timer _refreshTimer;
  Future<void>? _activeRefresh;

  Future<McpOAuthFlow> begin(String serverId, Uri redirectUri) async {
    _discardExpiredFlows();
    _flows.removeWhere(
      (String _, _OAuthFlow flow) => flow.serverId == serverId,
    );
    final McpServerProfile profile = _requireOAuthProfile(serverId);
    _store.setMcpOAuthStatus(serverId, McpOAuthStatus.authorizing);
    try {
      _requireRedirectUri(redirectUri);
      final _Discovery discovery = await _discover(Uri.parse(profile.url!));
      _store.setMcpOAuthDiscovery(
        serverId,
        authorizationServer: discovery.authorizationServer.toString(),
        authorizationEndpoint: discovery.authorizationEndpoint.toString(),
        tokenEndpoint: discovery.tokenEndpoint.toString(),
        resource: discovery.resource.toString(),
        registrationEndpoint: discovery.registrationEndpoint?.toString(),
      );

      StoredMcpOAuth? stored = _store.getMcpOAuth(serverId);
      String? clientId = stored?.clientId;
      String? clientSecret = stored?.clientSecret;
      String? authMethod = stored?.tokenEndpointAuthMethod;
      final bool staleDynamicRegistration =
          clientId != null &&
          stored?.redirectUri != null &&
          stored!.redirectUri != redirectUri.toString();
      if (clientId == null || staleDynamicRegistration) {
        final Uri? registrationEndpoint = discovery.registrationEndpoint;
        if (registrationEndpoint == null) {
          throw const FormatException(
            'Authorization server requires a pre-registered client ID',
          );
        }
        final _ClientRegistration registration = await _registerClient(
          registrationEndpoint,
          redirectUri,
        );
        clientId = registration.clientId;
        clientSecret = registration.clientSecret;
        authMethod = registration.tokenEndpointAuthMethod;
        _store.setMcpOAuthClient(
          serverId,
          clientId: clientId,
          clientSecret: clientSecret,
          tokenEndpointAuthMethod: authMethod,
          redirectUri: redirectUri.toString(),
        );
      }
      if (authMethod == null) {
        if (clientSecret == null) {
          authMethod = 'none';
        } else if (discovery.tokenEndpointAuthMethods.isEmpty ||
            discovery.tokenEndpointAuthMethods.contains(
              'client_secret_basic',
            )) {
          authMethod = 'client_secret_basic';
        } else if (discovery.tokenEndpointAuthMethods.contains(
          'client_secret_post',
        )) {
          authMethod = 'client_secret_post';
        } else {
          throw const FormatException(
            'Authorization server does not support client secret authentication',
          );
        }
      }
      _validateClientAuthentication(authMethod, clientSecret);

      final String flowId = _randomToken(24);
      final String verifier = _randomToken(48);
      final String challenge = base64Url
          .encode(sha256.convert(ascii.encode(verifier)).bytes)
          .replaceAll('=', '');
      final Uri authorizationUrl = _withQuery(
        discovery.authorizationEndpoint,
        <String, String>{
          'response_type': 'code',
          'client_id': clientId,
          'redirect_uri': redirectUri.toString(),
          'code_challenge': challenge,
          'code_challenge_method': 'S256',
          'state': flowId,
          'resource': discovery.resource.toString(),
          if (discovery.scopes.isNotEmpty) 'scope': discovery.scopes.join(' '),
        },
      );
      _flows[flowId] = _OAuthFlow(
        serverId: serverId,
        verifier: verifier,
        createdAt: DateTime.now().toUtc(),
        redirectUri: redirectUri,
        tokenEndpoint: discovery.tokenEndpoint,
        clientId: clientId,
        clientSecret: clientSecret,
        tokenEndpointAuthMethod: authMethod,
        resource: discovery.resource,
        scopes: discovery.scopes,
      );
      return McpOAuthFlow(
        flowId: flowId,
        authorizationUrl: authorizationUrl.toString(),
      );
    } on Object catch (error) {
      final String message = _errorMessage(error);
      _store.setMcpOAuthStatus(serverId, McpOAuthStatus.error, error: message);
      throw DaemonError(kErrProviderUnavailable, message);
    }
  }

  /// Completes a browser redirect received by the daemon's HTTP listener.
  Future<void> handleCallback(HttpRequest request) async {
    final String? state = request.uri.queryParameters['state'];
    _discardExpiredFlows();
    final _OAuthFlow? flow = state == null ? null : _flows[state];
    if (flow == null) {
      await _writeCallbackPage(
        request,
        HttpStatus.badRequest,
        'Authorization expired',
        'Return to SpeedDial and start authorization again.',
      );
      return;
    }

    final Uri callbackUri = flow.redirectUri.replace(query: request.uri.query);
    try {
      await complete(flow.serverId, state!, callbackUri);
      await _writeCallbackPage(
        request,
        HttpStatus.ok,
        'Authorization complete',
        'SpeedDial can now use this MCP server. You may close this tab.',
      );
    } on DaemonError catch (error) {
      await _writeCallbackPage(
        request,
        HttpStatus.badRequest,
        'Authorization failed',
        error.message,
      );
    }
  }

  /// Completes a callback received by a trusted frontend loopback listener.
  ///
  /// The full URI is checked against the redirect URI captured with the flow,
  /// including its unguessable OAuth state, before the authorization code is
  /// exchanged. PKCE material and tokens never leave the daemon.
  Future<void> complete(String serverId, String flowId, Uri callbackUri) async {
    _discardExpiredFlows();
    final _OAuthFlow? flow = _flows[flowId];
    if (flow == null || flow.serverId != serverId) {
      throw DaemonError(kErrNotFound, 'Unknown or expired OAuth flow');
    }
    if (!_matchesRedirect(callbackUri, flow.redirectUri) ||
        callbackUri.queryParameters['state'] != flowId) {
      throw DaemonError(
        kErrConflict,
        'OAuth callback does not match the authorization flow',
      );
    }
    _flows.remove(flowId);

    final String? oauthError = callbackUri.queryParameters['error'];
    if (oauthError != null) {
      final String description =
          callbackUri.queryParameters['error_description'] ?? oauthError;
      _store.setMcpOAuthStatus(
        flow.serverId,
        McpOAuthStatus.error,
        error: description,
      );
      throw DaemonError(kErrProviderUnavailable, description);
    }
    final String? code = callbackUri.queryParameters['code'];
    if (code == null || code.isEmpty) {
      const String message = 'Authorization callback did not include a code';
      _store.setMcpOAuthStatus(
        flow.serverId,
        McpOAuthStatus.error,
        error: message,
      );
      throw const DaemonError(kErrProviderUnavailable, message);
    }

    try {
      final _TokenResponse tokens = await _requestToken(
        flow.tokenEndpoint,
        <String, String>{
          'grant_type': 'authorization_code',
          'code': code,
          'redirect_uri': flow.redirectUri.toString(),
          'client_id': flow.clientId,
          'code_verifier': flow.verifier,
          'resource': flow.resource.toString(),
        },
        clientId: flow.clientId,
        clientSecret: flow.clientSecret,
        authMethod: flow.tokenEndpointAuthMethod,
        fallbackScopes: flow.scopes,
      );
      _store.setMcpOAuthTokens(
        flow.serverId,
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        expiresAt: tokens.expiresAt,
        scopes: tokens.scopes,
      );
      await _onChanged(flow.serverId);
    } on Object catch (error) {
      final String message = _errorMessage(error);
      _store.setMcpOAuthStatus(
        flow.serverId,
        McpOAuthStatus.error,
        error: message,
      );
      throw DaemonError(kErrProviderUnavailable, message);
    }
  }

  bool isAuthorizing(String serverId, String flowId) {
    _discardExpiredFlows();
    return _flows[flowId]?.serverId == serverId;
  }

  Future<void> disconnect(String serverId) async {
    _requireOAuthProfile(serverId);
    _flows.removeWhere(
      (String _, _OAuthFlow flow) => flow.serverId == serverId,
    );
    _store.clearMcpOAuthTokens(serverId);
    await _onChanged(serverId);
  }

  /// Refreshes enabled OAuth profiles whose access token expires imminently.
  /// A failed profile is marked and omitted from ACP configuration; it does
  /// not prevent unrelated sessions or MCP servers from starting.
  Future<void> refreshEnabled() {
    final Future<void>? active = _activeRefresh;
    if (active != null) return active;
    final Future<void> refresh = _refreshEnabled();
    _activeRefresh = refresh;
    return refresh.whenComplete(() {
      if (identical(_activeRefresh, refresh)) _activeRefresh = null;
    });
  }

  Future<void> _refreshEnabled() async {
    final DateTime refreshBefore = DateTime.now().toUtc().add(_refreshSkew);
    for (final McpServerProfile profile in _store.listMcpServers()) {
      if (!profile.enabled || !profile.authType.isOAuth) continue;
      final StoredMcpOAuth? oauth = _store.getMcpOAuth(profile.id);
      if (oauth?.accessToken == null) continue;
      final DateTime? expiresAt = oauth!.expiresAt;
      if (expiresAt == null || expiresAt.isAfter(refreshBefore)) continue;
      if (oauth.refreshToken == null) {
        await _setRefreshFailure(
          profile.id,
          McpOAuthStatus.expired,
          'Access token expired; authorize again',
        );
        continue;
      }
      try {
        final String? tokenEndpoint = oauth.tokenEndpoint;
        final String? clientId = oauth.clientId;
        if (tokenEndpoint == null || clientId == null) {
          throw const FormatException('Stored OAuth metadata is incomplete');
        }
        final _TokenResponse tokens = await _requestToken(
          Uri.parse(tokenEndpoint),
          <String, String>{
            'grant_type': 'refresh_token',
            'refresh_token': oauth.refreshToken!,
            'client_id': clientId,
            'resource': oauth.resource ?? profile.url!,
          },
          clientId: clientId,
          clientSecret: oauth.clientSecret,
          authMethod:
              oauth.tokenEndpointAuthMethod ??
              (oauth.clientSecret == null ? 'none' : 'client_secret_basic'),
          fallbackScopes: oauth.scopes,
        );
        _store.setMcpOAuthTokens(
          profile.id,
          accessToken: tokens.accessToken,
          refreshToken: tokens.refreshToken,
          expiresAt: tokens.expiresAt,
          scopes: tokens.scopes,
        );
        await _onChanged(profile.id);
      } on Object catch (error) {
        await _setRefreshFailure(
          profile.id,
          McpOAuthStatus.error,
          'Token refresh failed: ${_errorMessage(error)}',
        );
      }
    }
  }

  Future<void> _setRefreshFailure(
    String serverId,
    McpOAuthStatus status,
    String error,
  ) async {
    final StoredMcpOAuth? current = _store.getMcpOAuth(serverId);
    if (current?.status == status && current?.error == error) return;
    _store.setMcpOAuthStatus(serverId, status, error: error);
    await _onChanged(serverId);
  }

  void close() {
    _refreshTimer.cancel();
    _flows.clear();
    if (_ownsHttpClient) _http.close(force: true);
  }

  McpServerProfile _requireOAuthProfile(String serverId) {
    final McpServerProfile? profile = _store.getMcpServer(serverId);
    if (profile == null) {
      throw DaemonError(kErrNotFound, 'Unknown MCP server: $serverId');
    }
    if (profile.transport != McpTransport.http || !profile.authType.isOAuth) {
      throw DaemonError(
        kErrConflict,
        'OAuth is available only for HTTP MCP servers configured for OAuth',
      );
    }
    return profile;
  }

  Future<_Discovery> _discover(Uri server) async {
    _requireSecureEndpoint(server, 'MCP server');
    final _Challenge challenge = await _authorizationChallenge(server);
    final List<Uri> resourceMetadataUris = <Uri>[
      if (challenge.resourceMetadata != null) challenge.resourceMetadata!,
      ..._protectedResourceMetadataUris(server),
    ];
    Map<String, Object?>? resourceMetadata;
    Object? lastError;
    for (final Uri uri in resourceMetadataUris.toSet()) {
      try {
        resourceMetadata = await _getJson(uri);
        break;
      } on Object catch (error) {
        lastError = error;
      }
    }
    if (resourceMetadata == null) {
      throw FormatException(
        'MCP protected-resource metadata discovery failed: '
        '${_errorMessage(lastError ?? 'not found')}',
      );
    }
    final List<String> authorizationServers = _stringList(
      resourceMetadata['authorization_servers'],
    );
    if (authorizationServers.isEmpty) {
      throw const FormatException(
        'Protected-resource metadata has no authorization server',
      );
    }
    final Uri authorizationServer = Uri.parse(authorizationServers.first);
    _requireSecureEndpoint(authorizationServer, 'Authorization server');

    Map<String, Object?>? serverMetadata;
    for (final Uri uri in _authorizationMetadataUris(authorizationServer)) {
      try {
        serverMetadata = await _getJson(uri);
        break;
      } on Object catch (error) {
        lastError = error;
      }
    }
    if (serverMetadata == null) {
      throw FormatException(
        'Authorization-server metadata discovery failed: '
        '${_errorMessage(lastError ?? 'not found')}',
      );
    }
    final String? issuer = serverMetadata['issuer'] as String?;
    if (issuer == null ||
        !_sameIssuer(Uri.parse(issuer), authorizationServer)) {
      throw const FormatException(
        'Authorization-server metadata issuer does not match discovery URL',
      );
    }
    final List<String> challengeMethods = _stringList(
      serverMetadata['code_challenge_methods_supported'],
    );
    if (!challengeMethods.contains('S256')) {
      throw const FormatException(
        'Authorization server does not advertise S256 PKCE support',
      );
    }
    final Uri authorizationEndpoint = _requiredEndpoint(
      serverMetadata,
      'authorization_endpoint',
    );
    final Uri tokenEndpoint = _requiredEndpoint(
      serverMetadata,
      'token_endpoint',
    );
    final Uri? registrationEndpoint = _optionalEndpoint(
      serverMetadata,
      'registration_endpoint',
    );
    final List<String> tokenEndpointAuthMethods = _stringList(
      serverMetadata['token_endpoint_auth_methods_supported'],
    );
    final Uri resource = switch (resourceMetadata['resource']) {
      final String value => Uri.parse(value),
      _ => server,
    };
    _requireResourceUri(resource);
    final List<String> metadataScopes = _stringList(
      resourceMetadata['scopes_supported'],
    );
    return _Discovery(
      resource: resource,
      authorizationServer: authorizationServer,
      authorizationEndpoint: authorizationEndpoint,
      tokenEndpoint: tokenEndpoint,
      registrationEndpoint: registrationEndpoint,
      tokenEndpointAuthMethods: tokenEndpointAuthMethods,
      scopes: challenge.scopes.isNotEmpty ? challenge.scopes : metadataScopes,
    );
  }

  Future<_Challenge> _authorizationChallenge(Uri server) async {
    try {
      final HttpClientRequest request = await _http
          .postUrl(server)
          .timeout(_requestTimeout);
      request.headers
        ..contentType = ContentType.json
        ..set(HttpHeaders.acceptHeader, 'application/json, text/event-stream');
      request.write(
        jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'initialize',
          'params': <String, Object?>{
            'protocolVersion': '2025-11-25',
            'capabilities': <String, Object?>{},
            'clientInfo': <String, Object?>{
              'name': 'SpeedDial',
              'version': '0.1.0',
            },
          },
        }),
      );
      final HttpClientResponse response = await request.close().timeout(
        _requestTimeout,
      );
      final List<String> authenticateHeaders =
          response.headers[HttpHeaders.wwwAuthenticateHeader] ??
          const <String>[];
      await _readBody(response);
      final String combined = authenticateHeaders.join(', ');
      final RegExpMatch? metadataMatch = RegExp(
        r'resource_metadata\s*=\s*"([^"]+)"',
        caseSensitive: false,
      ).firstMatch(combined);
      final RegExpMatch? scopeMatch = RegExp(
        r'scope\s*=\s*"([^"]*)"',
        caseSensitive: false,
      ).firstMatch(combined);
      final Uri? resourceMetadata = switch (metadataMatch?.group(1)) {
        final String value => Uri.tryParse(value),
        _ => null,
      };
      if (resourceMetadata != null) {
        _requireSecureEndpoint(resourceMetadata, 'Resource metadata');
      }
      return _Challenge(
        resourceMetadata: resourceMetadata,
        scopes: (scopeMatch?.group(1) ?? '')
            .split(RegExp(r'\s+'))
            .where((String value) => value.isNotEmpty)
            .toList(growable: false),
      );
    } on Object {
      return const _Challenge(resourceMetadata: null, scopes: <String>[]);
    }
  }

  Future<_ClientRegistration> _registerClient(
    Uri endpoint,
    Uri redirectUri,
  ) async {
    final Map<String, Object?> result = await _postJson(
      endpoint,
      <String, Object?>{
        'client_name': 'SpeedDial',
        'redirect_uris': <String>[redirectUri.toString()],
        'grant_types': const <String>['authorization_code', 'refresh_token'],
        'response_types': const <String>['code'],
        'token_endpoint_auth_method': 'none',
      },
    );
    final String? clientId = result['client_id'] as String?;
    if (clientId == null || clientId.isEmpty) {
      throw const FormatException(
        'Dynamic client registration returned no client_id',
      );
    }
    return _ClientRegistration(
      clientId: clientId,
      clientSecret: result['client_secret'] as String?,
      tokenEndpointAuthMethod:
          result['token_endpoint_auth_method'] as String? ?? 'none',
    );
  }

  Future<_TokenResponse> _requestToken(
    Uri endpoint,
    Map<String, String> form, {
    required String clientId,
    required String? clientSecret,
    required String authMethod,
    required List<String> fallbackScopes,
  }) async {
    _validateClientAuthentication(authMethod, clientSecret);
    final HttpClientRequest request = await _http
        .postUrl(endpoint)
        .timeout(_requestTimeout);
    request.headers.contentType = ContentType(
      'application',
      'x-www-form-urlencoded',
      charset: 'utf-8',
    );
    final Map<String, String> body = Map<String, String>.of(form);
    switch (authMethod) {
      case 'none':
        break;
      case 'client_secret_post':
        body['client_secret'] = clientSecret!;
      case 'client_secret_basic':
        final String credentials =
            '${Uri.encodeQueryComponent(clientId)}:'
            '${Uri.encodeQueryComponent(clientSecret!)}';
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Basic ${base64Encode(ascii.encode(credentials))}',
        );
      default:
        throw FormatException(
          'Unsupported token endpoint authentication method: $authMethod',
        );
    }
    request.write(
      body.entries
          .map(
            (MapEntry<String, String> entry) =>
                '${Uri.encodeQueryComponent(entry.key)}='
                '${Uri.encodeQueryComponent(entry.value)}',
          )
          .join('&'),
    );
    final HttpClientResponse response = await request.close().timeout(
      _requestTimeout,
    );
    final String raw = await _readBody(response);
    final Object? decoded = raw.isEmpty ? null : jsonDecode(raw);
    final Map<String, Object?> json = decoded is Map
        ? decoded.cast<String, Object?>()
        : const <String, Object?>{};
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FormatException(
        (json['error_description'] ?? json['error'] ?? 'Token request failed')
            .toString(),
      );
    }
    final String? accessToken = json['access_token'] as String?;
    if (accessToken == null || accessToken.isEmpty) {
      throw const FormatException('Token response has no access_token');
    }
    final String tokenType = (json['token_type'] as String? ?? 'Bearer');
    if (tokenType.toLowerCase() != 'bearer') {
      throw FormatException('Unsupported OAuth token type: $tokenType');
    }
    final int? expiresIn = switch (json['expires_in']) {
      final int value => value,
      final num value => value.toInt(),
      final String value => int.tryParse(value),
      _ => null,
    };
    final List<String> scopes = switch (json['scope']) {
      final String value =>
        value
            .split(RegExp(r'\s+'))
            .where((String scope) => scope.isNotEmpty)
            .toList(growable: false),
      _ => fallbackScopes,
    };
    return _TokenResponse(
      accessToken: accessToken,
      refreshToken: json['refresh_token'] as String?,
      expiresAt: expiresIn == null
          ? null
          : DateTime.now().toUtc().add(Duration(seconds: expiresIn)),
      scopes: scopes,
    );
  }

  Future<Map<String, Object?>> _getJson(Uri uri) async {
    _requireSecureEndpoint(uri, 'Discovery endpoint');
    final HttpClientRequest request = await _http
        .getUrl(uri)
        .timeout(_requestTimeout);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    return _decodeJsonResponse(await request.close().timeout(_requestTimeout));
  }

  Future<Map<String, Object?>> _postJson(
    Uri uri,
    Map<String, Object?> body,
  ) async {
    _requireSecureEndpoint(uri, 'Registration endpoint');
    final HttpClientRequest request = await _http
        .postUrl(uri)
        .timeout(_requestTimeout);
    request.headers
      ..contentType = ContentType.json
      ..set(HttpHeaders.acceptHeader, 'application/json');
    request.write(jsonEncode(body));
    return _decodeJsonResponse(await request.close().timeout(_requestTimeout));
  }

  Future<Map<String, Object?>> _decodeJsonResponse(
    HttpClientResponse response,
  ) async {
    final String body = await _readBody(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FormatException(
        'HTTP ${response.statusCode}: ${body.isEmpty ? response.reasonPhrase : body}',
      );
    }
    final Object? decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const FormatException('Expected a JSON object');
    }
    return decoded.cast<String, Object?>();
  }

  Future<String> _readBody(HttpClientResponse response) async {
    final BytesBuilder bytes = BytesBuilder(copy: false);
    int length = 0;
    await for (final List<int> chunk in response.timeout(_requestTimeout)) {
      length += chunk.length;
      if (length > _maxResponseBytes) {
        throw const FormatException('OAuth response exceeds 1 MiB');
      }
      bytes.add(chunk);
    }
    return utf8.decode(bytes.takeBytes());
  }

  List<Uri> _protectedResourceMetadataUris(Uri server) {
    final String endpointPath = server.path == '/' ? '' : server.path;
    return <Uri>[
      server.replace(
        path: '/.well-known/oauth-protected-resource$endpointPath',
        query: null,
        fragment: null,
      ),
      server.replace(
        path: '/.well-known/oauth-protected-resource',
        query: null,
        fragment: null,
      ),
    ];
  }

  List<Uri> _authorizationMetadataUris(Uri issuer) {
    final String path = issuer.path == '/' ? '' : issuer.path;
    return <Uri>[
      issuer.replace(
        path: '/.well-known/oauth-authorization-server$path',
        query: null,
        fragment: null,
      ),
      issuer.replace(
        path: '/.well-known/openid-configuration$path',
        query: null,
        fragment: null,
      ),
      if (path.isNotEmpty)
        issuer.replace(
          path: '$path/.well-known/openid-configuration',
          query: null,
          fragment: null,
        ),
    ];
  }

  Uri _requiredEndpoint(Map<String, Object?> json, String name) {
    final Object? value = json[name];
    if (value is! String || value.isEmpty) {
      throw FormatException('Authorization metadata has no $name');
    }
    final Uri uri = Uri.parse(value);
    _requireSecureEndpoint(uri, name);
    return uri;
  }

  Uri? _optionalEndpoint(Map<String, Object?> json, String name) {
    final Object? value = json[name];
    if (value == null) return null;
    if (value is! String || value.isEmpty) {
      throw FormatException('Authorization metadata has invalid $name');
    }
    final Uri uri = Uri.parse(value);
    _requireSecureEndpoint(uri, name);
    return uri;
  }

  void _validateClientAuthentication(String method, String? secret) {
    if (method != 'none' &&
        method != 'client_secret_post' &&
        method != 'client_secret_basic') {
      throw FormatException(
        'Unsupported token endpoint authentication method: $method',
      );
    }
    if (method != 'none' && (secret == null || secret.isEmpty)) {
      throw const FormatException(
        'OAuth client secret is required by the authorization server',
      );
    }
  }

  void _requireSecureEndpoint(Uri uri, String label) {
    if (!uri.hasAuthority || uri.hasFragment) {
      throw FormatException(
        '$label must be an absolute URI without a fragment',
      );
    }
    if (uri.scheme == 'https') return;
    if (uri.scheme == 'http' && _isLoopback(uri.host)) return;
    throw FormatException(
      '$label must use HTTPS (HTTP is allowed on loopback)',
    );
  }

  void _requireRedirectUri(Uri uri) {
    if (!uri.hasAuthority ||
        uri.hasFragment ||
        uri.path != '/oauth/callback' ||
        (uri.scheme != 'https' &&
            !(uri.scheme == 'http' && _isLoopback(uri.host)))) {
      throw const FormatException(
        'OAuth redirect URI must be HTTPS or loopback HTTP and end in '
        '/oauth/callback',
      );
    }
  }

  void _requireResourceUri(Uri uri) {
    if (!uri.hasAuthority ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.hasFragment) {
      throw const FormatException(
        'Protected resource identifier must be an absolute HTTP URI without a fragment',
      );
    }
  }

  bool _isLoopback(String host) {
    if (host.toLowerCase() == 'localhost') return true;
    final InternetAddress? address = InternetAddress.tryParse(host);
    return address?.isLoopback ?? false;
  }

  bool _sameIssuer(Uri a, Uri b) =>
      a.scheme.toLowerCase() == b.scheme.toLowerCase() &&
      a.host.toLowerCase() == b.host.toLowerCase() &&
      a.port == b.port &&
      _withoutTrailingSlash(a.path) == _withoutTrailingSlash(b.path);

  bool _matchesRedirect(Uri callback, Uri redirect) {
    if (callback.hasFragment ||
        callback.scheme.toLowerCase() != redirect.scheme.toLowerCase() ||
        callback.host.toLowerCase() != redirect.host.toLowerCase() ||
        callback.port != redirect.port ||
        callback.path != redirect.path ||
        callback.userInfo != redirect.userInfo) {
      return false;
    }
    for (final MapEntry<String, String> entry
        in redirect.queryParameters.entries) {
      if (callback.queryParameters[entry.key] != entry.value) return false;
    }
    return true;
  }

  String _withoutTrailingSlash(String path) =>
      path.endsWith('/') && path.length > 1
      ? path.substring(0, path.length - 1)
      : path;

  Uri _withQuery(Uri uri, Map<String, String> additions) => uri.replace(
    queryParameters: <String, String>{...uri.queryParameters, ...additions},
  );

  List<String> _stringList(Object? value) => value is List
      ? value.whereType<String>().toList(growable: false)
      : const <String>[];

  String _randomToken(int byteCount) => base64Url
      .encode(List<int>.generate(byteCount, (_) => _random.nextInt(256)))
      .replaceAll('=', '');

  void _discardExpiredFlows() {
    final List<String> expired = <String>[
      for (final MapEntry<String, _OAuthFlow> entry in _flows.entries)
        if (_isExpired(entry.value)) entry.key,
    ];
    for (final String id in expired) {
      final _OAuthFlow flow = _flows.remove(id)!;
      _store.setMcpOAuthStatus(
        flow.serverId,
        McpOAuthStatus.error,
        error: 'Authorization timed out',
      );
    }
  }

  bool _isExpired(_OAuthFlow flow) =>
      DateTime.now().toUtc().difference(flow.createdAt) > _flowLifetime;

  String _errorMessage(Object error) => switch (error) {
    final FormatException value => value.message,
    final SocketException value => value.message,
    final TimeoutException _ => 'OAuth server did not respond in time',
    final String value => value,
    _ => error.toString(),
  };

  Future<void> _writeCallbackPage(
    HttpRequest request,
    int status,
    String title,
    String message,
  ) async {
    final HtmlEscape escape = const HtmlEscape();
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.html
      ..write('''<!doctype html>
<html><head><meta charset="utf-8"><title>${escape.convert(title)}</title></head>
<body style="font:16px system-ui;max-width:640px;margin:64px auto;padding:0 24px">
<h1>${escape.convert(title)}</h1><p>${escape.convert(message)}</p>
</body></html>''');
    await request.response.close();
  }
}

class _OAuthFlow {
  const _OAuthFlow({
    required this.serverId,
    required this.verifier,
    required this.createdAt,
    required this.redirectUri,
    required this.tokenEndpoint,
    required this.clientId,
    required this.clientSecret,
    required this.tokenEndpointAuthMethod,
    required this.resource,
    required this.scopes,
  });

  final String serverId;
  final String verifier;
  final DateTime createdAt;
  final Uri redirectUri;
  final Uri tokenEndpoint;
  final String clientId;
  final String? clientSecret;
  final String tokenEndpointAuthMethod;
  final Uri resource;
  final List<String> scopes;
}

class _Challenge {
  const _Challenge({required this.resourceMetadata, required this.scopes});

  final Uri? resourceMetadata;
  final List<String> scopes;
}

class _Discovery {
  const _Discovery({
    required this.resource,
    required this.authorizationServer,
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    required this.registrationEndpoint,
    required this.scopes,
    required this.tokenEndpointAuthMethods,
  });

  final Uri resource;
  final Uri authorizationServer;
  final Uri authorizationEndpoint;
  final Uri tokenEndpoint;
  final Uri? registrationEndpoint;
  final List<String> scopes;
  final List<String> tokenEndpointAuthMethods;
}

class _ClientRegistration {
  const _ClientRegistration({
    required this.clientId,
    required this.clientSecret,
    required this.tokenEndpointAuthMethod,
  });

  final String clientId;
  final String? clientSecret;
  final String tokenEndpointAuthMethod;
}

class _TokenResponse {
  const _TokenResponse({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.scopes,
  });

  final String accessToken;
  final String? refreshToken;
  final DateTime? expiresAt;
  final List<String> scopes;
}
