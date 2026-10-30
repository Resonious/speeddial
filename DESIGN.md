# DESIGN.md — SpeedDial's look: the oven

SpeedDial's UI has a deliberate theme: **the agent is an oven.** A turn burns as a flame, a sent
message bakes and pops out of the oven, freshly written text glows like hot metal and cools,
compaction simmers down, a reconnect reheats. The effects exist to make real moments legible at a
glance and to make the app a pleasure to watch work. They are part of the product, not
decoration, so new features should get them too, in the same spirit and with the same discipline.

Read this before building or changing anything users see. When you add a new kind of effect, add
it here.

## Moments and their effects

Every effect marks something that actually happened. Reuse these before writing a new painter.

| Moment | Effect | Where (`packages/app/lib/src/ui/`) |
|---|---|---|
| Release build running | Steady ember border and “Building…” label on the download page; clears on completion or connection failure, no motion | `scripts/downloads.html` |
| External PR link dragged over the app | Steady theme ember border and a clear drop hint; disappears on leave/drop, no ticker in either motion mode | `pull_request_drop_region.dart` |
| Quote/code copied | Copy action becomes an ember-colored check and “Copied” for two seconds; no layout movement or continuous animation | `chat/markdown_blocks.dart` |
| Image download result | A brief fade into the save receipt; a saved image shows an ember-colored check. Reduced motion shows the result immediately. | `chat/image_viewer.dart` |
| Reply staged from a selection | The inline reply box fades and scales in beside the text; the new composer chip pops with an elastic bounce and an ember halo that cools; the chip's editor and a sent reply's detail ease open. All still under reduced motion. | `chat/replies.dart` |
| Archived session restored | A success toast (ember check) saying “Session restored”; the archived banner eases away (immediate under reduced motion) | `session_restored_notice.dart`, `chat/chat_pane.dart` |
| Notice or failure (toast) | Drops in below the top bar with a slight overshoot, with a neutral card and a tone icon (info muted, success ember check); only errors tint the card red. Hover holds its plain timer (no ticker while it sits), × or timeout lifts it out and the stack closes up. Never covers the composer. Reduced motion: appears and leaves at once | `toast.dart` (`showToast`) |
| Message sent, not yet confirmed | Pale "dough" bubble under a veil, a warm glint sweeping it | `chat/oven.dart` (`BakingBubble`) |
| Large file uploading with a sent message | An ember crust browns left to right along the dough bubble's bottom edge as bytes go out, under a plain "Uploading… 42%" label; driven by real progress, so it holds still under reduced motion | `chat/oven.dart` (`BakingBubble.upload`) |
| Message confirmed | Pops: a small bounce, a warm halo, wisps of steam | `chat/oven.dart` (`DeliveredPop`) |
| Agent's turn | Flame row at the live end: "Preheating…", then a per-turn cooking verb ("Baking…", "Caramelizing…"), "Keeping warm…" with a blue pilot light while waiting on the user; goes out in smoke | `chat/oven.dart` (`TurnFlameRow`), `flame.dart` (`Flame`) |
| Session running / waiting (left rail) | Live flame / amber "timer" face (a ring with a centre pip, never a solid dot, so it can't pass for a warm idle ember) that rattles and chimes twice outward; still and frozen mid-chime under reduced motion | `left/session_status_glyph.dart` |
| Recently idle session | Steady ember dot and halo cool from hot to gray over three hours of inactivity; minute-resolution refresh, no animation ticker. A done session shows a slightly larger green dot in a steady green halo (the same footprint as a hot ember, so it never reads as the smaller mark), swelling in when marked done. Offline dots are cold. | `left/idle_session_ember.dart` |
| Daemon out of reach | Flames grey and still; nothing claims to be live | `Flame(dormant: true)`; the pane derives the turn as not running |
| Agent writing | Typewriter with an ember at the typing point and a few sparks; fresh text glows behind it and cools; the ember pops (flash, burst of sparks, smoke) when the message is done | `chat/typewriter.dart` |
| Tool call running | Icon glows hot, a glint sweeps its title, elapsed time ticks; cools when done | `chat/tool_call_heat.dart`, `chat/heat_shimmer.dart` |
| Busy run of tool calls and thinking | One steady cell: the thought streams on its own line, the call's description types, backspaces and retypes | `chat/tool_run.dart`, `chat/typed_text.dart`, `chat/thought_line.dart` |
| Mobile session title tapped | A rounded title card fades and expands gently from the top over a dimmed backdrop (240 ms ease-out); full selectable text scrolls within the available height. Reduced motion opens and closes immediately. | `session_title_dialog.dart` |
| Session renamed (left rail, top bar) | The old name backspaces to what it shares with the new one under an ember caret, then the new name types in; the Linux header bar types the same way (no caret) while the window title takes the new name at once; switching sessions, and reduced motion, swap it at once | `left/session_list.dart` (`SessionRow`), `shell.dart` (`_TopBarTitle`, `_NativeTitleBarSync`), `chat/typed_text.dart` (`TypedText`, `TextTyper`) |
| Session preparing (composer) | Each new preparation step backspaces the last to what they share and types in under an ember caret, about three times a rename's pace so quick steps still read; the hint sits at the far end of the line so the typing never moves it | `chat/composer.dart` (`_PreparationNotice`), `chat/typed_text.dart` |
| Subagents | A crew of small flames that flare as they report, cold once the turn ends | `chat/subagent_crew.dart` |
| Compaction | Divider: "Reducing the conversation…" with bubbles simmering along the line, then "Conversation reduced · 313k → 48k tokens" | `chat/compaction.dart` |
| Catching up after a reconnect | Strip rises with a flame while a haze "reheats" the stale timeline; missed rows rise into place | `chat/catching_up.dart` |
| History loading | A ghost of the conversation under a warm glint; dims and stills on failure | `chat/history_skeleton.dart` |
| Landing at the bottom | Sparks fly up off the bottom edge | `chat/landing_sparks.dart` |
| New activity below while scrolled up | Jump button flares like a fanned ember; rises in and sinks out | `chat/latest_button.dart` |

## Palette

Use the theme's tokens (`Theme.of(context).speedDialColors`, `colorScheme`); never hard-code colors.

- `colorScheme.primary` is the ember: the flame's body, sparks as they cool.
- `flameRoot` is the deep red-orange root. `flameTip` is amber: glints, hot sparks, the afterglow.
  `flameCore` is the pale, white-hot core.
- Status: `running` (blue), `waitingPermission` (amber), `error` (red), `idle` (grey); `border` for
  hairlines.
- **Light vs dark.** White-hot vanishes on a light canvas, so start amber there. Glows are fainter
  on light (see the `glowStrength` values). Over text, add light on dark (`BlendMode.plus`) and tint
  with `BlendMode.multiply` on light, so text keeps its contrast; never wash text with a translucent
  film.

## Motion rules

1. **Mark real moments.** Sent, confirmed, written, done, landed, failed. Nothing animates without a
   reason, and nothing idles on screen for decoration.
2. **One coherent effect beats many particles.** Lots of tiny sparks read as dust or static. Prefer
   a glow, a streak or a pop; keep particles few, and slow them (drag) so they stay near their
   source.
3. **Short, finite, live only.** One-shot effects finish within about a second. Loops (flicker,
   glint, simmer) run only while their thing is actually live, and every ticker stops when it is
   done.
4. **Never jolt the layout.** Sizes ease (`AnimatedSize`, or the size animation a cross-fade already
   has; don't nest them, nested ones stall). Swaps fade through, the old out before the new comes in,
   so text never overlaps. Long content is capped and scrolls within. A view following the bottom
   keeps following.
5. **Patience before loaders.** Anything that may vanish quickly waits out a blink (about 120 to
   150 ms) before showing, so fast paths never flash.
6. **Out of reach means dormant.** When the daemon can't be reached, flames go grey and still and
   nothing claims to be working.
7. **Reduced motion holds still.** Honour `MediaQuery.disableAnimations`: show the end state at once,
   run no tickers. `AnimatedSize` can't take a zero duration, so leave it out instead.
8. **Play once.** One-shot effects play on first build only; rebuilds and scrolling back never replay
   them. State that must survive a row being rebuilt (open or closed, typing progress) lives in
   `PageStorage` under explicit ids, because the timeline rebuilds rows that grow past the screen.
9. **Repaint, don't rebuild.** Drive painters with `repaint:` animations, keep the work in `paint` or
   a render object, isolate with `RepaintBoundary`, reuse `Paint` and `Path` objects. No per-frame
   allocation in `build`.
10. **Clarity first in copy.** Kitchen words add charm ("Preheating…", "Keeping warm…", "Reducing
    the conversation…"), but a label must still say what is happening.

## Giving a new feature its eye candy

1. Name the moment, and pick its kitchen metaphor: baking, simmering, reheating, a pop, steam,
   embers. If nothing fits, a plain, well-eased transition beats a forced metaphor.
2. Reuse the pieces above before writing a new painter.
3. Wire up reduced motion, both themes, and the dormant (daemon out of reach) state.
4. **Look at it** (below), frame by frame, in both themes, and tune until it reads well. Most first
   drafts are too strong, too noisy, or overlap something.
5. Test it: that it plays, that it stops (`tester.hasRunningAnimations` is false afterwards), and
   that it holds still under reduced motion. Break it on purpose and watch a test fail.
6. Add a line to ARCHITECTURE.md and, for a new kind of effect, a row to the table above.

## Seeing and testing effects

- **Render frames in a scratch widget test.** Load real fonts with `FontLoader` (IBM Plex from
  `packages/app/fonts`, Material icons from the Flutter SDK's
  `bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf`), wrap the app in a
  `RepaintBoundary`, pump to fixed times, and write `toImage` PNGs from inside `tester.runAsync`.
  Lay frames side by side (ImageMagick `montage`) to judge the motion, then delete the scratch test.
- **The real app:** the web demo build (see AGENTS.md) in headless Chrome. Demo mode's fake daemon
  delays sends and runs a two-second tool call so the effects show.
- **Assertions:** `paints..circle()`, `..path()`, `..rrect()`, `..line()`, `paintsNothing`, and
  `paints..everything(...)` to count draws. Pump in small steps, since tickers start counting on
  their first frame. Use `FakeAccessibilityFeatures(disableAnimations: true)` for reduced motion.
