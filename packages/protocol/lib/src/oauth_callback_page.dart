import 'dart:convert';

/// What an OAuth callback page is reporting, which sets its mark and heat.
enum OAuthCallbackTone { success, failure, notice }

/// Renders the page a browser lands on after an OAuth redirect.
///
/// The daemon and the app's loopback listener both serve it. It is a single
/// self-contained document: the listener may close right after responding, so
/// nothing can be fetched afterwards. Colors mirror
/// `packages/app/lib/src/theme.dart`; the look follows `site/public/style.css`.
String oauthCallbackPage({
  required String title,
  required String message,
  required OAuthCallbackTone tone,
}) {
  const HtmlEscape escape = HtmlEscape();
  final String safeTitle = escape.convert(title);
  final String safeMessage = escape.convert(message);
  final (String name, String eyebrow, String mark) = switch (tone) {
    OAuthCallbackTone.success => ('success', 'Fresh out of the oven', _check),
    OAuthCallbackTone.failure => ('failure', 'Came out burnt', _bang),
    OAuthCallbackTone.notice => ('notice', 'Nothing more to bake', _info),
  };
  return '''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark light">
<title>$safeTitle · SpeedDial</title>
<link rel="icon" href="$_favicon">
<style>$_style</style>
</head>
<body class="$name">
<header><span class="brand"><span class="brand-mark">$_handset<i></i><i></i><i></i></span>SpeedDial</span></header>
<main>
<div class="mark" aria-hidden="true">$mark</div>
<p class="eyebrow">$eyebrow</p>
<h1>$safeTitle</h1>
<p class="lede">$safeMessage</p>
</main>
</body>
</html>
''';
}

const String _favicon =
    "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' "
    "viewBox='0 0 24 32'%3E%3Cpath fill='%23FF7A33' d='M12 1c1.2 5-3.4 7.6-5.6 "
    '11.4C4.7 15.3 3 18 3 21.5 3 27 7 31 12 31s9-4 9-9.4c0-3.6-1.6-6.2-3.3-8.4.2 '
    "2.2-.6 4-2.2 4.8.4-6.4-2-12-3.5-17z'/%3E%3C/svg%3E";

const String _handset =
    '<svg viewBox="0 0 64 64" aria-hidden="true"><path fill="currentColor" '
    'transform="scale(-1,1) translate(-64,0)" d="M43.5 9.5c1.6-1.6 4.2-1.6 5.8 '
    '0l5.2 5.2c2.3 2.3 2.9 5.8 1.3 8.7-7.3 13.6-18.5 24.8-32.1 32.1-2.9 1.6-6.4 '
    '1-8.7-1.3l-5.2-5.2c-1.6-1.6-1.6-4.2 0-5.8l7.4-7.4c1.6-1.6 4.2-1.6 5.8 0l3.4 '
    '3.4c5.6-3.4 10.3-8.1 13.7-13.7l-3.4-3.4c-1.6-1.6-1.6-4.2 0-5.8z"/></svg>';

const String _check =
    '<svg viewBox="0 0 24 24"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>';

const String _bang =
    '<svg viewBox="0 0 24 24"><path d="M12 5.5v8.5M12 18.4v.1"/></svg>';

const String _info =
    '<svg viewBox="0 0 24 24"><path d="M12 5.6v.1M12 10.5v8"/></svg>';

