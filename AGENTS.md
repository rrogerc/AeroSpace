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
- **`script/rebuild-and-install.sh`** — the build/install helper described below.
- **Hidden native window parking** — `enable-native-window-hiding = true` parks inactive windows in a never-shown,
  connection-owned WindowServer group, with SIP enabled and no extra normal macOS desktop. Revealed windows return
  exclusively to the original desktop before public focus/AX frame operations. Currently supports one monitor;
  missing private APIs fall back to corner hiding. Adding an ordinary desktop does not recreate the group, and
  leaving the original desktop suspends AeroSpace window work until the user returns. The main state machine is
  `Sources/AppBundle/HiddenWindowParking.swift`, integrated through `NativeWorkspaceVisibility.swift`,
  `focusCache.swift`, `getNativeFocusedWindow.swift`, `MacApp.swift`, and `layout/refresh.swift`. The private return
  operation and cleanup are in `Sources/PrivateApi/WorkspaceGroups.m`. Tests: `HiddenWindowParkingTest`,
  `NativeWorkspaceVisibilityTest`, `NativeDesktopWindowTest`, and `ConfigTest.testNativeWindowHidingIsOptIn`.
  Interrupted background refreshes finish their started membership transition and cancel stale frame/focus gates,
  keeping unrelated workspaces parked; treating cancellation as recovery briefly revealed all hidden windows.
  An unchanged, previously published gate stays valid after membership/home verification so cancellation of a no-op
  refresh cannot discard a destination activation still queued against that gate.
  Reveals also wait for WindowServer's on-screen list before parking outgoing windows (bounded at 250 ms): native
  membership alone was acknowledged before incoming windows became visible, intermittently exposing the wallpaper.
  The recorded shortcut replay went from eight wallpaper flashes in 120 switches to zero with this barrier.
  Foreign-desktop windows keep their original workspace/kind without taking a tile (`normalizeLayoutReason.swift`,
  `MacosForeignDesktopWindowsContainer`); focus, corner fallback, and shutdown leave them under macOS control.
  The earlier environment-variable
  native-Space/group experiments remain available separately; this config option takes precedence over them.
  Investigation and live-test evidence: `docs/dev/native-window-hiding.md`.
- **Commands don't wait for a frontmost app that shows no window**: before a command runs, AeroSpace asks the frontmost
  app for its focused window. After a switch to an empty workspace that's still the app of the previous workspace, with
  its window hidden. A game there (Slay the Spire 2, Godot) answers AX only between frames, and with its window off
  screen a frame blocks in `-[CAMetalLayer nextDrawable]` until its 1 s timeout, or until the window is shown again.
  So the switch back waited for the answer of the window that it was about to show: 600 to 680 ms, now about 10 ms,
  and the game answers 6 to 36 ms after its window is back. When the frontmost app is the one that native focus was
  synced with last and WindowServer shows no window of it, a command takes the window of that sync instead of asking
  (`isNativeFocusOffScreen` in `Sources/AppBundle/focusCache.swift`, `getNativeFocusedWindowBeforeCommand` in
  `Sources/AppBundle/getNativeFocusedWindow.swift`, called from `runLightSession`). Refreshes still ask the app. A
  window hidden in a corner still counts as on screen for WindowServer, so its app is asked as before.
  Tests: `WorkspaceSwitchPerformanceTest.testCommandDoesNotAskFrontmostAppThatShowsNoWindow`,
  `testCommandAsksFrontmostAppThatShowsWindowOrWasNotSynced`.
- **Scoped refreshes ask LaunchServices only about their own apps**: `NSRunningApplication` makes a synchronous round
  trip to LaunchServices for every property, even for the pid. A refresh read `activationPolicy` of every running app
  on the main thread (about 30 ms for 160 apps), where the workspace hotkey tap runs too. A refresh scoped to some
  apps now looks up only those (`refreshAllAndGetAliveWindowIds` in `Sources/AppBundle/tree/MacApp.swift`). Checking
  the scope before the policy isn't enough: the pid costs the same round trip. Refreshes of all apps (after a mouse
  click, or a command that isn't a workspace switch) still go through every running app. No unit test, it's
  LaunchServices behavior: checked with `sample` on the installed app.
