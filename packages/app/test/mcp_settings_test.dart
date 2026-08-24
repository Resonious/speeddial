import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/oauth/localhost_oauth_callback.dart';
import 'package:speeddial_app/src/scope.dart';
import 'package:speeddial_app/src/ui/settings/mcp_settings_page.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

void main() {
  testWidgets('adds a stdio MCP server and stores credential names', (
    WidgetTester tester,
  ) async {
    final FakeDaemonClient client = FakeDaemonClient();
    final AppData data = AppData()..registerClient('daemon', client);
    addTearDown(data.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          data: data,
          child: const McpSettingsPage(
            daemonId: 'daemon',
            daemonName: 'Test daemon',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No MCP servers configured'), findsOneWidget);
    await tester.tap(find.byKey(const Key('mcp-add-server')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('mcp-name')), 'Filesystem');
    await tester.tap(find.byKey(const Key('mcp-scope')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Demo Project').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('mcp-endpoint')),
      '/usr/local/bin/filesystem-mcp',
    );
    await tester.enterText(find.byKey(const Key('mcp-args')), '--stdio');
    final Finder addSecret = find.byKey(const Key('mcp-add-secret'));
    await tester.ensureVisible(addSecret);
    await tester.tap(addSecret);
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('mcp-secret-name-0')),
      'API_TOKEN',
    );
    await tester.enterText(
      find.byKey(const Key('mcp-secret-value-0')),
      'top-secret',
    );
    await tester.tap(find.byKey(const Key('mcp-save')));
    await tester.pumpAndSettle();

    expect(find.text('Filesystem'), findsOneWidget);
    expect(find.text('Demo Project'), findsOneWidget);
    expect(find.text('/usr/local/bin/filesystem-mcp --stdio'), findsOneWidget);
    final profiles = await client.listMcpServers();
    expect(profiles.single.projectId, 'proj-demo');
    expect(profiles.single.secretNames, const <String>['API_TOKEN']);
    expect(profiles.single.toJson().toString(), isNot(contains('top-secret')));
  });

  testWidgets('authorizes and disconnects an HTTP OAuth server', (
    WidgetTester tester,
  ) async {
    final FakeDaemonClient client = FakeDaemonClient();
    final AppData data = AppData()..registerClient('daemon', client);
    addTearDown(data.dispose);
    Uri? launched;
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          data: data,
          child: McpSettingsPage(
            daemonId: 'daemon',
            daemonName: 'Test daemon',
            launchExternal: (Uri uri) async {
              launched = uri;
              return true;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mcp-add-server')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('mcp-name')), 'Remote tools');
    await tester.tap(find.byKey(const Key('mcp-transport')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remote server (HTTP)').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('mcp-endpoint')),
      'https://mcp.example/tools',
    );
    await tester.tap(find.byKey(const Key('mcp-auth-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OAuth 2.1').last);
    await tester.pumpAndSettle();
    final Finder save = find.byKey(const Key('mcp-save'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(find.text('OAuth: Not connected'), findsOneWidget);
    await tester.tap(find.byTooltip('MCP server actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect account'));
    await tester.pump();
    expect(launched.toString(), contains('https://auth.example/authorize'));
    expect(
      find.textContaining('Finish authorization in your browser'),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('OAuth: Authorized'), findsOneWidget);

    await tester.tap(find.byTooltip('MCP server actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();
    expect(find.text('OAuth: Not connected'), findsOneWidget);
  });

  testWidgets('retries OAuth status after a temporary disconnection', (
    WidgetTester tester,
  ) async {
    final _DisconnectingOAuthClient client = _DisconnectingOAuthClient();
    final AppData data = AppData()..registerClient('daemon', client);
    addTearDown(data.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          data: data,
          child: McpSettingsPage(
            daemonId: 'daemon',
            daemonName: 'Test daemon',
            launchExternal: (Uri uri) async => true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mcp-add-server')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('mcp-name')), 'Remote tools');
    await tester.tap(find.byKey(const Key('mcp-transport')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remote server (HTTP)').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('mcp-endpoint')),
      'https://mcp.example/tools',
    );
    await tester.tap(find.byKey(const Key('mcp-auth-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OAuth 2.1').last);
    await tester.pumpAndSettle();
    final Finder save = find.byKey(const Key('mcp-save'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('MCP server actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect account'));
    await tester.pump();

    expect(find.textContaining('daemon client is not connected'), findsNothing);
    expect(
      find.textContaining('Finish authorization in your browser'),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(client.statusCalls, 2);
    expect(find.text('OAuth: Authorized'), findsOneWidget);
  });

  testWidgets('localhost OAuth forwards the frontend callback to the daemon', (
    WidgetTester tester,
  ) async {
    final FakeDaemonClient client = FakeDaemonClient();
    final AppData data = AppData()..registerClient('daemon', client);
    final _FakeLocalhostOAuthCallback callback = _FakeLocalhostOAuthCallback();
    addTearDown(data.dispose);
    Uri? launched;
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          data: data,
          child: McpSettingsPage(
            daemonId: 'daemon',
            daemonName: 'Test daemon',
            launchExternal: (Uri uri) async {
              launched = uri;
              return true;
            },
            startLocalhostCallback: () async => callback,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mcp-add-server')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('mcp-name')), 'Local OAuth');
    await tester.tap(find.byKey(const Key('mcp-transport')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remote server (HTTP)').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('mcp-endpoint')),
      'https://mcp.example/tools',
    );
    await tester.tap(find.byKey(const Key('mcp-auth-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OAuth 2.1 (localhost)').last);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('temporarily listens on localhost'),
      findsOneWidget,
    );
    final Finder save = find.byKey(const Key('mcp-save'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    final McpServerProfile created = (await client.listMcpServers()).single;
    expect(created.authType, McpAuthType.oauthLocalhost);
    await tester.tap(find.byTooltip('MCP server actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect account'));
    await tester.pumpAndSettle();

    expect(launched.toString(), contains('https://auth.example/authorize'));
    expect(callback.receivedFlowId, 'fake-oauth-${created.id}');
    expect(callback.successResponded, isTrue);
    expect(callback.closed, isTrue);
    expect(find.text('OAuth: Authorized'), findsOneWidget);
  });
}

class _DisconnectingOAuthClient extends FakeDaemonClient {
  int statusCalls = 0;

  @override
  Future<McpServerProfile> mcpOAuthStatus(String id, String flowId) {
    statusCalls++;
    if (statusCalls == 1) {
      throw const DaemonConnectionError('daemon client is not connected');
    }
    return super.mcpOAuthStatus(id, flowId);
  }
}

class _FakeLocalhostOAuthCallback implements LocalhostOAuthCallback {
  @override
  final Uri redirectUri = Uri.parse('http://localhost:49152/oauth/callback');

  String? receivedFlowId;
  bool successResponded = false;
  bool closed = false;

  @override
  Future<Uri> waitForCallback(String flowId) async {
    receivedFlowId = flowId;
    return redirectUri.replace(
      queryParameters: <String, String>{
        'code': 'authorization-code',
        'state': flowId,
      },
    );
  }

  @override
  Future<void> respondSuccess() async {
    successResponded = true;
  }

  @override
  Future<void> respondError(String message) async {}

  @override
  Future<void> close() async {
    closed = true;
  }
}
