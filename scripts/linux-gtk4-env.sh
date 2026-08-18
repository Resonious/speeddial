#!/usr/bin/env bash
# linux-gtk4-env.sh — shared environment for the GTK4 Linux build scripts.
# Sourced by linux-gtk4-dev.sh / linux-gtk4-release.sh; run directly for a
# sanity report ("doctor").
#
# Assumes the fork is checked out at ../flutter-gtk4 relative to the repo root
# (override with FLUTTER_GTK4=/path). The fork must be set up once via its
# gtk4-bootstrap.sh; these scripts only drive app builds.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$REPO_ROOT/packages/app"
FLUTTER_GTK4="${FLUTTER_GTK4:-$REPO_ROOT/../flutter-gtk4}"
FLUTTER="$FLUTTER_GTK4/bin/flutter"
ENGINE_SRC="$FLUTTER_GTK4/engine/src"
GTK4_PREFIX="${GTK4_PREFIX:-$HOME/gtk4-prefix}"

# Must match a commit with published CI artifacts (the fork's own content hash
# has none). Keep in sync with BASE_COMMIT in $FLUTTER_GTK4/gtk4-bootstrap.sh.
PREBUILT_ENGINE_VERSION="${FLUTTER_PREBUILT_ENGINE_VERSION:-e329e87291ecce47b13da7386511e5c5aae1b056}"

gtk4_env_die() { echo "error: $*" >&2; exit 1; }

gtk4_env_check() {
  [ -x "$FLUTTER" ] || gtk4_env_die "no flutter at $FLUTTER (set FLUTTER_GTK4=/path/to/fork)"
  [ -d "$ENGINE_SRC/out" ] || gtk4_env_die "engine not built; run $FLUTTER_GTK4/gtk4-bootstrap.sh first"
}

# PKG_CONFIG_*/LDFLAGS are for the APP runner only (gtk4 headers/libs). Never
# export them into engine gn/ninja shells — they rebase sysroot paths.
GTK4_BUILD_ENV=()
GTK4_RUN_ENV=()
gtk4_env_resolve_prefix() {
  if pkg-config --exists gtk4 2>/dev/null && [ -z "${PKG_CONFIG_PATH:-}" ]; then
    return # system gtk4-devel; nothing to do
  fi
  if [ -f "$GTK4_PREFIX/usr/lib64/pkgconfig/gtk4.pc" ]; then
    GTK4_BUILD_ENV+=(
      "PKG_CONFIG_PATH=$GTK4_PREFIX/usr/lib64/pkgconfig:$GTK4_PREFIX/usr/share/pkgconfig"
      "PKG_CONFIG_SYSROOT_DIR=$GTK4_PREFIX"
      "LDFLAGS=-L$GTK4_PREFIX/usr/lib64 -Wl,-rpath-link,$GTK4_PREFIX/usr/lib64"
    )
    GTK4_RUN_ENV+=("LD_LIBRARY_PATH=$GTK4_PREFIX/usr/lib64")
  else
    gtk4_env_die "no gtk4 devel files; install gtk4-devel or run $FLUTTER_GTK4/gtk4-bootstrap.sh to extract $GTK4_PREFIX"
  fi
}

GTK4_ENGINE_ENV=(
  "FLUTTER_ENGINE=$ENGINE_SRC"
  "FLUTTER_PREBUILT_ENGINE_VERSION=$PREBUILT_ENGINE_VERSION"
)

# The tool keys its snapshot on git HEAD; the invocation that rebuilds it fails
# if FLUTTER_ENGINE is set (bootstrap self-invocation lacks --local-engine).
# Run a cheap no-op first without it.
gtk4_absorb_tool_rebuild() {
  env -u FLUTTER_ENGINE "FLUTTER_PREBUILT_ENGINE_VERSION=$PREBUILT_ENGINE_VERSION" \
    "$FLUTTER" --version >/dev/null
}

# Generate the GTK4 runner on demand; linux/ (GTK3) stays untouched.
# linux-gtk4/ is intentionally not committed — regenerate after flutter upgrades.
gtk4_ensure_runner() {
  if [ ! -f "$APP_DIR/linux-gtk4/CMakeLists.txt" ]; then
    echo "generating GTK4 runner in packages/app/linux-gtk4/ ..."
    env -u FLUTTER_ENGINE "FLUTTER_PREBUILT_ENGINE_VERSION=$PREBUILT_ENGINE_VERSION" \
      "$FLUTTER" create --platforms=linux --linux-gtk=gtk4 --linux-dir=linux-gtk4 "$APP_DIR" >/dev/null
    grep -qxF 'packages/app/linux-gtk4/' "$REPO_ROOT/.git/info/exclude" 2>/dev/null || \
      echo 'packages/app/linux-gtk4/' >> "$REPO_ROOT/.git/info/exclude"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "fork:          $FLUTTER_GTK4 ($(git -C "$FLUTTER_GTK4" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?'))"
  echo "engine builds: $(ls "$ENGINE_SRC/out" 2>/dev/null | tr '\n' ' ')"
  echo "runner:        $([ -f "$APP_DIR/linux-gtk4/CMakeLists.txt" ] && echo present || echo missing)"
  echo "gtk4 prefix:   $([ -f "$GTK4_PREFIX/usr/lib64/pkgconfig/gtk4.pc" ] && echo "$GTK4_PREFIX" || echo none/system)"
  echo "base commit:   $PREBUILT_ENGINE_VERSION"
fi
