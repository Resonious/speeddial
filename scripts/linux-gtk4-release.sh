#!/usr/bin/env bash
# linux-gtk4-release.sh — production (AOT release) build of SpeedDial against
# the local GTK4 Flutter fork.
#
#   scripts/linux-gtk4-release.sh [extra flutter build args...]
#
# Output: packages/app/build/linux-gtk4/x64/release/bundle/
# A `speeddial` wrapper is written into the bundle when the runtime needs the
# extracted GTK4 prefix libs (LD_LIBRARY_PATH); otherwise run speeddial_app
# directly.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/linux-gtk4-env.sh"

gtk4_env_check
gtk4_env_resolve_prefix
gtk4_absorb_tool_rebuild
gtk4_ensure_runner

cd "$APP_DIR"
env "${GTK4_ENGINE_ENV[@]}" "${GTK4_BUILD_ENV[@]}" "$FLUTTER" build linux --release \
  --local-engine=linux_release_x64 --local-engine-host=linux_release_x64 \
  --linux-dir=linux-gtk4 --linux-gtk=gtk4 "$@"

bundle="$APP_DIR/build/linux-gtk4/x64/release/bundle"
if [ ${#GTK4_RUN_ENV[@]} -gt 0 ]; then
  cat > "$bundle/speeddial" <<EOF
#!/usr/bin/env bash
exec env ${GTK4_RUN_ENV[*]} "\$(dirname "\${BASH_SOURCE[0]}")/speeddial_app" "\$@"
EOF
  chmod +x "$bundle/speeddial"
  echo "run it: $bundle/speeddial"
else
  echo "run it: $bundle/speeddial_app"
fi
