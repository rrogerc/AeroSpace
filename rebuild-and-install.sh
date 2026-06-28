#!/bin/bash
# rebuild-and-install.sh — rebuild AeroSpace from sources, install it, and restart it. One command.
#
# What it does:
#   1. Builds the release (./build-release.sh: docs, completion, universal binary, Xcode, validation)
#   2. Quits the running AeroSpace
#   3. Installs the new app -> /Applications and the new CLI -> ~/bin
#   4. Relaunches and prints the running version
#
# It handles the Ruby quirk automatically: the Gemfile pins `ruby ~> 3.0`, but the default `ruby`
# here is too new (4.x) and /usr/bin/ruby is too old (2.6), so we put keg-only `ruby@3.4` first on
# PATH (what build-release.sh's docs step needs). Nothing to remember.
#
# It does NOT rebase. To pull new upstream commits first:
#     git fetch upstream && git rebase upstream/main   # resolve any conflicts, then run this
#
# Usage:
#     ./rebuild-and-install.sh            build + install + restart
#     ./rebuild-and-install.sh --check    validate environment only (no build), then exit
#
# Override install locations / Ruby with env vars if you ever need to:
#     APP_DEST (default /Applications/AeroSpace.app)  CLI_DEST (default ~/bin/aerospace)  RUBY_FORMULA (default ruby@3.4)

set -euo pipefail

# Resolve this script's real directory (the repo root), even when invoked via a symlink in ~/bin.
source="${BASH_SOURCE[0]}"
while [ -L "$source" ]; do
    dir="$(cd -P "$(dirname "$source")" >/dev/null 2>&1 && pwd)"
    source="$(readlink "$source")"
    [[ "$source" != /* ]] && source="$dir/$source"
done
cd "$(cd -P "$(dirname "$source")" >/dev/null 2>&1 && pwd)"

APP_DEST="${APP_DEST:-/Applications/AeroSpace.app}"
CLI_DEST="${CLI_DEST:-$HOME/bin/aerospace}"
RUBY_FORMULA="${RUBY_FORMULA:-ruby@3.4}"

check_only=0
[ "${1:-}" = "--check" ] && check_only=1

# --- pick the project-required Ruby -----------------------------------------
ruby_bin="$(brew --prefix "$RUBY_FORMULA" 2>/dev/null)/bin"
if [ -x "$ruby_bin/ruby" ]; then
    export PATH="$ruby_bin:$PATH"
else
    echo "error: $RUBY_FORMULA not found. Install it with:" >&2
    echo "    brew install $RUBY_FORMULA" >&2
    echo "    \"\$(brew --prefix $RUBY_FORMULA)/bin/gem\" install bundler -v 2.7.1" >&2
    exit 1
fi

if [ "$check_only" = 1 ]; then
    echo "repo:     $PWD"
    echo "ruby:     $(ruby --version)"
    echo "bundler:  $(bundle --version 2>/dev/null || echo '?')"
    [ -x ./build-release.sh ] && echo "build:    ./build-release.sh OK" || { echo "build:    ./build-release.sh MISSING" >&2; exit 1; }
    echo "app dest: $APP_DEST"
    echo "cli dest: $CLI_DEST"
    echo "OK — environment looks good. Run without --check to build + install."
    exit 0
fi

# --- build ------------------------------------------------------------------
echo "==> Building release with $(ruby --version | awk '{print $1, $2}') (a few minutes)…"
./build-release.sh

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
