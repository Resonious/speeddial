# SpeedDial Spec

An "ADE" (agent development environment) called "Speed Dial" with performance as the top priority. Use 
Dart and Flutter for the whole stack. Components:

* Daemon: CLI-only background process that controls actual agent sessions. Should work with `omp`, `codex`, and `claude` for now but keep it exensible. ACP should be pretty universal. Daemon should also support session bookkeeping commands (i.e. sessions, projects, etc), git commit/push/PR commands, and any other command needed to drive the UI.
* UI: Frontend that connects to any number of daemons either via localhost or via the net. Take inspiration from T3 Code (https://t3.codes/updated-screenshot.webp) and paseo (https://paseo.sh/homepage-hero.png). Projects and sessions on the left, agent chat in the center, files/git on the right. Do not just show a terminal window; implement the UI entirely in Flutter. Should work on both desktop and mobile.

Please look up both T3 Code and Paseo (perhaps also Orca) for the full feature list; I want more-or-less feature parity. The goal is to take a pattern which works (those apps) and make it fast (by building it in Flutter).

Development process: split into atomic tasks for subagents to work on. Have independent reviewer agents review the output. Always visually test UI changes.
