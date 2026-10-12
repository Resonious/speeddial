/// Interactive explainers: an SVG scene plus steps and toggles that restyle
/// it. See PROTOCOL.md "Explainers" for the format agents author.
library;

import 'svg_document.dart';

const int kMaxExplainerSvgLength = 200 * 1024;
const int kMaxExplainerSteps = 100;
const int kMaxExplainerToggles = 8;
const int kMaxExplainerTextLength = 2000;

/// Selector → attribute → value (string or number), as authored.
typedef ExplainerChanges = Map<String, Map<String, Object>>;

/// One step of an explainer as sent on the wire.
class ExplainerStepSpec {
  const ExplainerStepSpec({
    required this.caption,
    this.set = const <String, Map<String, Object>>{},
  });

  final String caption;
  final ExplainerChanges set;

  Map<String, Object?> toJson() => <String, Object?>{
    'caption': caption,
    if (set.isNotEmpty) 'set': set,
  };
}

/// A switch the viewer can flip; its changes apply on top of the current
/// step while on.
class ExplainerToggleSpec {
  const ExplainerToggleSpec({
    required this.label,
    required this.set,
    this.on = false,
  });

  final String label;
  final bool on;
  final ExplainerChanges set;

  Map<String, Object?> toJson() => <String, Object?>{
    'label': label,
    if (on) 'on': true,
    'set': set,
  };
}

/// The `Explainer` wire object (PROTOCOL.md).
class ExplainerSpec {
  const ExplainerSpec({
    this.title,
    required this.svg,
    this.steps = const <ExplainerStepSpec>[],
    this.toggles = const <ExplainerToggleSpec>[],
  });

  final String? title;
  final String svg;
  final List<ExplainerStepSpec> steps;
  final List<ExplainerToggleSpec> toggles;

