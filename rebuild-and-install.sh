#!/bin/bash
# rebuild-and-install.sh — rebuild AeroSpace from sources, install it, and restart it. One command.
#
# What it does:
#   1. Builds the release (./script/build-release.sh: universal CLI, Xcode app, codesign, validation)
#   2. Quits the running AeroSpace
#   3. Installs the new app -> /Applications and the new CLI -> ~/.local/bin
#   4. Relaunches and prints the running version
#
# It does NOT rebase. To pull new upstream commits first:
#     git fetch upstream && git rebase upstream/main   # resolve any conflicts, then run this
#
# Usage:
#     ./rebuild-and-install.sh            build + install + restart
#     ./rebuild-and-install.sh --check    validate environment only (no build), then exit
#
# Override install locations with env vars if you ever need to:
#     APP_DEST (default /Applications/AeroSpace.app)  CLI_DEST (default ~/.local/bin/aerospace)

set -euo pipefail

# Resolve this script's real directory (the repo root), even when invoked via a symlink in ~/.local/bin.
source="${BASH_SOURCE[0]}"
while [ -L "$source" ]; do
    dir="$(cd -P "$(dirname "$source")" >/dev/null 2>&1 && pwd)"
    source="$(readlink "$source")"
    [[ "$source" != /* ]] && source="$dir/$source"
done
cd "$(cd -P "$(dirname "$source")" >/dev/null 2>&1 && pwd)"

APP_DEST="${APP_DEST:-/Applications/AeroSpace.app}"
CLI_DEST="${CLI_DEST:-$HOME/.local/bin/aerospace}"

check_only=0
[ "${1:-}" = "--check" ] && check_only=1

if [ "$check_only" = 1 ]; then
    echo "repo:     $PWD"
    echo "bash:     $(bash -c 'echo $BASH_VERSION') (the build scripts need 5 or newer)"
    echo "swift:    $(swift --version 2>&1 | head -1)"
    [ -x ./script/build-release.sh ] && echo "build:    ./script/build-release.sh OK" || { echo "build:    ./script/build-release.sh MISSING" >&2; exit 1; }
    echo "app dest: $APP_DEST"
    echo "cli dest: $CLI_DEST"
    echo "OK — environment looks good. Run without --check to build + install."
    exit 0
fi

# --- build ------------------------------------------------------------------
echo "==> Building release (a few minutes)…"
./script/build-release.sh

# --- install ----------------------------------------------------------------
echo "==> Quitting running AeroSpace (if any)…"
osascript -e 'quit app "AeroSpace"' 2>/dev/null || true
for _ in $(seq 1 20); do
    pgrep -f "AeroSpace.app/Contents/MacOS/AeroSpace" >/dev/null 2>&1 || break
    sleep 0.5
done

echo "==> Installing app  -> $APP_DEST"
rm -rf "$APP_DEST"
cp -r .release/AeroSpace.app "$APP_DEST"

echo "==> Installing CLI  -> $CLI_DEST"
mkdir -p "$(dirname "$CLI_DEST")"
cp .release/aerospace "$CLI_DEST"

# --- relaunch + verify ------------------------------------------------------
echo "==> Relaunching…"
open "$APP_DEST"

echo "==> Waiting for AeroSpace server to come up…"
for _ in $(seq 1 30); do
    "$CLI_DEST" --version 2>/dev/null | grep -q "server version: 0.0.0-SNAPSHOT" && break
    sleep 0.5
done

echo "==> Done. Installed version:"
"$CLI_DEST" --version
