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
        _ = nativeFocused?.focusWindow()
        lastKnownNativeFocusedWindowId = nativeFocused?.windowId
    }
    (nativeFocused?.app as? MacApp)?.lastNativeFocusedWindowId = nativeFocused?.windowId
}
