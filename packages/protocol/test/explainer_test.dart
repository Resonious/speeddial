import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:test/test.dart';

const String _svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 200">
  <style>
    .box { fill: var(--surface); stroke: var(--border); }
    #db { stroke: var(--accent); }
    rect.hot { stroke-width: 3; }
  </style>
  <defs>
    <marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5"
            markerWidth="6" markerHeight="6" orient="auto-start-reverse">
      <path d="M0 0 L10 5 L0 10 z" fill="var(--muted)"/>
    </marker>
  </defs>
  <g id="client" class="box">
    <rect x="10" y="80" width="80" height="40" rx="6"/>
    <text x="50" y="100" text-anchor="middle" dominant-baseline="middle">
      Client <tspan font-weight="bold">app</tspan>
    </text>
    <title>The browser</title>
  </g>
  <rect id="db" class="box hot" x="300" y="80" width="80" height="40"
        style="fill: #fff8; opacity: 0.5"/>
  <line id="req" x1="90" y1="100" x2="300" y2="100" stroke="var(--fg)"
        marker-end="url(#arrow)" opacity="0"/>
</svg>
''';

ExplainerSpec _spec({
  String svg = _svg,
  List<ExplainerStepSpec> steps = const <ExplainerStepSpec>[],
  List<ExplainerToggleSpec> toggles = const <ExplainerToggleSpec>[],
}) => ExplainerSpec(title: 'Request', svg: svg, steps: steps, toggles: toggles);

List<String> _errors(ExplainerSpec spec) {
  try {
    ExplainerDocument.parse(spec);
  } on ExplainerException catch (e) {
    return e.errors;
  }
  fail('expected ExplainerException');
}

void main() {
  group('ExplainerDocument.parse', () {
    test('builds the tree, cascade, markers, text runs, and tooltips', () {
      final ExplainerDocument doc = ExplainerDocument.parse(_spec());
      final SvgDocument svg = doc.svg;
      expect(svg.viewBox.width, 400);
      expect(svg.nodes.first.tag, 'svg');

      final SvgNode client = svg.nodes[svg.ids['client']!];
      expect(client.title, 'The browser');
      expect(client.props[SvgAttr.fill], const SvgThemeColor('surface'));

      // id rule beats class rule; inline style beats both.
      final SvgNode db = svg.nodes[svg.ids['db']!];
      expect(db.props[SvgAttr.stroke], const SvgThemeColor('accent'));
      expect(db.props[SvgAttr.strokeWidth], 3);
      expect(db.props[SvgAttr.fill], const SvgColor(0x88FFFFFF));
      expect(db.props[SvgAttr.opacity], 0.5);

      final SvgNode marker = svg.nodes[svg.ids['arrow']!];
      expect(marker.marker!.refX, 9);
      expect(marker.orientReverse, isTrue);
      expect(svg.nodes[svg.ids['req']!].props[SvgAttr.markerEnd], 'arrow');

      final List<String> runs = <String>[
        for (final SvgNode node in svg.nodes)
          if (node.tag == '#text') node.props[SvgAttr.text]! as String,
      ];
      // The trailing run collapses to nothing.
      expect(runs, <String>['Client ', 'app', '']);
      expect(doc.steps, hasLength(1));
    });

    test('steps accumulate and toggles resolve', () {
      final ExplainerDocument doc = ExplainerDocument.parse(
        _spec(
          steps: const <ExplainerStepSpec>[
            ExplainerStepSpec(caption: 'Idle'),
            ExplainerStepSpec(
              caption: 'Request',
              set: <String, Map<String, Object>>{
                '#req': <String, Object>{'opacity': 1},
              },
            ),
            ExplainerStepSpec(
              caption: 'Lookup',
              set: <String, Map<String, Object>>{
                '.box': <String, Object>{'stroke': 'var(--success)'},
              },
            ),
          ],
          toggles: const <ExplainerToggleSpec>[
            ExplainerToggleSpec(
              label: 'Labels',
              on: true,
              set: <String, Map<String, Object>>{
                'text': <String, Object>{'text': 'Browser'},
              },
            ),
          ],
        ),
      );
      final int req = doc.svg.ids['req']!;
      final int db = doc.svg.ids['db']!;
      expect(doc.steps[0].overrides, isEmpty);
      expect(doc.steps[1].overrides[req]![SvgAttr.opacity], 1);
      expect(doc.steps[2].overrides[req]![SvgAttr.opacity], 1);
      expect(
        doc.steps[2].overrides[db]![SvgAttr.stroke],
        const SvgThemeColor('success'),
      );
      expect(doc.toggles.single.on, isTrue);
      expect(
        doc.toggles.single.overrides.values.single[SvgAttr.text],
        'Browser',
      );
    });

    test('reports every problem at once', () {
      final List<String> errors = _errors(
        _spec(
          svg: '''
