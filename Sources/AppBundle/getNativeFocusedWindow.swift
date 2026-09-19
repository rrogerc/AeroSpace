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
func getNativeFocusedWindow(_ cm: CancellationMode, preferCached: Bool = false) async throws -> Window? {
    if preferCached && !isUnitTest,
       let windows = getOnScreenWindowServerWindows(),
       let cached = cachedNativeFocusedWindow(
           frontmostPid: NSWorkspace.shared.frontmostApplication?.processIdentifier,
           windows: windows,
           nativeVisibility: focus.windowOrNil.flatMap { NativeVisibilityGates.shared.get($0.windowId, pid: $0.app.pid) },
           appWindowCount: (focus.windowOrNil?.app as? MacApp)?.windowsCount,
       )
    {
        return cached
    }
    return try await focusedApp?.getFocusedWindow(cm)
}
