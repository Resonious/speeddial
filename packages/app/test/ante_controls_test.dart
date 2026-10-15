import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/scope.dart';
import 'package:speeddial_app/src/ui/chat/chat_pane.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/chat/composer.dart';
import 'package:speeddial_app/src/ui/chat/ante_controls.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

const commands = <NativeCommand>[
  NativeCommand(
    name: 'provider',
    description: 'Show or switch the Ante upstream provider',
    argumentHint: '[provider] [model]',
  ),
  NativeCommand(
    name: 'rewind',
    description:
        'Rewind before a user turn (latest by default); files stay unchanged',
    argumentHint: '[message sequence]',
  ),
  NativeCommand(
    name: 'fork',
    description: 'Fork the conversation through a message',
    argumentHint: '[message sequence]',
  ),
];

void main() {
  for (final double width in <double>[390, 441, 1440]) {
    for (final bool light in <bool>[false, true]) {
      testWidgets('Ante UI and slash aliases share actions ($width, $light)', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final fake = FakeDaemonClient();
        final app = AppData()..registerClient('fake', fake);
        final project = (await fake.listProjects()).first;
        final source = await fake.createSession(
          projectId: project.id,
          providerId: 'ante',
          model: 'cerebras/gemma-4-31b',
        );
        fake.seedHistory(source.id, const [
          UserMessageEvent(text: 'First turn'),
          AgentMessageChunkEvent(text: 'First answer'),
          TurnCompleteEvent(stopReason: 'end_turn'),
        ]);
        await app.sessions.refresh('fake');
        await app.daemonConfig.refreshInfo('fake');
        app.connections.setStatus('fake', ConnectionStatus.connected);
        app.selection
          ..selectedDaemonId = 'fake'
          ..selectedProjectId = project.id
          ..selectedSessionId = source.id;
        await tester.pumpWidget(
          AppScope(
            data: app,
            child: MaterialApp(
              theme:
                  (light ? buildSpeedDialLightTheme() : buildSpeedDialTheme())
                      .copyWith(platform: TargetPlatform.linux),
              home: const Scaffold(body: ChatPane()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('composer-model')));
        await tester.pumpAndSettle();
        expect(find.text('gpt-5.6-luna'), findsOneWidget);
        expect(find.text('glm-5.2'), findsOneWidget);
        expect(
          app.sessions.byId(source.id)!.model,
          'cerebras/gemma-4-31b',
          reason: 'Browsing must not switch providers',
        );
        await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'cerebras'));
        await tester.tap(find.widgetWithText(ChoiceChip, 'cerebras'));
        await tester.pumpAndSettle();
        expect(find.text('gpt-5.6-luna'), findsNothing);
        expect(find.text('gemma-4-31b'), findsOneWidget);
        await tester.ensureVisible(
          find.widgetWithText(ChoiceChip, 'All providers'),
        );
        await tester.tap(find.widgetWithText(ChoiceChip, 'All providers'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('model-picker-query')),
          'gpt-5.6',
        );
        await tester.pumpAndSettle();
        expect(find.text('glm-5.2'), findsNothing);
        await tester.tap(find.text('gpt-5.6-luna'));
        await tester.pumpAndSettle();
        expect(
          app.sessions.byId(source.id)!.model,
          'openai-subscription/gpt-5.6-luna',
        );
        await tester.enterText(find.byType(TextField), '/provider zai');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(app.sessions.byId(source.id)!.model, 'zai/glm-5.2');
        await tester.tap(find.byTooltip('Conversation actions'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Fork conversation'));
        await tester.pumpAndSettle();
        final buttonFork = app.selection.selectedSessionId!;
        expect(buttonFork, isNot(source.id));
        app.selection.selectedSessionId = source.id;
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '/fork ');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        final slashFork = app.selection.selectedSessionId!;
        expect(slashFork, isNot(source.id));
        expect(
          (await fake.history(slashFork)).events
              .map((e) => e.toJson()..remove('timestamp')),
          (await fake.history(buttonFork)).events
              .map((e) => e.toJson()..remove('timestamp')),
        );
        await tester.tap(find.byTooltip('Conversation actions'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Rewind last turn'));
        await tester.pumpAndSettle();
        expect(find.text('First answer'), findsNothing);
        app.selection.selectedSessionId = buttonFork;
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '/rewind ');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.text('First answer'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        await fake.dispose();
      });
      testWidgets(
        'Ante controls can be selected and submitted (light: $light, width: $width)',
        (tester) async {
          tester.view.physicalSize = Size(width, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final sent = <String>[];
          await tester.pumpWidget(
            MaterialApp(
              theme:
                  (light ? buildSpeedDialLightTheme() : buildSpeedDialTheme())
                      .copyWith(platform: TargetPlatform.linux),
              home: Scaffold(
                body: Composer(
                  status: SessionStatus.idle,
                  commands: commands,
                  model: 'a-provider-model-with-a-long-name',
                  models: const ['a-provider-model-with-a-long-name'],
                  onModelChanged: (_) {},
                  thinkingLevel: 'medium',
                  thinkingLevels: const ['low', 'medium', 'high'],
                  onThinkingChanged: (_) {},
                  sessionControls: AnteControls(
                    enabled: true,
                    onRewind: () {},
                    onFork: () {},
                  ),
                  onSend: (text, _) async => sent.add(text),
                  onStop: () {},
                ),
              ),
            ),
          );
          await tester.enterText(find.byType(TextField), '/');
          await tester.pumpAndSettle();
          for (final command in commands) {
            expect(
              find.byKey(Key('slash-command-/${command.name}')),
              findsOneWidget,
            );
          }
          await tester.tap(find.byKey(const Key('slash-command-/provider')));
          await tester.pumpAndSettle();
          expect(
            tester.widget<TextField>(find.byType(TextField)).controller!.text,
            '/provider ',
          );
          await tester.enterText(
            find.byType(TextField),
            '/provider openai gpt-6-astra',
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(sent, <String>['/provider openai gpt-6-astra']);
        },
      );
    }
  }
}
