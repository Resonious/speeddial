/// Translation between ACP form-mode elicitations (`elicitation/create`) and
/// SpeedDial's provider questions.
///
/// Agents such as Google Antigravity ask the user questions this way: each
/// question is one schema property (a `oneOf` string for single select, an
/// array of `anyOf` items for multi select, or a plain string for free text),
/// optionally paired with a `<key>_other` string for a free-form answer.
library;

import 'package:speeddial_protocol/speeddial_protocol.dart';

/// One schema property presented as a question.
class _Field {
  const _Field({
    required this.key,
    required this.otherKey,
    required this.multiSelect,
    required this.values,
  });

  final String key;

  /// The companion free-form property receiving the answer's note, if any.
  final String? otherKey;
  final bool multiSelect;

  /// Option values in the same order as the question's options. Empty for
  /// a free-text question, whose note is the value.
  final List<String> values;
}

/// A parsed form elicitation and its questions.
class AcpElicitationForm {
  AcpElicitationForm._(this.questions, this._fields);

  final List<UserQuestion> questions;
  final List<_Field> _fields;

  /// Parses a form `requestedSchema`. Returns null for schemas SpeedDial
  /// cannot present as questions (no properties, or non-string fields).
  static AcpElicitationForm? parse(Object? requestedSchema) {
    if (requestedSchema is! Map) return null;
    final rawProperties = requestedSchema['properties'];
    if (rawProperties is! Map || rawProperties.isEmpty) return null;
    final properties = <String, Map<Object?, Object?>>{};
    for (final entry in rawProperties.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String || value is! Map) return null;
      properties[key] = value;
    }
    bool isCompanion(String key) =>
        key.endsWith('_other') &&
        properties.containsKey(key.substring(0, key.length - 6)) &&
        properties[key]!['type'] == 'string';

    final fields = <_Field>[];
    final drafts = <({String text, bool multi, List<UserQuestionOption> o})>[];
    for (final MapEntry(:key, :value) in properties.entries) {
      if (isCompanion(key)) continue;
      final List<({String value, String label})>? choices;
      final bool multi;
      switch (value['type']) {
        case 'string':
          multi = false;
          choices = _choices(value) ?? const [];
        case 'array':
          multi = true;
          final items = value['items'];
          choices = items is Map ? _choices(items) : null;
          if (choices == null || choices.isEmpty) return null;
        default:
          return null;
      }
      final otherKey = '${key}_other';
      fields.add(
        _Field(
          key: key,
          otherKey: properties.containsKey(otherKey) && isCompanion(otherKey)
              ? otherKey
              : null,
          multiSelect: multi,
          values: <String>[for (final choice in choices) choice.value],
        ),
      );
      final title = value['title'];
      final description = value['description'];
      final text = <String>[
        if (title is String && title.trim().isNotEmpty) title.trim(),
        if (description is String && description.trim().isNotEmpty)
          description.trim(),
      ].join('\n');
      drafts.add((
        text: text.isEmpty ? key : text,
        multi: multi,
        o: <UserQuestionOption>[
          for (final choice in choices)
            UserQuestionOption(label: choice.label, description: ''),
        ],
      ));
    }
    if (fields.isEmpty) return null;
    final questions = <UserQuestion>[
      for (var i = 0; i < drafts.length; i++)
        UserQuestion(
          header: drafts.length == 1 ? 'Question' : 'Question ${i + 1}',
          question: drafts[i].text,
          multiSelect: drafts[i].multi,
          options: drafts[i].o,
        ),
    ];
    return AcpElicitationForm._(questions, fields);
  }

  /// The choices of a `oneOf`/`anyOf` list of `{const, title}` or an `enum`
  /// (with optional `enumNames`); null when the schema has none. Duplicate
  /// labels are dropped since answers select options by label.
  static List<({String value, String label})>? _choices(
    Map<Object?, Object?> s,
  ) {
    final result = <({String value, String label})>[];
    final labels = <String>{};
    void add(Object? value, Object? label) {
      if (value is! String) return;
      final text = label is String && label.isNotEmpty ? label : value;
      if (labels.add(text)) result.add((value: value, label: text));
    }

    final variants = s['oneOf'] ?? s['anyOf'];
    if (variants is List) {
      for (final variant in variants) {
        if (variant is Map) add(variant['const'], variant['title']);
      }
      return result;
    }
    final values = s['enum'];
    if (values is List) {
      final names = s['enumNames'];
      for (var i = 0; i < values.length; i++) {
        add(values[i], names is List && i < names.length ? names[i] : null);
      }
      return result;
    }
    return null;
  }

  /// The `content` of an `accept` response for [answers], one per question.
  /// Unanswered questions are omitted.
  Map<String, Object?> content(List<UserQuestionAnswer> answers) {
    final content = <String, Object?>{};
    for (var i = 0; i < _fields.length && i < answers.length; i++) {
      final field = _fields[i];
      final answer = answers[i];
      final options = questions[i].options;
      final selected = <String>[
        for (var j = 0; j < options.length; j++)
          if (answer.selected.contains(options[j].label)) field.values[j],
      ];
      final note = answer.note;
      if (field.values.isEmpty) {
        if (note != null) content[field.key] = note;
        continue;
      }
      if (selected.isNotEmpty) {
        content[field.key] = field.multiSelect ? selected : selected.first;
      }
      if (note != null && field.otherKey != null) {
        content[field.otherKey!] = note;
      }
    }
    return content;
  }
}