- **Frame changes (e.g. `fullscreen`) don't wait for a slow app**: a game answers an AX request only every frame or
  two. Godot (Slay the Spire 2) runs a frame from a run loop observer and then wakes the run loop, so every pass of the
  loop takes one request at most: 27 ms a request while the game is played (the median of 4900 requests), and 67 ms
  for one in ten. `fullscreen` on the game sent six requests one after the other: the focused window and its ID,
  `AXEnhancedUserInterface`, then size, position, size. Four changes, all in the path of every command and every
  layout:
  - Before a command, the focused window comes from WindowServer whenever it shows the window that AeroSpace has
    focused as the front window of the frontmost app (`cachedNativeFocusedWindow`). That was only so for workspace
    switches. WindowServer answers in about 1.5 ms, as fast as the quickest apps
    (`getNativeFocusedWindowBeforeCommand` in `Sources/AppBundle/getNativeFocusedWindow.swift`). The parameter of
    `runLightSession` that used to turn it on only scopes the refresh now, and is called `isWorkspaceSwitch`.
  - `AXEnhancedUserInterface` is read after the frames of a batch if the app's last answer was false, not before them
    (`Sources/AppBundle/EnhancedUserInterface.swift`). If another client has enabled it meanwhile, that one batch may
    animate, and the layout of the next refresh writes the frames again with the attribute disabled. Two exceptions
    are asked first: an app that had the attribute enabled once (Zen enables it by itself, see "New windows show up
    in their tile"), and the frame of a new window behind the curtain.
  - Frames are written on whole points (`WindowFrameUpdate.onWholePoints` in `Sources/AppBundle/windowServer.swift`,
    applied in `MacApp.setAxFrame`). On a monitor 2048 points wide, two tiles are 1004.5 points wide each. AppKit
    rounds such a frame its own way (even the same width up or down, depending on the frame before it), so the window
    never matched the requested frame, and every layout (after every command, and every mouse click) wrote it again:
    four requests for a window that was already in place. Edges are rounded, not sizes, so the gaps stay even.
  - A window that can't have its size where it is moves first (`WindowFrameUpdate.movesFirst`). AppKit clamps an AX
    resize at the right and bottom edges of the screen, so the right one of two tiles only grew as far as the screen
    edge (1018 points wide instead of 2022), moved, and then got its size: three steps on screen and two resizes.
    Now it's position, then size. Only if the window stays within one monitor on the way: a window that spans
    monitors is the case of upstream's issue 143, and gets size, position, size as before.

  Measured on the game in the right one of two tiles, with six toggles of `fullscreen` before and after (medians):
  the first write is sent 14 ms after the command instead of 100 ms, and WindowServer shows the final frame after
  62 ms instead of 176 ms. Not counting what the refreshes ask, the six toggles took 21 requests to the game instead
  of 48.
  The sequence can't get shorter than that. On a test window (an accessory app, which AeroSpace doesn't manage, with
  a Godot-like run loop): `AXFrame` isn't settable, WindowServer shows a frame only after the app has answered (so a
  write can't be checked and the next one skipped), and two requests sent at once are still answered a frame or two
  apart. So a window that changes both position and size (the right or the bottom tile) still changes in two steps,
  and the left or the top tile in one. A window that refuses its frame for its own reasons (Steam is at least 1010
  points wide) is still written by every layout.
  Tests: `WindowFrameUpdateTest`, `EnhancedUserInterfaceTest`,
  `WorkspaceSwitchPerformanceTest.testCommandCanReuseConfirmedNativeFocus`.