  /// Decodes and shape-checks [json]. Messages are written for agents, since
  /// the same decoder validates `show_explainer` arguments.
  factory ExplainerSpec.fromJson(Map<String, Object?> json) {
    final Object? title = json['title'];
    if (title != null && (title is! String || title.length > 200)) {
      throw const FormatException(
        'title must be a string of at most 200 chars',
      );
    }
    final Object? svg = json['svg'];
    if (svg is! String) {
      throw const FormatException('svg is required and must be a string');
    }
    if (svg.length > kMaxExplainerSvgLength) {
      throw const FormatException(
        'svg exceeds $kMaxExplainerSvgLength characters',
      );
    }
    final List<Object?> rawSteps = switch (json['steps']) {
      null => const <Object?>[],
      final List<Object?> list => list,
      _ => throw const FormatException('steps must be an array'),
    };
    if (rawSteps.length > kMaxExplainerSteps) {
      throw const FormatException('at most $kMaxExplainerSteps steps');
    }
    final List<Object?> rawToggles = switch (json['toggles']) {
      null => const <Object?>[],
      final List<Object?> list => list,
      _ => throw const FormatException('toggles must be an array'),
    };
    if (rawToggles.length > kMaxExplainerToggles) {
      throw const FormatException('at most $kMaxExplainerToggles toggles');
    }
    return ExplainerSpec(
      title: title as String?,
      svg: svg,
      steps: <ExplainerStepSpec>[
        for (int i = 0; i < rawSteps.length; i++)
          _step(rawSteps[i], 'steps[$i]'),
      ],
      toggles: <ExplainerToggleSpec>[
        for (int i = 0; i < rawToggles.length; i++)
          _toggle(rawToggles[i], 'toggles[$i]'),
      ],
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'title': ?title,
    'svg': svg,
    if (steps.isNotEmpty)
      'steps': steps
          .map((ExplainerStepSpec s) => s.toJson())
          .toList(growable: false),
    if (toggles.isNotEmpty)
      'toggles': toggles
          .map((ExplainerToggleSpec t) => t.toJson())
          .toList(growable: false),
  };

  static ExplainerStepSpec _step(Object? raw, String where) {
    if (raw is! Map) throw FormatException('$where must be an object');
    final Object? caption = raw['caption'];
    if (caption is! String) {
      throw FormatException('$where.caption must be a string');
    }
    if (caption.length > kMaxExplainerTextLength) {
      throw FormatException(
        '$where.caption exceeds $kMaxExplainerTextLength chars',
      );
    }
    _onlyKeys(raw, const <String>{'caption', 'set'}, where);
    return ExplainerStepSpec(
      caption: caption,
      set: _changes(raw['set'], '$where.set', optional: true),
    );
  }

  static ExplainerToggleSpec _toggle(Object? raw, String where) {
    if (raw is! Map) throw FormatException('$where must be an object');
    final Object? label = raw['label'];
    if (label is! String || label.isEmpty || label.length > 60) {
      throw FormatException('$where.label must be a 1-60 char string');
    }
    final Object? on = raw['on'];
    if (on != null && on is! bool) {
      throw FormatException('$where.on must be a boolean');
    }
    _onlyKeys(raw, const <String>{'label', 'on', 'set'}, where);
    return ExplainerToggleSpec(
      label: label,
      on: on as bool? ?? false,
      set: _changes(raw['set'], '$where.set', optional: false),
    );
  }

  static void _onlyKeys(
    Map<Object?, Object?> raw,
    Set<String> keys,
    String where,
  ) {
    for (final Object? key in raw.keys) {
      if (!keys.contains(key)) {
        throw FormatException(
          '$where has unknown key "$key" (allowed: ${keys.join(', ')})',
        );
      }
    }
  }

  static ExplainerChanges _changes(
    Object? raw,
    String where, {
    required bool optional,
  }) {
    if (raw == null) {
      if (optional) return const <String, Map<String, Object>>{};
      throw FormatException('$where is required');
    }
    if (raw is! Map) {
      throw FormatException(
        '$where must map selectors to attribute objects, e.g. '
        '{"#cache": {"fill": "var(--accent)"}}',
      );
    }
    final ExplainerChanges out = <String, Map<String, Object>>{};
    for (final MapEntry<Object?, Object?> entry in raw.entries) {
      final Object? selector = entry.key;
      final Object? attributes = entry.value;
      if (selector is! String || attributes is! Map) {
        throw FormatException(
          '$where["$selector"] must be an object of attribute values',
        );
      }
      final Map<String, Object> values = <String, Object>{};
      for (final MapEntry<Object?, Object?> attribute in attributes.entries) {
        final Object? value = attribute.value;
        if (attribute.key is! String || (value is! String && value is! num)) {
          throw FormatException(
            '$where["$selector"]["${attribute.key}"] must be a string or '
            'number',
          );
        }
        values[attribute.key! as String] = value!;
      }
      out[selector] = values;
    }
    return out;
  }
}

/// Element index → changed attributes.
typedef ExplainerOverrides = Map<int, Map<SvgAttr, Object>>;

class ExplainerStep {
  const ExplainerStep(this.caption, this.overrides);
  final String caption;

  /// The cumulative state at this step: every earlier step's changes, then
  /// this step's.
  final ExplainerOverrides overrides;
}

class ExplainerToggle {
  const ExplainerToggle(this.label, this.on, this.overrides);
  final String label;
  final bool on;
  final ExplainerOverrides overrides;
}

/// A validated explainer, ready to render.
class ExplainerDocument {
  ExplainerDocument._(
    this.spec,
    this.svg,
    this.steps,
    this.toggles,
    this.warnings,
  );

  final ExplainerSpec spec;
  final SvgDocument svg;

  /// Never empty: a stepless explainer has one implicit, captionless step.
  final List<ExplainerStep> steps;
  final List<ExplainerToggle> toggles;

  /// Problems that did not prevent rendering (ignored attributes, etc.).
  final List<String> warnings;

