# CLAUDE.md

This is a **personal fork** of [AeroSpace](https://github.com/nikitabobko/AeroSpace) (the tiling WM).
Remotes: `origin` = this fork (`rrogerc/AeroSpace`), `upstream` = `nikitabobko/AeroSpace`.

## Custom changes vs upstream

Kept as commits on top of `upstream/main` (they replay on every rebase):

- **`fullscreen --width <0..1>`** — centered partial-width fullscreen (e.g. `aerospace fullscreen --width 0.66`).
  Touches `Sources/Common/cmdArgs/impl/FullscreenCmdArgs.swift`, `Sources/AppBundle/command/impl/FullscreenCommand.swift`,
  `Sources/AppBundle/tree/Window.swift` (`fullscreenWidth`), `Sources/AppBundle/layout/layoutRecursive.swift` (`layoutFullscreen`).
- **`rebuild-and-install.sh`** — the build/install helper described below.

## Rebuild, install, and restart — one command

```bash
./rebuild-and-install.sh          # build + install + restart
./rebuild-and-install.sh --check  # validate environment only, no build
```

(Also runnable as `aerospace-rebuild` — `~/bin/aerospace-rebuild` is a symlink to this script.)

It does, in order:
1. **Picks the right Ruby** — prepends keg-only `ruby@3.4` to `PATH` (see Ruby note below), so no manual `PATH=` prefix is needed.
2. **Builds** the release via `./build-release.sh` (man pages + site, shell completion, universal arm64+x86_64 binary, Xcode app, codesign, validation, zip/brew packaging).
3. **Quits** the running AeroSpace.
4. **Installs** `.release/AeroSpace.app` → `/Applications/AeroSpace.app` and `.release/aerospace` → `~/bin/aerospace`
   (the install is a manual copy — this fork does **not** use the `aerospace-dev` brew cask that `install-from-sources.sh` sets up).
5. **Relaunches**, waits for the server, and prints the running version.

Install locations / Ruby are overridable via env vars: `APP_DEST`, `CLI_DEST`, `RUBY_FORMULA`.

The script deliberately does **not** rebase (conflicts need a human). The full update flow is:

```bash
git fetch upstream && git rebase upstream/main   # resolve any conflicts (usually FullscreenCmdArgs.swift)
./rebuild-and-install.sh
git push --force-with-lease origin main          # update the fork (rebase rewrites history)
```

## Ruby note (why the script juggles versions)

The `Gemfile` pins `ruby '~> 3.0'` (>=3.0, <4.0) and `Gemfile.lock` pins `BUNDLED WITH 2.7.1`.
On this machine `/usr/bin/ruby` is 2.6 (too old) and the brew default `ruby` is 4.x (too new), so **neither works**.
Fix (one-time): `brew install ruby@3.4` then `"$(brew --prefix ruby@3.4)/bin/gem" install bundler -v 2.7.1`.
`ruby@3.4` is keg-only (not on the default `PATH`); `rebuild-and-install.sh` adds it to `PATH` for the build so
`build-release.sh`'s docs step (`build-docs.sh` → `bundle`) resolves to it. Gems vendor into `.deps/bundler-path`.

If you ever build with `build-release.sh` directly, prefix it: `PATH="$(brew --prefix ruby@3.4)/bin:$PATH" ./build-release.sh`.

## Prerequisites (already set up here)

- Swift 6.2.3 (`.swift-version`); `/usr/bin/swift` matches, so `swiftly` is not required.
- Self-signed codesign cert **`aerospace-codesign-certificate`** in Keychain. Rebuilding with the same cert keeps
  macOS Accessibility permission across reinstalls (no re-approval prompt).
- Rust/cargo (for shell completion), `ruby@3.4` + bundler 2.7.1 (for docs).

## Conventions

- Build scripts live at the repo root and `cd "$(dirname "$0")"`. `script/setup.sh` nukes `PATH` to
  `.deps/bin:/bin:/usr/bin` and wraps optional tools resolved via `which` at source time — that's why Ruby must be
  on `PATH` *before* invoking the build.
- See `dev-docs/development.md` for upstream's documented (brew-cask) build flow.
