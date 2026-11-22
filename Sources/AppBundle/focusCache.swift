import AppKit
import Common

@MainActor private var lastKnownNativeFocusedWindowId: UInt32? = nil

@MainActor
func cachedNativeFocusedWindow(
    frontmostPid: Int32?,
    windows: [WindowServerWindowInfo],
    nativeVisibility: NativeVisibilityGate? = nil,
    appWindowCount: Int? = nil,
) -> Window? {
    guard let window = focus.windowOrNil,
          window.app.pid == frontmostPid,
          window.visualWorkspace?.isVisible == true,
          !window.isHiddenInCorner,
          let frontWindow = windows.first(where: { $0.pid == frontmostPid }),
          frontWindow.windowId == window.windowId,
          frontWindow.layer == 0
    else { return nil }
    // Native activation can finish before a background AX inventory query. For
    // a single-window app, observed visibility and the exact frontmost window
    // confirm focus without waiting behind that query on the next shortcut.
    guard window.windowId == lastKnownNativeFocusedWindowId ||
        (appWindowCount == 1 && nativeVisibility?.isReady == true)
    else { return nil }
    // A new window, a popup, or a changed native focus takes the existing AX path instead.
    return window
}

/// The window that macOS focused the last time native focus was synced
@MainActor var lastKnownNativeFocusedWindow: Window? { lastKnownNativeFocusedWindowId.flatMap { Window.get(byId: $0) } }

/// The frontmost app is the one that native focus was synced with last, and it shows no window. So macOS focus is
/// still where that sync left it: in a window of a hidden workspace, or nowhere. There's nothing to learn from asking
/// the app, and it may take long to answer. A game answers AX between frames, and with its window off screen a frame
/// waits a second for a drawable. A switch to the workspace of that window would wait for the answer before it shows
/// the window, which is what lets the game answer
@MainActor
func isNativeFocusOffScreen(frontmostPid: Int32?, windows: [WindowServerWindowInfo]) -> Bool {
    guard let frontmostPid, frontmostPid == lastSyncedFrontmostPid else { return false }
    return !windows.contains { $0.pid == frontmostPid }
}

/// The data should flow (from nativeFocused to focused) and
///                      (from nativeFocused to lastKnownNativeFocusedWindowId)
/// Alternative names: takeFocusFromMacOs, syncFocusFromMacOs
@MainActor func updateFocusCache(_ nativeFocused: Window?) {
    guard NativeWorkspaceVisibility.shared.shouldFollowNativeFocus(nativeFocused) else { return }
    if nativeFocused?.parent is MacosPopupWindowsContainer {
        return
    }
    if nativeFocused?.windowId != lastKnownNativeFocusedWindowId {
        if let nativeFocused {
            if nativeFocused.visualWorkspace?.isVisible == false && isMacosFallback(to: nativeFocused) {
                stayOnFocusedWorkspace()
            } else {
                _ = nativeFocused.focusWindow()
            }
            focusedWindowDeathDate = nil // macOS has reacted to the death
        }
        lastKnownNativeFocusedWindowId = nativeFocused?.windowId
    }
    lastSyncedFrontmostPid = frontmostPid
    (nativeFocused?.app as? MacApp)?.lastNativeFocusedWindowId = nativeFocused?.windowId
}

/// When the focused window or its app dies (e.g. cmd-q), macOS activates some other app on its own.
/// Following that app to an invisible workspace would be a workspace switch that nobody asked for
@MainActor var focusedWindowDeathDate: Date? = nil

/// Must be called before the dying window leaves the tree
@MainActor func onWindowDied(_ window: Window) {
    if focus.windowOrNil == window { focusedWindowDeathDate = .now }
}

/// The app that was frontmost the last time native focus was synced
@MainActor private var lastSyncedFrontmostPid: pid_t? = nil
@MainActor var frontmostPidForTests: pid_t? = nil
@MainActor var terminatedPidsForTests: Set<pid_t> = []

@MainActor private var frontmostPid: pid_t? {
    isUnitTest ? frontmostPidForTests : NSWorkspace.shared.frontmostApplication?.processIdentifier
}

@MainActor private func isTerminated(_ pid: pid_t) -> Bool {
    isUnitTest ? terminatedPidsForTests.contains(pid) : NSRunningApplication(processIdentifier: pid)?.isTerminated ?? true
}

@MainActor private func isMacosFallback(to nativeFocused: Window) -> Bool {
    // AX may give up on a quitting app before macOS activates the next one, so the dead window may already be gone
    if let date = focusedWindowDeathDate, date.distance(to: .now) < 1 { return true }
    // Or only WindowServer knows about the death yet. Then the dead window is garbage collected here
    if let focused = focus.windowOrNil, focused != nativeFocused, focused.isDestroyed {
        focused.garbageCollect(skipClosedWindowsCache: false)
        return true
    }
    // Or AeroSpace never knew the quitting app's windows (e.g. a game that refused AX while it was loading)
    if let pid = lastSyncedFrontmostPid, pid != nativeFocused.app.pid, isTerminated(pid) { return true }
    return false
}

@MainActor private func stayOnFocusedWorkspace() {
    _ = focus.workspace.focusWorkspace()
    // Otherwise, macOS keeps the keyboard focus in a hidden window of the app it activated
    focus.windowOrNil?.nativeFocus()
}
