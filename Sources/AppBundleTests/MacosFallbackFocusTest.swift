@testable import AppBundle
import Common
import XCTest

/// When the focused window is destroyed (e.g. cmd-q), macOS activates some other app on its own
@MainActor
final class MacosFallbackFocusTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        updateFocusCache(nil)
    }

    func testStaysOnWorkspaceWhenMacosFallsBackToAnotherWorkspace() {
        let current = Workspace.get(byName: "current")
        let other = Workspace.get(byName: "other")
        TestWindow.new(id: 1, parent: current.rootTilingContainer)
        let quit = TestWindow.new(id: 2, parent: current.rootTilingContainer)
        let fallback = TestWindow.new(id: 3, parent: other.rootTilingContainer)
        focusNatively(quit)

        quit.isDestroyedForTest = true
        updateFocusCache(fallback)

        assertEquals(focus.workspace, current)
        assertEquals(focus.windowOrNil?.windowId, 1)
        assertTrue(current.isVisible)
        assertFalse(other.isVisible)
        assertFalse(quit.isBound) // Dropped right away instead of waiting for the app to exit
        assertEquals(TestApp.shared.focusedWindow?.windowId, 1) // macOS focus is handed back to this workspace
    }

    func testStaysOnWorkspaceThatBecameEmpty() {
        let current = Workspace.get(byName: "current")
        let quit = TestWindow.new(id: 1, parent: current.rootTilingContainer)
        let fallback = TestWindow.new(id: 2, parent: Workspace.get(byName: "other").rootTilingContainer)
        focusNatively(quit)

        quit.isDestroyedForTest = true
        updateFocusCache(fallback)

        assertEquals(focus.workspace, current)
        assertNil(focus.windowOrNil)
        assertFalse(quit.isBound)
    }

    func testLaterRefreshesDoNotFollowTheFallbackButFollowNewFocus() {
        let current = Workspace.get(byName: "current")
        let quit = TestWindow.new(id: 1, parent: current.rootTilingContainer)
        let fallback = TestWindow.new(id: 2, parent: Workspace.get(byName: "other").rootTilingContainer)
        let third = Workspace.get(byName: "third")
        let cmdTabTarget = TestWindow.new(id: 3, parent: third.rootTilingContainer)
        focusNatively(quit)
        quit.isDestroyedForTest = true
        updateFocusCache(fallback)

        updateFocusCache(fallback) // The next refresh session reports the same native focus
        assertEquals(focus.workspace, current)

        updateFocusCache(cmdTabTarget)
        assertEquals(focus.workspace, third)
        assertEquals(focus.windowOrNil?.windowId, 3)
    }

    func testFollowsNativeFocusToAnotherWorkspaceWhileFocusedWindowIsAlive() {
        let current = Workspace.get(byName: "current")
        let other = Workspace.get(byName: "other")
        let focused = TestWindow.new(id: 1, parent: current.rootTilingContainer)
        let cmdTabTarget = TestWindow.new(id: 2, parent: other.rootTilingContainer)
        focusNatively(focused)

        updateFocusCache(cmdTabTarget)

        assertEquals(focus.workspace, other)
        assertEquals(focus.windowOrNil?.windowId, 2)
        assertTrue(focused.isBound)
    }

    func testFollowsMacosFallbackWithinTheSameWorkspace() {
        let current = Workspace.get(byName: "current")
        TestWindow.new(id: 1, parent: current.rootTilingContainer)
        let quit = TestWindow.new(id: 2, parent: current.rootTilingContainer)
        focusNatively(quit)

        quit.isDestroyedForTest = true
        updateFocusCache(TestApp.shared.windows.first { $0.windowId == 1 })

        assertEquals(focus.workspace, current)
        assertEquals(focus.windowOrNil?.windowId, 1)
    }

    /// Slow Roads: AX gives up on the quitting app, so its window is collected before macOS activates the next app
    func testStaysWhenTheDeadWindowWasCollectedBeforeMacosFallsBack() {
        let current = Workspace.get(byName: "current")
        let other = Workspace.get(byName: "other")
        TestWindow.new(id: 1, parent: current.rootTilingContainer)
        let quit = TestWindow.new(id: 2, parent: current.rootTilingContainer)
        let fallback = TestWindow.new(id: 3, parent: other.rootTilingContainer)
        focusNatively(quit)

        updateFocusCache(nil) // The quitting app no longer answers AX
        quit.garbageCollect(skipClosedWindowsCache: false)
        updateFocusCache(fallback)

        assertEquals(focus.workspace, current)
        assertEquals(focus.windowOrNil?.windowId, 1)
        assertFalse(other.isVisible)
        assertEquals(TestApp.shared.focusedWindow?.windowId, 1)
    }

    func testFollowsTheNextNativeFocusChangeAfterMacosFellBack() {
        let current = Workspace.get(byName: "current")
        let quit = TestWindow.new(id: 1, parent: current.rootTilingContainer)
        let fallback = TestWindow.new(id: 2, parent: Workspace.get(byName: "other").rootTilingContainer)
        let third = Workspace.get(byName: "third")
        let cmdTabTarget = TestWindow.new(id: 3, parent: third.rootTilingContainer)
        focusNatively(quit)
        quit.garbageCollect(skipClosedWindowsCache: false)
        updateFocusCache(fallback)
        assertEquals(focus.workspace, current)

        updateFocusCache(cmdTabTarget)

        assertEquals(focus.workspace, third)
    }

    func testDeathOfUnfocusedWindowDoesNotStopFollowing() {
        let current = Workspace.get(byName: "current")
        let other = Workspace.get(byName: "other")
        let focused = TestWindow.new(id: 1, parent: current.rootTilingContainer)
        let unfocused = TestWindow.new(id: 2, parent: current.rootTilingContainer)
        let cmdTabTarget = TestWindow.new(id: 3, parent: other.rootTilingContainer)
        focusNatively(focused)

        unfocused.garbageCollect(skipClosedWindowsCache: false)
        updateFocusCache(cmdTabTarget)

        assertEquals(focus.workspace, other)
    }

    /// Slow Roads again: AeroSpace never got to know the game's window, so the workspace looked empty
    func testStaysWhenTheFrontmostAppQuitWithoutAeroSpaceKnowingItsWindows() {
        let current = Workspace.get(byName: "current")
        let other = Workspace.get(byName: "other")
        let fallback = TestWindow.new(id: 1, parent: other.rootTilingContainer)
        let third = Workspace.get(byName: "third")
        let cmdTabTarget = TestWindow.new(id: 2, parent: third.rootTilingContainer)
        assertTrue(current.focusWorkspace())
        let game: pid_t = 42
        frontmostPidForTests = game
        updateFocusCache(nil) // The game doesn't answer AX

        terminatedPidsForTests = [game]
        frontmostPidForTests = TestApp.shared.pid
        updateFocusCache(fallback)

        assertEquals(focus.workspace, current)
        assertFalse(other.isVisible)

        updateFocusCache(cmdTabTarget)
        assertEquals(focus.workspace, third)
    }

    func testFollowsNativeFocusFromAppThatIsStillRunning() {
        let current = Workspace.get(byName: "current")
        let other = Workspace.get(byName: "other")
        let cmdTabTarget = TestWindow.new(id: 1, parent: other.rootTilingContainer)
        assertTrue(current.focusWorkspace())
        frontmostPidForTests = 42 // E.g. Finder with only the desktop, or an app whose last window was closed
        updateFocusCache(nil)

        frontmostPidForTests = TestApp.shared.pid
        updateFocusCache(cmdTabTarget)

        assertEquals(focus.workspace, other)
    }

    private func focusNatively(_ window: TestWindow) {
        assertTrue(window.focusWindow())
        window.nativeFocus()
        updateFocusCache(window)
    }
}
