import 'package:speeddial_protocol/speeddial_protocol.dart';

/// The explainer the fake daemon shows when a demo message mentions
/// "explain": a SpeedDial turn, with a moving packet, markers, tooltips,
/// and a toggle.
const ExplainerSpec kDemoExplainer = ExplainerSpec(
  title: 'How a SpeedDial turn flows',
  svg: '''
<svg viewBox="0 0 640 220" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5"
            markerWidth="7" markerHeight="7" orient="auto-start-reverse">
      <path d="M0 0 L10 5 L0 10 z" fill="context-stroke"/>
    </marker>
  </defs>
  <style>
    .box { fill: var(--surface); stroke: var(--border); stroke-width: 1.5; }
    .label { font-size: 15px; font-weight: 600; text-anchor: middle; }
    .sub { font-size: 12px; fill: var(--muted); text-anchor: middle; }
    .edge { stroke: var(--muted); stroke-width: 2; fill: none; }
    .latency { font-size: 11px; fill: var(--info); text-anchor: middle; opacity: 0; }
  </style>

  <g id="app">
    <rect class="box" x="20" y="70" width="150" height="70" rx="10"/>
    <text class="label" x="95" y="100">App</text>
    <text class="sub" x="95" y="120">Flutter UI</text>
    <title>Desktop, web, Android, or a watch</title>
  </g>
  <g id="daemon">
    <rect class="box" x="245" y="70" width="150" height="70" rx="10"/>
    <text class="label" x="320" y="100">Daemon</text>
    <text class="sub" x="320" y="120">SQLite + WebSocket</text>
    <title>Persists every event, then broadcasts it</title>
  </g>
  <g id="agent">
    <rect class="box" x="470" y="70" width="150" height="70" rx="10"/>
    <text class="label" x="545" y="100">Agent</text>
    <text class="sub" x="545" y="120">ACP / Codex / Ante</text>
    <title>The wrapped agent harness</title>
  </g>

  <path id="send" class="edge" d="M170 92 L241 92" marker-end="url(#arrow)" opacity="0.25"/>
  <path id="prompt" class="edge" d="M395 92 L466 92" marker-end="url(#arrow)" opacity="0.25"/>
  <path id="stream" class="edge" d="M470 120 C 420 175, 220 175, 174 122"
        stroke-dasharray="6 4" marker-end="url(#arrow)" opacity="0"/>

  <circle id="packet" cx="0" cy="0" r="7" fill="var(--accent)"
          transform="translate(95 40)" opacity="0"/>
  <text id="status" x="320" y="34" font-size="13" text-anchor="middle"
        fill="var(--muted)">Idle</text>

  <text class="latency" id="lat-send" x="207" y="84">~1 ms</text>
  <text class="latency" id="lat-prompt" x="431" y="84">~2 ms</text>
  <text class="latency" id="lat-stream" x="320" y="196">first token ~600 ms</text>
</svg>
''',
  steps: <ExplainerStepSpec>[
    ExplainerStepSpec(
      caption:
          'Three processes take part: the app you are using, the daemon, and '
          'the agent harness it wraps.',
    ),
    ExplainerStepSpec(
      caption: 'You send a message. The app calls sessions.send.',
      set: <String, Map<String, Object>>{
        '#packet': <String, Object>{
          'opacity': 1,
          'transform': 'translate(206 92)',
        },
        '#send': <String, Object>{'opacity': 1, 'stroke': 'var(--accent)'},
        '#status': <String, Object>{'text': 'sessions.send'},
      },
    ),
    ExplainerStepSpec(
      caption:
          'The daemon persists the userMessage event first, then prompts the '
          'agent.',
      set: <String, Map<String, Object>>{
        '#packet': <String, Object>{'transform': 'translate(431 92)'},
        '#send': <String, Object>{'stroke': 'var(--muted)'},
        '#prompt': <String, Object>{'opacity': 1, 'stroke': 'var(--accent)'},
        '#status': <String, Object>{'text': 'persist, then prompt'},
      },
    ),
    ExplainerStepSpec(
      caption:
          'The agent streams chunks back. Each one is stored with a seq and '
          'broadcast to every connected app.',
      set: <String, Map<String, Object>>{
        '#packet': <String, Object>{
          'transform': 'translate(320 158)',
          'fill': 'var(--success)',
        },
        '#prompt': <String, Object>{'stroke': 'var(--muted)'},
        '#stream': <String, Object>{'opacity': 1, 'stroke': 'var(--success)'},
        '#status': <String, Object>{'text': 'session.event × n'},
      },
    ),
    ExplainerStepSpec(
      caption: 'A turnComplete event ends the turn.',
      set: <String, Map<String, Object>>{
        '#packet': <String, Object>{
          'transform': 'translate(95 40)',
          'opacity': 0,
        },
        '#stream': <String, Object>{'stroke': 'var(--muted)'},
        '#status': <String, Object>{
          'text': 'turnComplete',
          'fill': 'var(--success)',
        },
      },
    ),
  ],
  toggles: <ExplainerToggleSpec>[
    ExplainerToggleSpec(
      label: 'Latencies',
      set: <String, Map<String, Object>>{
        '.latency': <String, Object>{'opacity': 1},
      },
    ),
  ],
);