<svg viewBox="0 0 10 10">
  <linearGradient id="g"/>
  <circle cx="5" cy="5"/>
  <rect width="2" height="2" fill="var(--nope)"/>
  <foreignObject/>
</svg>''',
          steps: const <ExplainerStepSpec>[
            ExplainerStepSpec(
              caption: 'x',
              set: <String, Map<String, Object>>{
                '#missing': <String, Object>{'fill': 'red'},
              },
            ),
          ],
        ),
      );
      expect(errors.join('\n'), contains('linearGradient'));
      expect(errors.join('\n'), contains('needs r'));
      expect(errors.join('\n'), contains('unknown theme color'));
      expect(errors.join('\n'), contains('foreignObject'));
      expect(errors, hasLength(4));
    });

    test('step problems are reported against a valid svg', () {
      final List<String> errors = _errors(
        _spec(
          steps: const <ExplainerStepSpec>[
            ExplainerStepSpec(
              caption: 'x',
              set: <String, Map<String, Object>>{
                '#missing': <String, Object>{'fill': 'red'},
                '#db': <String, Object>{'r': 4, 'fill': 'blurple'},
                'g > rect': <String, Object>{'fill': 'red'},
                '#req': <String, Object>{'colour': 'red'},
              },
            ),
          ],
        ),
      );
      expect(errors, hasLength(5));
      expect(errors[0], contains('matches no element'));
      expect(errors[1], contains('r does not apply to <rect> #db'));
      expect(errors[2], contains('unknown color "blurple"'));
      expect(errors[3], contains('unsupported selector'));
      expect(errors[4], contains('unknown attribute "colour"'));
    });

    test('requires a viewBox and well-formed XML', () {
      expect(
        _errors(_spec(svg: '<svg><rect width="1" height="1"/></svg>')).single,
        contains('viewBox'),
      );
      expect(
        _errors(_spec(svg: '<svg viewBox="0 0 1 1"><g></svg>')).single,
        contains('not well-formed'),
      );
    });

    test('rejects pathological nesting without overflowing', () {
      final String deep =
          '<svg viewBox="0 0 1 1">${'<g>' * 5000}${'</g>' * 5000}</svg>';
      expect(_errors(_spec(svg: deep)).single, contains('nested more than'));
    });

    test('warns about ignored attributes and css', () {
      final ExplainerDocument doc = ExplainerDocument.parse(
        _spec(
          svg: '''
<svg viewBox="0 0 10 10">
  <style>@keyframes spin {} rect:hover { fill: red; }</style>
  <rect width="2" height="2" filter="url(#f)"/>
