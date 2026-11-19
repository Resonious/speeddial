import 'package:speeddial_daemon/src/acp/acp_elicitation.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('maps enum and free-text fields both ways', () {
    final form = AcpElicitationForm.parse(<String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'size': <String, Object?>{
          'type': 'string',
          'title': 'Size',
          'description': 'Pick one',
          'enum': <Object?>['s', 'l'],
          'enumNames': <Object?>['Small', 'Large'],
        },
        'name': <String, Object?>{'type': 'string'},
      },
    })!;
    expect(form.questions.map((q) => q.question), <String>[
      'Size\nPick one',
      'name',
    ]);
    expect(form.questions.first.options.map((o) => o.label), <String>[
      'Small',
      'Large',
    ]);
    expect(form.questions.last.options, isEmpty);
    expect(
      form.content(const <UserQuestionAnswer>[
        UserQuestionAnswer(selected: <String>['Large'], note: 'ignored'),
        UserQuestionAnswer(selected: <String>[], note: 'Ada'),
      ]),
      <String, Object?>{'size': 'l', 'name': 'Ada'},
    );
    expect(
      form.content(const <UserQuestionAnswer>[
        UserQuestionAnswer(selected: <String>[]),
        UserQuestionAnswer(selected: <String>[]),
      ]),
      isEmpty,
    );
  });

  test('a free-form answer alone fills only the companion field', () {
    final form = AcpElicitationForm.parse(<String, Object?>{
      'properties': <String, Object?>{
        'q1': <String, Object?>{
          'type': 'string',
          'title': 'Color?',
          'oneOf': <Object?>[
            <String, Object?>{'const': '1', 'title': 'Red'},
          ],
        },
        'q1_other': <String, Object?>{'type': 'string', 'title': 'Other'},
      },
    })!;
    expect(form.questions, hasLength(1));
    expect(form.questions.single.header, 'Question');
    expect(
      form.content(const <UserQuestionAnswer>[
        UserQuestionAnswer(selected: <String>[], note: 'green'),
      ]),
      <String, Object?>{'q1_other': 'green'},
    );
  });

  test('rejects schemas it cannot present', () {
    expect(AcpElicitationForm.parse(null), isNull);
    expect(
      AcpElicitationForm.parse(<String, Object?>{
        'properties': <String, Object?>{},
      }),
      isNull,
    );
    expect(
      AcpElicitationForm.parse(<String, Object?>{
        'properties': <String, Object?>{
          'age': <String, Object?>{'type': 'integer'},
        },
      }),
      isNull,
    );
  });
}
