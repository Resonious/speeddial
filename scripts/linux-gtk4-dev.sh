#!/usr/bin/env bash
# linux-gtk4-dev.sh — run SpeedDial (debug, hot reload) against the local GTK4
# Flutter fork.
#
#   scripts/linux-gtk4-dev.sh [--demo] [extra flutter run args...]
#
# --demo uses the in-memory fake daemon (no real daemon needed); without it the
# app expects a daemon per AGENTS.md. Extra args pass through to flutter run.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/linux-gtk4-env.sh"

demo=0
if [ "${1:-}" = "--demo" ]; then demo=1; shift; fi

gtk4_env_check
gtk4_env_resolve_prefix
gtk4_absorb_tool_rebuild
gtk4_ensure_runner

cd "$APP_DIR"
args=(run -d linux
  --local-engine=linux_debug_unopt_x64 --local-engine-host=linux_debug_unopt_x64
  --linux-dir=linux-gtk4 --linux-gtk=gtk4)
[ "$demo" = 1 ] && args+=(--dart-define=demo=true)
args+=("$@")

echo "+ flutter ${args[*]}"
exec env "${GTK4_ENGINE_ENV[@]}" "${GTK4_BUILD_ENV[@]}" "${GTK4_RUN_ENV[@]}" \
  "$FLUTTER" "${args[@]}"
