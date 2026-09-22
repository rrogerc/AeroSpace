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
        if let nativeFocused, let destroyed = destroyedFocusedWindow(beforeMacosFallbackTo: nativeFocused) {
            stayOnFocusedWorkspace(droppingDestroyed: destroyed)
        } else {
            _ = nativeFocused?.focusWindow()
        }
        lastKnownNativeFocusedWindowId = nativeFocused?.windowId
    }
    (nativeFocused?.app as? MacApp)?.lastNativeFocusedWindowId = nativeFocused?.windowId
}

/// When the focused window is destroyed (e.g. its app quits), macOS activates some other app on its own.
/// Following that app to an invisible workspace would be a workspace switch that nobody asked for
@MainActor private func destroyedFocusedWindow(beforeMacosFallbackTo nativeFocused: Window) -> Window? {
    guard let focused = focus.windowOrNil, focused != nativeFocused,
          nativeFocused.visualWorkspace?.isVisible == false,
          focused.isDestroyed // The last check, because it's a WindowServer request
    else { return nil }
    return focused
}

@MainActor private func stayOnFocusedWorkspace(droppingDestroyed destroyed: Window) {
    let workspace = focus.workspace
    destroyed.garbageCollect(skipClosedWindowsCache: false)
    _ = workspace.focusWorkspace()
    // Otherwise, macOS keeps the keyboard focus in a hidden window of the app it activated
    focus.windowOrNil?.nativeFocus()
}
