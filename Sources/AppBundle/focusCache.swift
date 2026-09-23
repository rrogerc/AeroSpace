import AppKit

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

/// The data should flow (from nativeFocused to focused) and
///                      (from nativeFocused to lastKnownNativeFocusedWindowId)
/// Alternative names: takeFocusFromMacOs, syncFocusFromMacOs
@MainActor func updateFocusCache(_ nativeFocused: Window?) {
    if nativeFocused?.parent is MacosPopupWindowsContainer {
        return
    }
    if nativeFocused?.windowId != lastKnownNativeFocusedWindowId {
        if let nativeFocused {
            if nativeFocused.visualWorkspace?.isVisible == false && focusedWindowDied(beforeMacosFocused: nativeFocused) {
                stayOnFocusedWorkspace()
            } else {
                _ = nativeFocused.focusWindow()
            }
            focusedWindowDeathDate = nil // macOS has reacted to the death
        }
        lastKnownNativeFocusedWindowId = nativeFocused?.windowId
    }
    (nativeFocused?.app as? MacApp)?.lastNativeFocusedWindowId = nativeFocused?.windowId
}

/// When the focused window dies (e.g. its app quits), macOS activates some other app on its own.
/// Following that app to an invisible workspace would be a workspace switch that nobody asked for
@MainActor var focusedWindowDeathDate: Date? = nil

/// Must be called before the dying window leaves the tree
@MainActor func onWindowDied(_ window: Window) {
    if focus.windowOrNil == window { focusedWindowDeathDate = .now }
}

/// AX may give up on a quitting app before macOS activates the next one, so the dead window may already be gone.
/// Or only WindowServer knows about the death yet. Then the dead window is garbage collected here
@MainActor private func focusedWindowDied(beforeMacosFocused nativeFocused: Window) -> Bool {
    if let date = focusedWindowDeathDate, date.distance(to: .now) < 1 { return true }
    guard let focused = focus.windowOrNil, focused != nativeFocused,
          focused.isDestroyed // The last check, because it's a WindowServer request
    else { return false }
    focused.garbageCollect(skipClosedWindowsCache: false)
    return true
}

@MainActor private func stayOnFocusedWorkspace() {
    _ = focus.workspace.focusWorkspace()
    // Otherwise, macOS keeps the keyboard focus in a hidden window of the app it activated
    focus.windowOrNil?.nativeFocus()
}