- **Workspace switches don't blink the window shadow**: macOS draws the window that has the keyboard with a darker
  shadow than the other windows, and it's the app of a window that tells WindowServer which of the two to draw. A
  switch can focus a window only after it's on screen, and an app takes a few frames to react (Zen and Ghostty: four
  or five after another app, one or two between two Ghostty windows). So the window of the next workspace arrived
  with the light shadow, and with gaps the shadow around it blinked on every switch: dark, light, dark. Now the
  window that a switch is about to focus gets its active look while it's still hidden, right before
  `HiddenWindowParkingWorker` reveals it (`ActiveLook` in `Sources/AppBundle/ActiveLook.swift`, `showAsActive` in
  `Sources/AppBundle/HiddenWindowParking.swift`). How depends on its app:
  - Another app is frontmost: the app of the window is sent the events that macOS sends on activation (an
    AppKit-defined "application activated" event, then the key-window events of `AeroSpaceMakeKeyWindow`), without
    being activated (`AeroSpaceSetAppLooksActive` in `Sources/PrivateApi/include/private.m`). It draws the window as
    its key window. The app that is really frontmost isn't told anything, and keeps the keyboard until the switch
    focuses the window as before. If macOS doesn't activate the app after all (a newer command took the focus
    elsewhere), it's told that it's inactive again: on the next focus of another app, or after a second
    (`ActiveLookingApp`).
  - Its app is frontmost already (two Ghostty windows): the window becomes the main window of the app through AX
    before it's shown, which waits for the answer for at most 50 ms. AppKit goes on drawing the window that is on
    screen as active until the new one shows up. The app isn't asked if the window is its main window already (its
    only window, or the one that had the keyboard last), so a game isn't asked about a window that's off screen.

  Only with `enable-native-window-hiding`. Also touches `Sources/AppBundle/NativeWorkspaceVisibility.swift`
  (`revealedFocus`), `Sources/AppBundle/layout/refresh.swift` (`runLightSession`),
  `Sources/AppBundle/tree/MacApp.swift` (`activeLook`), and `Sources/AppBundle/focusCache.swift`.
  Measured on the gaps around the window, with ScreenCaptureKit at 60 Hz: before, 12 of 14 switches between Ghostty,
  Zen and Spotify had light frames (four or five into Zen or Ghostty from another app). After, none of 39. The
  price: the window of the same app shows up 3 to 5 ms later (Ghostty's answer), any other one under 1 ms later.
  That left the frame in which both windows were on screen, with their shadows on top of each other: the next entry.
  Details: "Shadow blink on workspace switches" in `docs/dev/native-window-hiding.md`.
  Tests: `ActiveLookTest`, and `HiddenWindowParkingTest.testWindowThatGetsTheFocusLooksActiveBeforeItIsRevealed` with
  the four tests after it.

- **Workspace switches show the next windows and hide the previous ones in the same frame**: a switch revealed the
  windows of the next workspace, and hid the windows of the previous one once the next ones were on screen. A frame
  in between had both, and their shadows add up: with gaps, the shadow went dark for a frame in about half of the
  switches. The two steps can't be one: only WindowManager moves a window of another app between the desktop and a
  group, one request at a time, and a window that joins the desktop is on screen 1 to 5 ms after the request, at a
  moment that WindowManager picks. What does change in a transaction of our own is the alpha of a group that we
  own, and while a group is shown, its alpha applies to all its windows, also to a window that is on the desktop as
  well. So next to the hidden group there are two shown groups, both empty between switches (`WindowSwapGroups`
  in `Sources/AppBundle/HiddenWindowParking.swift`): `arriving` with alpha 0, and `leaving` with alpha 1. A switch
  with windows on both sides (`swap`):
  1. Stage: the next windows move from the hidden group to `arriving`, and join the desktop there, unseen. The
     previous windows join `leaving`, and stay on the desktop as they are (`AeroSpaceStageWindowSwap` in
     `Sources/PrivateApi/WorkspaceGroups.m`).
  2. Swap, once WindowServer lists the next windows as on screen: one transaction gives `arriving` alpha 1 and
     `leaving` alpha 0 (`AeroSpaceCommitWindowSwap`).
  3. Settle: the previous windows leave the desktop for the hidden group, the next ones leave `arriving`, and the
     alphas go back (`AeroSpaceSettleWindowSwap`). Nothing of it shows, and afterwards every window is where it was
     before this change: on the desktop only, or in the hidden group only. It's over before the worker answers,
     so before the next window is focused: as long as the window that had the keyboard is on the desktop, seen or
     not, macOS draws the window that gets the keyboard as inactive for a frame or more.

  The request for the main window of an app with two windows (previous entry) is sent before the staging and
  awaited after it, so the windows are staged while the app answers. A switch to or from an empty workspace reveals
  or hides as before, and so does every switch if a private API is missing. If a step fails, the windows go back to
  the desktop, like after any other failure of the hidden group. Also touches
  `Sources/AppBundle/NativeWorkspaceVisibility.swift` (a window in a group of a swap is one of ours:
  `shouldRegisterNativeWindow`, `isWindowOnForeignNativeDesktop`).
  Measured the same way, on the same windows: right before, 12 of 26 switches had a frame with both shadows.
  After, none of 39, and none had a light frame. The price: the next windows show up when the previous ones go,
  19 ms into a switch. They used to show up after about 13 ms, and the previous ones went after about 21. The
  focus is requested 28.5 ms into a switch (27.6 before), and 41 ms at the 90th percentile (53 before: the
  transaction replaced a request to WindowManager and a poll every 4 ms).
  What's left: the first switch to an app that has just started can still arrive with the light shadow (its first
  event takes long), and a command that cancels a running switch ends the wait for the next windows early, as it
  did before. Everything that was tried is in "Both workspaces in one frame" in `docs/dev/native-window-hiding.md`.
  Tests: `HiddenWindowParkingTest.testWindowsOfTwoWorkspacesChangePlacesInOneTransaction` with the nine tests after
  it.

