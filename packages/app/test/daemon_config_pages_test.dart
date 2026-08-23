import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/scope.dart';
import 'package:speeddial_app/src/ui/settings/environment_page.dart';
import 'package:speeddial_app/src/ui/settings/harnesses_page.dart';

void main() {
  testWidgets('shows installed harness versions and updates one', (
    WidgetTester tester,
  ) async {
    final FakeDaemonClient client = FakeDaemonClient();
    final AppData data = AppData()..registerClient('daemon', client);
    addTearDown(data.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          data: data,
          child: const HarnessesPage(
            daemonId: 'daemon',
            daemonName: 'Test daemon',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('OMP'), findsOneWidget);
    expect(find.text('Claude Code'), findsOneWidget);
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('Ante'), findsOneWidget);
    expect(find.text('codex-cli 0.148.0'), findsOneWidget);

    await tester.tap(find.byKey(const Key('harness-update-codex')));
    await tester.pumpAndSettle();

    expect(client.harnessUpdateCalls, <String>['codex']);
    expect(find.textContaining('Codex is now codex-cli'), findsOneWidget);
  });

  testWidgets('adds, replaces, and removes a write-only environment variable', (
    WidgetTester tester,
  ) async {
    final FakeDaemonClient client = FakeDaemonClient();
    final AppData data = AppData()..registerClient('daemon', client);
    addTearDown(data.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          data: data,
          child: const EnvironmentPage(
            daemonId: 'daemon',
            daemonName: 'Test daemon',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No daemon environment variables'), findsOneWidget);
    await tester.tap(find.byKey(const Key('environment-add-variable')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('environment-name')),
      'API_TOKEN',
    );
    await tester.enterText(
      find.byKey(const Key('environment-value')),
      'top-secret',
    );
    await tester.tap(find.byKey(const Key('environment-save')));
    await tester.pumpAndSettle();

    expect(find.text('API_TOKEN'), findsOneWidget);
    expect(await client.listEnvironmentNames(), <String>['API_TOKEN']);
    expect(find.text('top-secret'), findsNothing);

    await tester.tap(find.byKey(const Key('environment-edit-API_TOKEN')));
    await tester.pumpAndSettle();
    expect(find.text('Replace value'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('environment-value')),
      'replacement',
    );
    await tester.tap(find.byKey(const Key('environment-save')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('environment-remove-API_TOKEN')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('environment-remove-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('No daemon environment variables'), findsOneWidget);
    expect(await client.listEnvironmentNames(), isEmpty);
  });
}
