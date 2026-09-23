This is a **personal fork** of [AeroSpace](https://github.com/nikitabobko/AeroSpace) (the tiling WM).
Remotes: `origin` = this fork (`rrogerc/AeroSpace`), `upstream` = `nikitabobko/AeroSpace`.

## Custom changes vs upstream

Kept as commits on top of `upstream/main` (they replay on every rebase):

- **`fullscreen --width <0..1>`** — centered partial-width fullscreen (e.g. `aerospace fullscreen --width 0.66`).
  Touches `Sources/Common/cmdArgs/impl/FullscreenCmdArgs.swift`, `Sources/AppBundle/command/impl/FullscreenCommand.swift`,
  `Sources/AppBundle/tree/Window.swift` (`fullscreenWidth`), `Sources/AppBundle/layout/layoutRecursive.swift` (`layoutFullscreen`).
- **Even gaps, and fullscreen lines up with tiling** — upstream's `height - 1` workaround now only applies to windows
  that reach the bottom of the visible area (no bottom outer gap, or `fullscreen --no-outer-gaps`). Tiled windows get
  the same gap on all four edges instead of 1px more at the bottom, and fullscreen uses the same height as tiling, so
  it no longer moves the bottom edge by 1px (`layoutHeight` in `Sources/AppBundle/layout/layoutRecursive.swift`).
  Plain `fullscreen` (no `--width`/`--no-outer-gaps`) does nothing for the only tiling window of a workspace, which
  already takes up the whole workspace, and such fullscreen ends as soon as the window is left alone (other windows
  closed, minimized or hidden, or it moved to an empty workspace), so the next `fullscreen --width` doesn't just turn
  it off and the tray doesn't mark the workspace as fullscreen
  (`isPointlessFullscreen`/`exitPointlessFullscreen` in `Sources/AppBundle/command/impl/FullscreenCommand.swift`,
  called from `refreshModel_nonCancellable` in `Sources/AppBundle/layout/refresh.swift`, and again in
  `runHeavyCompleteRefreshSession` after `normalizeLayoutReason`: a refresh collects closed windows and moves minimized
  and hidden ones out of the tiling tree only after its model refresh, so `normalizeLayoutReason` now runs before the
  tray update; `docs/aerospace-fullscreen.adoc`). Tests: `FullscreenCommandTest`.
- **Cmd+Q never switches workspaces** — when the focused window or its app goes away, macOS activates the previous app
  on its own; AeroSpace now stays on the workspace instead of following it (`isMacosFallback` in
  `Sources/AppBundle/focusCache.swift`). Relies on window discovery: after each refresh, apps that show windows
  AeroSpace doesn't manage yet (e.g. a game that was still loading) are rescanned (`Sources/AppBundle/unmanagedWindows.swift`).
  Also touches `Sources/AppBundle/tree/Window.swift`, `Sources/AppBundle/tree/MacWindow.swift`,
  `Sources/AppBundle/windowServer.swift`, `Sources/AppBundle/layout/refresh.swift`.
  Tests: `MacosFallbackFocusTest`, `UnmanagedWindowRescansTest`.
- **Apps that quit without a termination notification** — macOS never posts `didTerminateApplicationNotification`
  for some apps (e.g. Clock), so their dead windows stayed in the tree until some unrelated refresh: tiled windows
  kept their space, and a fullscreen window left alone stayed fullscreen. Such apps still leave
  `NSWorkspace.runningApplications`, so AeroSpace observes it (KVO) and refreshes the apps that left it
  (`Sources/AppBundle/GlobalObserver.swift`). No unit test, it's macOS behavior: checked live by quitting Clock.
- **Closing a window doesn't change the most recent window** — when a closed window leaves a container with one child,
  upstream's flatten binds that child in the container's place, and binding makes a node the most recent all the way
  up to the workspace. So closing a window could take "most recent" from the focused window in another branch, and a
  fullscreen window there left fullscreen. Dwindle workspaces flatten on nearly every close. The flatten now uses
  `TreeNode.replace(with:)`, which puts the child at the container's index, weight, and place in the MRU order
  (`Sources/AppBundle/tree/normalizeContainers.swift`, `Sources/AppBundle/tree/TreeNode.swift`,
  `Sources/AppBundle/util/MruStack.swift`). Tests: `TreeNodeTest.testNormalizeContainers_flattenKeepsTheMostRecentWindows`,
  `DwindleTest.testClosingAWindowDoesntEndFullscreenOfAnotherOne`.
- **Workspace switches don't flash the wallpaper** — apps move their windows at their own pace (Zen lands a frame
  after it accepts a move, games much later), so hiding the previous workspace waits until WindowServer shows the
  windows being revealed, for at most 250 ms (`PendingReveals` in `Sources/AppBundle/layout/PendingReveals.swift`).
  Also touches `Sources/AppBundle/tree/MacWindow.swift` (`hideInCorner`, `unhideFromCorner`) and
  `Sources/AppBundle/tree/MacApp.swift` (`setAxFrame(afterReveals:)`). Tests: `PendingRevealsTest`.
