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
}
