import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/state/mcp_store.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

void main() {
  test('keeps MCP servers newest first across edits and refreshes', () async {
    final FakeDaemonClient client = FakeDaemonClient();
    final McpStore store = McpStore(clientFor: (String _) => client);
    addTearDown(store.dispose);

    final McpServerProfile alpha = await store.create(
      'daemon',
      name: 'Alpha',
      transport: McpTransport.stdio,
      enabled: true,
      command: '/bin/alpha',
    );
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await store.create(
      'daemon',
      name: 'Zeta',
      transport: McpTransport.stdio,
      enabled: true,
      command: '/bin/zeta',
    );
    List<String> names() => store
        .serversFor('daemon')
        .map((McpServerProfile server) => server.name)
        .toList();
    expect(names(), <String>['Zeta', 'Alpha']);

    await store.update(
      'daemon',
      id: alpha.id,
      name: 'Omega',
      transport: McpTransport.stdio,
      enabled: false,
      projectId: null,
      command: '/bin/alpha',
    );
    expect(names(), <String>['Zeta', 'Omega']);

    await store.refresh('daemon');
    expect(names(), <String>['Zeta', 'Omega']);
  });
}
