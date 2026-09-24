import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/ui/chat/question_banner.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

const request = PermissionRequest(
  requestId: 'ask',
  toolCallId: 'tool',
  title: 'Answer the agent',
  options: [],
  questions: [
    UserQuestion(
      header: 'Setup',
      question: 'Where should it run?',
      options: [
        UserQuestionOption(label: 'Local', description: 'This machine'),
        UserQuestionOption(label: 'Remote', description: 'A server'),
      ],
    ),
    UserQuestion(
      header: 'Features',
      question: 'Which features?',
      multiSelect: true,
      options: [
        UserQuestionOption(label: 'Logs', description: ''),
        UserQuestionOption(label: 'Metrics', description: ''),
      ],
    ),
  ],
);

void main() {
  testWidgets(
    'selects single and multiple answers, includes notes, submits exact labels',
    (tester) async {
      List<UserQuestionAnswer>? answers;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuestionBanner(
              request: request,
              onSubmit: (value) async {
                answers = value;
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('Local'));
      await tester.pump();
      await tester.tap(find.text('Remote'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).first, 'Use staging');
      for (final label in ['Logs', 'Metrics']) {
        await tester.ensureVisible(find.text(label));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label));
        await tester.pump();
      }
      await tester.ensureVisible(find.text('Submit answers'));
      await tester.tap(find.text('Submit answers'));
      await tester.pumpAndSettle();
      expect(answers!.map((e) => e.toJson()).toList(), [
        {
          'selected': ['Remote'],
          'note': 'Use staging',
        },
        {
          'selected': ['Logs', 'Metrics'],
          'note': null,
        },
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('free text, retryable errors and skip work on a narrow screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var attempts = 0;
    List<UserQuestionAnswer>? submitted;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QuestionBanner(
            request: PermissionRequest(
              requestId: 'text',
              toolCallId: 'tool',
              title: '',
              options: [],
              questions: [request.questions.first],
            ),
            onSubmit: (value) async {
              attempts++;
              submitted = value;
              if (attempts == 1) throw const DaemonError(-1, 'Try again');
            },
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'Something else');
    await tester.ensureVisible(find.text('Submit answers'));
    await tester.tap(find.text('Submit answers'));
    await tester.pumpAndSettle();
    expect(submitted!.single.selected, isEmpty);
    expect(submitted!.single.note, 'Something else');
    expect(find.text('Try again'), findsOneWidget);
    await tester.ensureVisible(find.text('Skip'));
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(submitted, isNull);
    expect(tester.takeException(), isNull);
  });
}