  /// Validates [spec] completely. Throws [ExplainerException] listing every
  /// error found.
  static ExplainerDocument parse(ExplainerSpec spec) {
    final ExplainerDiagnostics diag = ExplainerDiagnostics();
    final SvgDocument? svg = parseSvgDocument(spec.svg, diag);
    if (svg == null) {
      throw ExplainerException(diag.errors, warnings: diag.warnings);
    }
    final List<ExplainerStep> steps = <ExplainerStep>[];
    ExplainerOverrides cumulative = <int, Map<SvgAttr, Object>>{};
    for (int i = 0; i < spec.steps.length; i++) {
      final ExplainerStepSpec step = spec.steps[i];
      final ExplainerOverrides changes = _resolve(
        svg,
        step.set,
        'steps[$i].set',
        diag,
      );
      cumulative = <int, Map<SvgAttr, Object>>{
        for (final MapEntry<int, Map<SvgAttr, Object>> entry
            in cumulative.entries)
          entry.key: entry.value,
      };
      for (final MapEntry<int, Map<SvgAttr, Object>> entry in changes.entries) {
        cumulative[entry.key] = <SvgAttr, Object>{
          ...?cumulative[entry.key],
          ...entry.value,
        };
      }
      steps.add(ExplainerStep(step.caption, cumulative));
    }
    if (steps.isEmpty) {
      steps.add(const ExplainerStep('', <int, Map<SvgAttr, Object>>{}));
    }
    final List<ExplainerToggle> toggles = <ExplainerToggle>[
      for (int i = 0; i < spec.toggles.length; i++)
        ExplainerToggle(
          spec.toggles[i].label,
          spec.toggles[i].on,
          _resolve(svg, spec.toggles[i].set, 'toggles[$i].set', diag),
        ),
    ];
    if (diag.errors.isNotEmpty) {
      throw ExplainerException(diag.errors, warnings: diag.warnings);
    }
    return ExplainerDocument._(spec, svg, steps, toggles, diag.warnings);
  }

  static ExplainerOverrides _resolve(
    SvgDocument svg,
    ExplainerChanges changes,
    String where,
    ExplainerDiagnostics diag,
  ) {
    final ExplainerOverrides out = <int, Map<SvgAttr, Object>>{};
    for (final MapEntry<String, Map<String, Object>> entry in changes.entries) {
      final String selector = entry.key;
      final List<int> matches;
      try {
        matches = svg.select(selector);
      } on FormatException catch (e) {
        diag.error('$where: ${e.message}');
        continue;
      }
      if (matches.isEmpty) {
        diag.error('$where: selector "$selector" matches no element');
        continue;
      }
      for (final MapEntry<String, Object> change in entry.value.entries) {
        final SvgAttr? attr = SvgAttr.byWire[change.key];
        if (attr == null) {
          diag.error('$where["$selector"]: unknown attribute "${change.key}"');
          continue;
        }
        final String raw = change.value is String
            ? change.value as String
            : (change.value as num).toString();
        for (final int index in matches) {
          final SvgNode node = svg.nodes[index];
          if (!attr.presentation &&
              attr != SvgAttr.transform &&
              !(kSvgGeometry[node.tag]?.contains(attr) ?? false)) {
            diag.error(
              '$where["$selector"]: ${attr.wire} does not apply to '
              '<${node.tag}>${node.id == null ? '' : ' #${node.id}'}',
            );
            break;
          }
          final Object value;
          try {
            value = parseSvgAttrValue(
              attr,
              raw,
              fontSize: _fontSize(svg, index),
            );
          } on FormatException catch (e) {
            diag.error('$where["$selector"]: ${attr.wire}: ${e.message}');
            break;
          }
          if (attr.kind == SvgValueKind.marker && value is String) {
            final int? marker = value.isEmpty ? null : svg.ids[value];
            if (value.isNotEmpty &&
                (marker == null || svg.nodes[marker].tag != 'marker')) {
              diag.error(
                '$where["$selector"]: ${attr.wire} references #$value, which '
                'is not a <marker>',
              );
              break;
            }
          }
          (out[index] ??= <SvgAttr, Object>{})[attr] = value;
        }
      }
    }
    return out;
  }

  static double _fontSize(SvgDocument svg, int index) {
    for (int i = index; i >= 0; i = svg.nodes[i].parent) {
      final Object? size = svg.nodes[i].props[SvgAttr.fontSize];
      if (size is double) return size;
    }
    return 16;
  }
}
