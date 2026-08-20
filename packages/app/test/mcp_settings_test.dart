import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/scope.dart';
import 'package:speeddial_app/src/ui/settings/mcp_settings_page.dart';

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
    expect(find.text('/usr/local/bin/filesystem-mcp --stdio'), findsOneWidget);
    final profiles = await client.listMcpServers();
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
    expect(
      launched.toString(),
      contains('https://auth.example/authorize'),
    );
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
}