</svg>''',
        ),
      );
      expect(doc.warnings, hasLength(3));
    });

    test('dy em offsets resolve against the font size', () {
      final ExplainerDocument doc = ExplainerDocument.parse(
        _spec(
          svg:
              '<svg viewBox="0 0 10 10"><text font-size="10">'
              '<tspan x="0" dy="1.5em">a</tspan></text></svg>',
        ),
      );
      final SvgNode tspan = doc.svg.nodes.firstWhere(
        (SvgNode n) => n.tag == 'tspan',
      );
      expect(tspan.props[SvgAttr.dy], 15);
    });
  });

  group('ExplainerSpec.fromJson', () {
    test('round trips', () {
      final ExplainerSpec spec = ExplainerSpec.fromJson(<String, Object?>{
        'title': 'T',
        'svg': '<svg viewBox="0 0 1 1"/>',
        'steps': <Object?>[
          <String, Object?>{
            'caption': 'one',
            'set': <String, Object?>{
              '#a': <String, Object?>{'opacity': 0.5},
            },
          },
        ],
        'toggles': <Object?>[
          <String, Object?>{
            'label': 'L',
            'set': <String, Object?>{
              '#a': <String, Object?>{'fill': 'red'},
            },
          },
        ],
      });
      expect(ExplainerSpec.fromJson(spec.toJson()).toJson(), spec.toJson());
    });

    test('rejects malformed shapes with readable messages', () {
      expect(
        () => ExplainerSpec.fromJson(<String, Object?>{
          'svg': '<svg/>',
          'steps': <Object?>[
            <String, Object?>{'caption': 'x', 'sets': <String, Object?>{}},
          ],
        }),
        throwsA(
          isA<FormatException>().having(
            (FormatException e) => e.message,
            'message',
            contains('unknown key "sets"'),
          ),
        ),
      );
      expect(
        () => ExplainerSpec.fromJson(<String, Object?>{
          'svg': '<svg/>',
          'steps': <Object?>[
            <String, Object?>{
              'caption': 'x',
              'set': <String, Object?>{'#a': 'red'},
            },
          ],
        }),
        throwsFormatException,
      );
    });
  });

  group('values', () {
    test('colors', () {
      expect(parseCssColor('#abc'), 0xFFAABBCC);
      expect(parseCssColor('#11223344'), 0x44112233);
      expect(parseCssColor('rgb(255, 0, 0)'), 0xFFFF0000);
      expect(parseCssColor('rgba(0 0 255 / 50%)'), 0x800000FF);
      expect(parseCssColor('hsl(120, 100%, 50%)'), 0xFF00FF00);
      expect(parseCssColor('SteelBlue'), 0xFF4682B4);
      expect(parseSvgPaint('none'), const SvgNoPaint());
      expect(parseSvgPaint('currentColor'), const SvgThemeColor('fg'));
      expect(
        parseSvgPaint('context-stroke'),
        const SvgContextPaint(stroke: true),
      );
    });

    test('path data normalizes to absolute commands', () {
      final SvgPathData path = parseSvgPathData(
        'm10 10 h5 v5 l-5 0 z M0 0 c1 1 2 2 3 3 s4 4 5 5 q1 1 2 2 t3 3 '
        'a5 5 0 01 10 10',
      );
      final List<SvgPathVerb> verbs = path.commands
          .map((SvgPathCommand c) => c.verb)
          .toList();
      expect(verbs, <SvgPathVerb>[
        SvgPathVerb.moveTo,
        SvgPathVerb.lineTo,
        SvgPathVerb.lineTo,
        SvgPathVerb.lineTo,
        SvgPathVerb.close,
        SvgPathVerb.moveTo,
        SvgPathVerb.cubicTo,
        SvgPathVerb.cubicTo,
        SvgPathVerb.quadTo,
        SvgPathVerb.quadTo,
        SvgPathVerb.arcTo,
      ]);
      expect(path.commands[2].args, <double>[15, 15]);
      // s reflects the previous control point (2,2) about (3,3).
      expect(path.commands[7].args, <double>[4, 4, 7, 7, 8, 8]);
      // t reflects the previous control point (9,9) about (10,10).
      expect(path.commands[9].args, <double>[11, 11, 13, 13]);
      expect(path.commands[10].args, <double>[5, 5, 0, 0, 1, 23, 23]);
      expect(() => parseSvgPathData('L1 1'), throwsFormatException);
    });

    test('transforms', () {
      final SvgTransform t = parseSvgTransform(
        'translate(10) scale(2) rotate(90 1 1)',
      );
      expect(t.ops.map((SvgTransformOp o) => o.kind), <SvgTransformKind>[
        SvgTransformKind.translate,
        SvgTransformKind.scale,
        SvgTransformKind.rotate,
      ]);
      final (double x, double y) = t.matrix.apply(2, 1);
      expect(x, closeTo(12, 1e-9));
      expect(y, closeTo(4, 1e-9));
      expect(() => parseSvgTransform('spin(3)'), throwsFormatException);
    });
  });

  test('ExplainerEvent round trips and summarizes', () {
    final ExplainerEvent event = ExplainerEvent(
      explainer: _spec(),
      seq: 3,
      timestamp: DateTime.utc(2026),
    );
    final SessionEvent decoded = SessionEvent.fromJson(event.toJson());
    expect(decoded, isA<ExplainerEvent>());
    expect(decoded.toJson(), event.toJson());
    final ExplainerEvent summary =
        summarizeSessionEvent(event) as ExplainerEvent;
    expect(summary.explainer.title, 'Request');
    expect(summary.explainer.svg, isEmpty);
    expect(summary.seq, 3);
  });
}
