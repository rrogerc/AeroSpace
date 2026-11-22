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
/// Refreshes ask the app anyway.
///
/// The app's answer takes two AX requests (the focused window, then its ID), and a game answers a request only every
/// frame or two (Slay the Spire 2: 27 ms a request, and 67 ms for one in ten). WindowServer answers in about 1.5 ms,
/// which is as fast as the quickest apps, so it's asked first before every command, not only before a workspace switch
@MainActor
func getNativeFocusedWindowBeforeCommand(_ cm: CancellationMode) async throws -> Window? {
    guard NativeWorkspaceVisibility.shared.shouldFollowNativeFocus(nil) else { return nil }
    if !isUnitTest, let windows = getOnScreenWindowServerWindows() {
        let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focused = focus.windowOrNil
        let cached = cachedNativeFocusedWindow(
            frontmostPid: frontmostPid,
            windows: windows,
            nativeVisibility: focused.flatMap { NativeVisibilityGates.shared.get($0.windowId, pid: $0.app.pid) },
            appWindowCount: (focused?.app as? MacApp)?.windowsCount,
        )
        if let cached { return cached }
        if isNativeFocusOffScreen(frontmostPid: frontmostPid, windows: windows) { return lastKnownNativeFocusedWindow }
    }
    return try await focusedApp?.getFocusedWindow(cm)
}