- **Hyprland-style dwindle layout** — with `[dwindle] enabled = true`, every new tiling window splits the most recent
  one in two, like Hyprland's dwindle layout (reference: Hyprland's `DwindleAlgorithm.cpp`). It's built on the regular
  tree: in a dwindle workspace every `tiles` container is a binary split, containers with one child are always
  flattened, weights keep their proportions, and anything with more than two children is folded into a spiral. The
  tree is normalized right before every layout, and placement normalizes first too, because a refresh changes the tree
  after its own normalization. `move`, `focus` and `swap` with a direction use geometry like Hyprland; the
  `aerospace dwindle` command takes Hyprland's layout messages; `split` refuses to run. Code:
  `Sources/AppBundle/tree/dwindle/` (placement, normalization, move, focus), `Sources/AppBundle/config/parseDwindle.swift`,
  `Sources/AppBundle/command/impl/DwindleCommand.swift`, `Sources/Common/cmdArgs/impl/DwindleCmdArgs.swift`.
  Hooks: `MacWindow.swift` (placement; `getOrRegister` checks for a duplicate registration before placing),
  `normalizeContainers.swift`, `layoutRecursive.swift` (`layoutWorkspace`, `layoutTiles`; `layoutHeight` is no longer
  fileprivate), `TilingContainer.swift`, `TreeNode.swift` (`swapChildren`), `WorkspaceEx.swift`, `focus.swift`
  (`stampFocusOrder`), `MoveCommand.swift`, `FocusCommand.swift`, `SwapCommand.swift`, `SplitCommand.swift`,
  `MoveNodeToWorkspaceCommand.swift`, and `OrderedJson.swift` + `parseConfig.swift` (decimal numbers in the config).
  Docs: the "Dwindle layout" section of `docs/guide.adoc`, `docs/aerospace-dwindle.adoc`.
  Tests: `DwindleTest`, `DwindleCommandTest`, `DwindleMoveFocusTest`, `ConfigTest.testParseDwindle`.
- **`rebuild-and-install.sh`** — the build/install helper described below.

## Rebuild, install, and restart — one command

```bash
./rebuild-and-install.sh          # build + install + restart
./rebuild-and-install.sh --check  # validate environment only, no build
```

(Also runnable as `aerospace-rebuild` — `~/.local/bin/aerospace-rebuild` is a symlink to this script.)

It does, in order:
1. **Picks the right Ruby** — prepends keg-only `ruby@3.4` to `PATH` (see Ruby note below), so no manual `PATH=` prefix is needed.
2. **Builds** the release via `./build-release.sh` (man pages + site, shell completion, universal arm64+x86_64 binary, Xcode app, codesign, validation, zip/brew packaging).
3. **Quits** the running AeroSpace.
4. **Installs** `.release/AeroSpace.app` → `/Applications/AeroSpace.app` and `.release/aerospace` → `~/.local/bin/aerospace`
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
