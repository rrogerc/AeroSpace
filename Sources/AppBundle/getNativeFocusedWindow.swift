import AppKit
import Common

@MainActor
var appForTests: (any AbstractApp)? = nil

@MainActor
private var focusedApp: (any AbstractApp)? {
    get async throws {
        if isUnitTest {
            return appForTests
        } else {
            check(appForTests == nil)
            return switch NSWorkspace.shared.frontmostApplication {
                case let frontmostApplication?: try await MacApp.getOrRegister(frontmostApplication)
                case nil: nil
            }
        }
    }
}

@MainActor
func getNativeFocusedWindow(_ cm: CancellationMode) async throws -> Window? {
    guard NativeWorkspaceVisibility.shared.shouldFollowNativeFocus(nil) else { return nil }
    return try await focusedApp?.getFocusedWindow(cm)
}

/// A command doesn't wait for the frontmost app if WindowServer already shows what the app would answer.
/// Refreshes ask the app anyway
@MainActor
func getNativeFocusedWindowBeforeCommand(_ cm: CancellationMode, preferCached: Bool) async throws -> Window? {
    guard NativeWorkspaceVisibility.shared.shouldFollowNativeFocus(nil) else { return nil }
    if !isUnitTest {
        let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focused = focus.windowOrNil
        // WindowServer queries aren't free, and an app that shows the focused window isn't off screen
        if preferCached || focused?.app.pid != frontmostPid, let windows = getOnScreenWindowServerWindows() {
            if preferCached,
               let cached = cachedNativeFocusedWindow(
                   frontmostPid: frontmostPid,
                   windows: windows,
                   nativeVisibility: focused.flatMap { NativeVisibilityGates.shared.get($0.windowId, pid: $0.app.pid) },
                   appWindowCount: (focused?.app as? MacApp)?.windowsCount,
               )
            {
                return cached
            }
            if isNativeFocusOffScreen(frontmostPid: frontmostPid, windows: windows) { return lastKnownNativeFocusedWindow }
        }
    }
    return try await focusedApp?.getFocusedWindow(cm)
}