- **New windows show up in their tile**: an app shows a new window where it likes, and AeroSpace moved it to its tile
  when it found out. With Ghostty that took 100 ms: six frames in which the new window covered the whole workspace.
  Nobody can move a window before its app shows it. But WindowServer knows a window tens of milliseconds before it's
  on screen, and a window in a shown group with alpha 0 isn't drawn (the previous entry). So a new window waits
  behind a curtain, a third shown group with alpha 0, until it has its frame (`NewWindowCurtain` in
  `Sources/AppBundle/NewWindowCurtain.swift`):
  1. Birth: AppKit sets the level of a window the moment it creates it, and WindowServer sends the level of every
     window to a connection that asked for the notifications of at least one window (any ID will do).
     AeroSpace asks for them at startup (`AeroSpaceObserveWindowEvents` in `Sources/PrivateApi/WindowEvents.m`), and
     a window that isn't ordered in, has no space, no level and no parent, and belongs to a regular app joins the
     curtain (`AeroSpaceCurtainWindow` in `Sources/PrivateApi/WorkspaceGroups.m`). Its app shows it there, unseen:
     30 to 60 ms after the birth with Ghostty, 7 to 40 with Zen, 14 at the least with a plain AppKit app.
  2. Frame: AeroSpace finds the window through AX as before, and asks its app for the frame of its tile. The new
     windows of a layout are asked first (`LayoutContext.newWindows` in `Sources/AppBundle/layout/layoutRecursive.swift`).
     The frames of the other windows wait on the AX threads of their apps until the new ones are on screen
     (`newWindowsToShowFirst`, `NewWindowCurtain.wait`): a window that shrinks before the new one is there shows the
     wallpaper in between.
  3. Show: when WindowServer has the frame (within 1.5 % of it: macOS scales a window while it opens), the window
     leaves the curtain (`AeroSpaceUncurtainWindow`). It shows up in its tile, on top of the windows that make room
     for it, and they follow.

  At birth every window looks the same to WindowServer, also a menu, a sheet, a popover, and a window that AeroSpace
  never manages. So nothing stays behind the curtain for long. A window with a parent or a level leaves when its app
  shows it (WindowServer has both by then). A window that AeroSpace manages and doesn't tile (a dialog, a popup)
  leaves at the next layout (`showNewWindowsWithoutTile` in `Sources/AppBundle/layout/refresh.swift`). A new window
  of a hidden workspace goes straight to the hidden group (`park` in `HiddenWindowParkingWorker.apply`). Every step
  has a deadline (`NewWindowCurtainTiming`), and whatever happens, a window that its app has shown is unseen for
  450 ms at most. The curtain only asks WindowServer, never the app. If WindowManager doesn't take a window out,
  the whole group goes, and WindowServer does.

  To get the frame out early, the refresh that finds a new window doesn't wait 30 ms for more events, isn't started
  over by the AX notifications that follow (they're refreshed after it), and lays out as soon as the window is in
  the tree, before it asks the app its other questions (`isAboutToPlaceNewWindow` and `placesNewWindow` in
  `refresh.swift`). The tray gets its text after the layout.

  That early, AeroSpace finds the window before its app has shown it, in every third new Ghostty window: the app
  answers AX as soon as the window is its key window, 10 to 15 ms before WindowServer has it on screen. Until then the
  window has no size, and CGWindowList has no record to go by for it. `HiddenWindowParkingWorker` takes the owner of
  a window from that list, so it didn't know whose the window was, and cancelled the job of its frame. Nobody asked
  the app, the windows that make room waited for the new one on the AX thread that the next layout needed, and
  100 ms later the window showed up where its app put it: of 11 windows opened with Cmd+N, 3 flashed like before.
  (None of the windows of the first measurements did. They were opened through AppleScript, and filmed by a probe
  that keeps WindowServer busy: AeroSpace asked for the frame 55 to 87 ms after the birth of a window then, and it
  asks after 22 to 60 ms when a key is pressed and nothing else runs.) Four things keep a frame from getting lost
  now:
  - The curtain says whose its windows are (`findOwners` in `HiddenWindowParking.swift`, `NewWindowCurtain.owners`).
    The window is asked for its frame at once, and its app shows it with that frame, or takes it right after.
  - The job of a frame tells the curtain when it gets as far as asking the app (`NewWindowCurtain.asking`, called
    from `MacApp.setAxFrame`). A job that ends without it leaves no frame behind: the next layout asks right away,
    and if nothing else starts one, the curtain does (`lookAt`: a refresh of the app).
  - The other windows don't wait for a new window that has no frame coming (`NewWindowCurtain.wait` returns false).
    They keep their frames, and make room with the layout that places the new window, or with the one after it
    has left the curtain as it is.
  - WindowServer has the frame of a window only once its app has shown it, so that's when the curtain starts to
    judge it. If the app has answered and shown the window, and WindowServer has another frame 50 ms later, the app
    is asked once more: an app that sets a frame of its own while it shows a window takes the second one. If it
    has another frame 50 ms after that as well, the window shows up as it is (it can't be that small).

  And the frame of a new window is never animated. With `AXEnhancedUserInterface` enabled, AppKit animates a frame
  that comes through AX, for a quarter of a second, and Zen enables the attribute by itself: whenever it creates a
  window, and again half a second after somebody has disabled it (it also answers "not implemented" to the request
  that disables it, and does it). AeroSpace asked for the attribute after the frames if the last answer was false,
  and the layout that follows a new window by 100 ms got that answer every time. So the first frames of the next
  new Zen window were animated, unless a window was closed in between: the third of three windows opened in a row
  left the curtain halfway between where Zen put it and its tile. Now an app that had the attribute enabled once is
  asked before every batch, and so is every app before the frame of a window behind the curtain
  (`EnhancedUserInterface.acquireForBatch(askFirst:)`, `wasEverEnabled`).

  Only with `enable-native-window-hiding`, and not for a window that is created while a mouse button is down (a tab
  that is dragged out follows the pointer). `AEROSPACE_NEW_WINDOW_CURTAIN=0` in the environment of AeroSpace turns it
  off. Also touches `Sources/AppBundle/NativeWorkspaceVisibility.swift` (the curtain exists while windows are
  hidden natively; a window behind it is one of ours), `Sources/AppBundle/HiddenWindowParking.swift` (a window
  behind the curtain gets its frame like a window on the desktop), `Sources/AppBundle/tree/MacApp.swift`
  (`setAxFrame`), `Sources/AppBundle/tree/MacWindow.swift` and `Sources/AppBundle/initAppBundle.swift`.

  Measured with ScreenCaptureKit at 60 Hz, on new Ghostty windows next to another one, in ms after WindowServer
  knew the window. Before (6 windows): the new window covered the workspace for 100 to 117 ms every time, was in its
  tile after 165 ms (the median), and the layout was settled after 267. After (20 windows): never outside its tile,
  in its tile after 138 ms, settled after 195. So nothing shows up later than it did: only the frames in between
  are gone. New Zen windows and the windows of a plain AppKit app show up in their tile as well. A dialog leaves
  the curtain 7 to 13 ms after its app shows it, and sheets, popovers and menus before that or within 4 ms.
  With real key presses (`keys.py` in `.local/new-window-flash/`: Cmd+N through the event tap of the keyboard, only
  while nobody uses the machine, and with nothing else running): before the four changes, 5 of 10 windows left the
  curtain without their frame. After them, 182 of 182 were in their tile when they left it, 45 to 116 ms after their
  birth, and 16 of those were asked before their app had shown them. None of the 36 that were filmed was outside of
  its tile in a frame, and WindowServer, asked 500 times a second about 75 more, never had one on the desktop where
  its app had put it (fifteen of them were opened three or four a second, each splitting the one before it). Zen,
  with Cmd+N as well: 13 of 14 windows in their tile when they left the curtain, also three and four in a row, and
  the fourteenth can't be as low as its tile (Zen windows are 495 points high at the least). A test app that gives its window its own frame back after the first request is asked again,
  and its window shows up in its tile. One whose windows can't be as narrow as their tile gets two requests of
  50 ms each (it used to be one of 100 ms), and shows its window as it is 160 ms after its birth.
  What's left: an app that doesn't answer AX within 150 ms of showing its window (it shows up where its app put it,
  as before), an app that gives a window another frame after it has left the curtain, a window that its app creates
  more than 5 s before it shows it, and the apps that show a window within a few milliseconds of creating it (Zen:
  4 to 6 ms after the curtain, and never seen so far).
  Everything that was measured is in "New windows in their tile" in `docs/dev/native-window-hiding.md`.
  Tests: `NewWindowCurtainTest`, `HiddenWindowParkingTest.testNewWindowBehindTheCurtainGetsItsFrameLikeAWindowOnTheDesktop`
  with the four tests after it, and `EnhancedUserInterfaceTest.testAppThatEnablesTheAttributeAgainAndAgainIsAskedBeforeEveryBatch`
  with the test after it.

- **No sponsorship item in the tray menu**: upstream's "Sponsor AeroSpace on GitHub" button and its rotating
  messages are gone (`Sources/AppBundle/ui/MenuBar.swift`, `Sources/AppBundle/ui/TrayMenuModel.swift`, and the
  deleted `Sources/Common/model/sponsorshipPrompts.swift`). If upstream changes the prompts, a rebase conflicts on
  the deleted file: keep it deleted.

- **The repo is laid out for this fork**: upstream's layout serves a project with CI, a website, releases and brew
  casks. Three changes:
  - Deleted, because only upstream's own project needs it: `.github/` (CI, issue and PR templates, funding),
    `CONTRIBUTING.md`, `install-from-sources.sh` (the brew cask install), `script/publish-release.sh`, `makefile`,
    the scripts that run the debug build (`run-cli.sh`, `run-debug.sh`,
    `script/reset-accessibility-permission-for-debug.sh`), and `script/clean-project.sh` with
    `script/clean-xcode.sh` (the first one runs `git clean -ffxd`, which deletes `.local` too).
  - The release build makes only what gets installed: the app and the CLI. The website, the man pages, the shell
    completion, the zip and the brew casks are gone, and with them `build-docs.sh`, `build-shell-completion.sh`,
    `script/build-brew-cask.sh`, `Gemfile`, `.bundle/`, `grammar/`, and the Ruby and Rust that they needed. `docs/`
    stays: `script/generate.sh` makes the help texts of the CLI from `docs/aerospace-*.adoc`. Nothing renders
    `docs/` to HTML or man pages any more, so nothing checks its AsciiDoc syntax either.
  - Moved: every script is in `script/` (`build-release.sh`, `build-debug.sh`, `test.sh`, `swift-test.sh`,
    `lint.sh`, `format.sh`, `generate.sh`, and this fork's `rebuild-and-install.sh`), `axDumps/` is
    `Sources/AppBundleTests/axDumps/` (excluded from the test target in `Package.swift`), `resources/` is
    `xcode/resources/` (only the Xcode build reads it), `dev-docs/` is `docs/dev/`, and `legal/` is `docs/legal/`.

  When taking upstream: git follows the moves, so upstream's changes to a moved file land in the new place. If
  upstream changes a deleted file, it conflicts: keep it deleted. If upstream changes a step that was cut from
  `build-release.sh` (docs, shell completion, pack, brew cask), drop the change. A new command of upstream comes
  with a grammar change: drop that too. Upstream has since split its `build-release.sh` into
  `script/build-release-cli.sh`, `script/build-release-app.sh` and `script/validate-release-binaries.sh`, and added
  `versions.sh` at the root: the first merge conflicts there, and `versions.sh` belongs in `script/`.

## Rebuild, install, and restart — one command

```bash
./script/rebuild-and-install.sh          # build + install + restart
./script/rebuild-and-install.sh --check  # validate environment only, no build
```

(Also runnable as `aerospace-rebuild` — `~/.local/bin/aerospace-rebuild` is a symlink to this script.)

It does, in order:
1. **Builds** the release via `./script/build-release.sh` (universal arm64+x86_64 CLI, Xcode app, codesign, validation).
   It refuses to build with uncommitted changes: the binaries carry the git hash, and the build ends with `git checkout .`.
2. **Quits** the running AeroSpace.
3. **Installs** `.release/AeroSpace.app` → `/Applications/AeroSpace.app` and `.release/aerospace` → `~/.local/bin/aerospace`
   (the install is a manual copy: this fork doesn't use a brew cask).
4. **Relaunches**, waits for the server, and prints the running version.

Install locations are overridable via env vars: `APP_DEST`, `CLI_DEST`.

The script deliberately does **not** rebase (conflicts need a human). The full update flow is:

```bash
git fetch upstream && git rebase upstream/main   # resolve any conflicts (usually FullscreenCmdArgs.swift)
./script/rebuild-and-install.sh
git push --force-with-lease origin main          # update the fork (rebase rewrites history)
```

## Tests

```bash
./script/test.sh        # everything: debug build with warnings as errors, tests, format, lint, unused code
./script/swift-test.sh  # only the tests
```

`test.sh` formats the code in place, and fails at the end if anything is uncommitted.

## Prerequisites (already set up here)

- Swift 6.2.3 (`.swift-version`); `/usr/bin/swift` matches, so `swiftly` is not required.
- Self-signed codesign cert **`aerospace-codesign-certificate`** in Keychain. Rebuilding with the same cert keeps
  macOS Accessibility permission across reinstalls (no re-approval prompt).
- bash 5 or newer on `PATH` (`brew install bash`): `script/setup.sh` refuses the bash 3.2 of macOS.

## Conventions

- Scripts live in `script/` and start with `cd "$(dirname "$0")/.."`, so all of them run from the repo root and
  call each other as `./script/<name>.sh`. `rebuild-and-install.sh` first follows the symlink that it's run
  through (`aerospace-rebuild`). `script/setup.sh` nukes `PATH` to `.deps/bin:/bin:/usr/bin` and wraps
  optional tools resolved via `which` at source time, so a tool has to be on `PATH` *before* a script is invoked.
- See `docs/dev/development.md` for upstream's notes on dependencies, the codesign certificate, and Xcode.