const String _style = r'''
:root {
  --canvas: #000; --card: #1c1b19; --outline: #3f3d39;
  --fg: #ece9e3; --muted: #9b978f; --lede: #cfcac1;
  --accent: #ff7a33; --on-accent-soft: #ffc9a8; --error: #f0555c;
  --root: #e5402a; --tip: #ffc04a; --core: #fff1c9;
  --hot: linear-gradient(180deg, var(--core) 0%, var(--tip) 38%, var(--accent) 70%, var(--root) 100%);
  --glow-root: rgba(229,64,42,.35); --glow-side: rgba(255,122,51,.12);
  --halo: rgba(255,122,51,.28); --halo-hot: rgba(255,160,70,.75);
  --text-glow: rgba(255,122,51,.35); --text-glow-hot: rgba(255,160,70,.7);
  --ease-out: cubic-bezier(.16, 1, .3, 1);
  color-scheme: dark;
}
@media (prefers-color-scheme: light) {
  :root {
    --canvas: #fbfaf7; --card: #fff; --outline: #ccc7bc;
    --fg: #1c1b19; --muted: #6a665e; --lede: #4a4740;
    --accent: #d9531a; --on-accent-soft: #7a2a06; --error: #c8323a;
    --root: #c2301a; --tip: #f7a825; --core: #ffe6a1;
    --hot: linear-gradient(180deg, var(--tip) 0%, var(--accent) 48%, var(--root) 100%);
    --glow-root: rgba(217,83,26,.16); --glow-side: rgba(247,168,37,.12);
    --halo: rgba(217,83,26,.16); --halo-hot: rgba(247,168,37,.55);
    --text-glow: rgba(217,83,26,.12); --text-glow-hot: rgba(247,168,37,.4);
    color-scheme: light;
  }
}
* { box-sizing: border-box; }
html { height: 100%; }
body {
  position: relative; isolation: isolate; overflow-x: hidden;
  min-height: 100%; margin: 0;
  display: grid; grid-template-rows: auto 1fr;
  background: var(--canvas); color: var(--fg);
  font: 400 17px/1.6 "IBM Plex Sans", system-ui, sans-serif;
  -webkit-font-smoothing: antialiased;
}
::selection { background: var(--accent); color: #1b0d04; }
header { padding: 14px clamp(16px, 4vw, 40px); }
.brand { display: inline-flex; align-items: center; gap: 10px; font-weight: 700; font-size: 19px; letter-spacing: -.01em; }
.brand-mark { position: relative; width: 30px; height: 30px; color: var(--accent); }
.brand-mark svg { display: block; width: 100%; height: 100%; }
.brand-mark i {
  position: absolute; height: 3px; border-radius: 2px;
  background: linear-gradient(90deg, transparent, var(--accent));
  transform: rotate(-40deg);
}
.brand-mark i:nth-of-type(1) { top: 15px; width: 9px; left: 2px; }
.brand-mark i:nth-of-type(2) { top: 20px; width: 10px; left: 5px; }
.brand-mark i:nth-of-type(3) { top: 25px; width: 8px; left: 9px; }
main {
  display: flex; flex-direction: column; align-items: center; justify-content: center;
  padding: 32px clamp(20px, 6vw, 96px) 96px; text-align: center;
}
.mark {
  display: grid; place-items: center;
  width: 72px; height: 72px; margin-bottom: 28px;
  border: 1px solid var(--outline); border-radius: 50%;
  background: var(--card); color: var(--muted);
}
.mark svg {
  width: 34px; height: 34px; fill: none; stroke: currentColor;
  stroke-width: 2.4; stroke-linecap: round; stroke-linejoin: round;
}
.eyebrow {
  margin: 0 0 18px; color: var(--muted);
  font: 500 13px/1.3 "IBM Plex Mono", ui-monospace, monospace;
  letter-spacing: .12em; text-transform: uppercase;
}
h1 {
  margin: 0; max-width: 14em; font-size: clamp(38px, 6vw, 64px); font-weight: 700;
  line-height: 1.05; letter-spacing: -.02em; overflow-wrap: anywhere;
}
.lede {
  max-width: 34em; margin: 24px 0 0; color: var(--lede);
  font-size: clamp(18px, 1.5vw, 21px); overflow-wrap: anywhere;
}

/* Success comes out hot: the mark pops once and the heading cools. */
.success::before {
  content: ""; position: absolute; z-index: -1; inset: auto 0 0; height: 70%;
  pointer-events: none;
  background: radial-gradient(ellipse at 70% 100%, var(--glow-root), transparent 60%),
              radial-gradient(ellipse at 30% 100%, var(--glow-side), transparent 55%);
}
.success .mark {
  border-color: var(--accent); color: var(--accent);
  box-shadow: 0 0 28px var(--halo);
  animation: pop .7s var(--ease-out), cool 1.2s ease-out;
}
.success .eyebrow { color: var(--on-accent-soft); }
.success h1 {
  background: var(--hot); -webkit-background-clip: text; background-clip: text; color: transparent;
  filter: drop-shadow(0 0 16px var(--text-glow));
  animation: forge 1.2s ease-out;
}
@keyframes pop { from { opacity: 0; transform: scale(.6); } 55% { opacity: 1; transform: scale(1.08); } }
@keyframes cool { from { box-shadow: 0 0 56px 8px var(--halo-hot); } }
@keyframes forge { from { filter: drop-shadow(0 0 30px var(--text-glow-hot)); } }

/* Failure is a cold oven: no heat, no motion. */
.failure .mark { border-color: var(--error); color: var(--error); }
.failure .eyebrow { color: var(--error); }

@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after { animation: none !important; transition: none !important; }
}
''';
