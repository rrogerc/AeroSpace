@testable import AppBundle
import Common
import XCTest

@MainActor
final class NativeDesktopWindowTest: XCTestCase {
    override func setUp() async throws {
        for container: TreeNode in [macosMinimizedWindowsContainer, macosPopupWindowsContainer] {
            for child in container.children { child.unbindFromParent() }
        }
        setUpWorkspacesForTests()
    }

    func testForeignTiledWindowLeavesNoEmptyTileOrFocusCandidate() async throws {
        let workspace = Workspace.get(byName: name)
        let remaining = TestWindow.new(id: 11, parent: workspace.rootTilingContainer)
        let departing = TestWindow.new(id: 12, parent: workspace.rootTilingContainer)
        XCTAssertTrue(departing.focusWindow())
        try await workspace.layoutWorkspace()
        let foreignFrame = try await departing.getAxRect(.cancellable)

        departing.isOnForeignNativeDesktopForTest = true
        try await normalizeLayoutReason()
        try await workspace.layoutWorkspace()

        XCTAssertEqual(workspace.rootTilingContainer.allLeafWindowsRecursive, [remaining])
        XCTAssertTrue(departing.parent === workspace.macOsForeignDesktopWindowsContainer)
        XCTAssertEqual(departing.layoutReason, .foreignNativeDesktop(prevParentKind: .tilingContainer))
        XCTAssertEqual(focus.windowOrNil, remaining)
        XCTAssertFalse(departing.focusWindow())
        let observedRemainingFrame = try await remaining.getAxRect(.cancellable)
        let remainingFrame = try XCTUnwrap(observedRemainingFrame)
        XCTAssertEqual(remainingFrame.width, workspace.workspaceMonitor.visibleRectPaddedByOuterGaps.width)
        let observedForeignFrame = try await departing.getAxRect(.cancellable)
        XCTAssertEqual(observedForeignFrame?.topLeftCorner, foreignFrame?.topLeftCorner)
        XCTAssertEqual(observedForeignFrame?.size, foreignFrame?.size)

        departing.isOnForeignNativeDesktopForTest = false
        try await normalizeLayoutReason()
        XCTAssertEqual(departing.layoutReason, .standard)
        XCTAssertTrue(departing.parent === workspace.rootTilingContainer)
        XCTAssertEqual(focus.windowOrNil, remaining, "A return without native focus must not reclaim focus")
    }

    func testReturningFloatingWindowKeepsOriginalWorkspaceAndFloatingBinding() async throws {
        let original = Workspace.get(byName: name + "-original")
        let window = TestWindow.new(id: 21, parent: original.floatingWindowsContainer)
        window.isOnForeignNativeDesktopForTest = true
        try await normalizeLayoutReason()
        let other = TestWindow.new(id: 22, parent: Workspace.get(byName: name + "-other").rootTilingContainer)
        XCTAssertTrue(other.focusWindow())

        window.isOnForeignNativeDesktopForTest = false
        try await normalizeLayoutReason()

        XCTAssertTrue(window.parent === original.floatingWindowsContainer)
        XCTAssertEqual(window.layoutReason, .standard)
        XCTAssertNil(window.foreignNativeDesktopWorkspaceName)
        XCTAssertEqual(focus.windowOrNil, other)
    }

    func testNativeFocusedReturnSelectsOriginalWorkspaceBeforeNormalization() async throws {
        let original = Workspace.get(byName: name + "-original")
        let window = TestWindow.new(id: 31, parent: original.rootTilingContainer)
        window.isOnForeignNativeDesktopForTest = true
        try await normalizeLayoutReason()
        let other = TestWindow.new(id: 32, parent: Workspace.get(byName: name + "-other").rootTilingContainer)
        XCTAssertTrue(other.focusWindow())
        updateFocusCache(other)

        // Native focus arrives before normalization has moved the window out of
        // its foreign-desktop container. Membership already says it is home.
        window.isOnForeignNativeDesktopForTest = false
        updateFocusCache(window)
        XCTAssertEqual(focus.windowOrNil, window)
        XCTAssertEqual(focus.workspace, original)
        try await normalizeLayoutReason()
        XCTAssertTrue(window.parent === original.rootTilingContainer)
        XCTAssertEqual(focus.windowOrNil, window)
    }

    func testNativeFullscreenTakesPrecedenceUntilItEndsOnForeignDesktop() async throws {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 41, parent: workspace.floatingWindowsContainer)
        window.isOnForeignNativeDesktopForTest = true
        window.isMacosFullscreenForTest = true
        try await normalizeLayoutReason()
        XCTAssertTrue(window.parent === workspace.macOsNativeFullscreenWindowsContainer)
        XCTAssertEqual(window.layoutReason, .macos(prevParentKind: .floatingWindowsContainer))

        window.isMacosFullscreenForTest = false
        try await normalizeLayoutReason()
        XCTAssertTrue(window.parent === workspace.macOsForeignDesktopWindowsContainer)
        XCTAssertEqual(window.layoutReason, .foreignNativeDesktop(prevParentKind: .floatingWindowsContainer))
        window.isOnForeignNativeDesktopForTest = false
        try await normalizeLayoutReason()
        XCTAssertTrue(window.parent === workspace.floatingWindowsContainer)
    }

    func testMinimizedForeignWindowKeepsOriginalWorkspaceAcrossGarbageCollection() async throws {
        let originalName = name + "-original"
        let window = TestWindow.new(id: 51, parent: Workspace.get(byName: originalName).rootTilingContainer)
        window.isOnForeignNativeDesktopForTest = true
        try await normalizeLayoutReason()
        window.isMacosMinimizedForTest = true
        try await normalizeLayoutReason()
        XCTAssertTrue(window.parent === macosMinimizedWindowsContainer)
        let other = TestWindow.new(id: 52, parent: Workspace.get(byName: name + "-other").rootTilingContainer)
        XCTAssertTrue(other.focusWindow())
        Workspace.garbageCollectUnusedWorkspaces()

        window.isMacosMinimizedForTest = false
        try await normalizeLayoutReason()
        XCTAssertEqual(window.nodeWorkspace?.name, originalName)
        XCTAssertTrue(window.parent is MacosForeignDesktopWindowsContainer)
        window.isOnForeignNativeDesktopForTest = false
        try await normalizeLayoutReason()
        XCTAssertEqual(window.nodeWorkspace?.name, originalName)
        XCTAssertTrue(window.parent is TilingContainer)
        XCTAssertEqual(focus.windowOrNil, other)
    }

    func testAppHiddenTakesPrecedenceWithoutLosingForeignDesktopState() async throws {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 61, parent: workspace.rootTilingContainer)
        window.isOnForeignNativeDesktopForTest = true
        try await normalizeLayoutReason()
        window.isMacosAppHiddenForTest = true
        try await normalizeLayoutReason()
        XCTAssertTrue(window.parent === workspace.macOsNativeHiddenAppsWindowsContainer)
        XCTAssertEqual(window.layoutReason, .macos(prevParentKind: .tilingContainer))
        XCTAssertNil(workspace.toLiveFocus().windowOrNil)
        XCTAssertFalse(window.focusWindow())

        window.isMacosAppHiddenForTest = false
        try await normalizeLayoutReason()
        XCTAssertTrue(window.parent === workspace.macOsForeignDesktopWindowsContainer)
        window.isOnForeignNativeDesktopForTest = false
        try await normalizeLayoutReason()
        XCTAssertTrue(window.parent === workspace.rootTilingContainer)
    }

    func testWorkspaceWithOnlyForeignWindowIsRetainedWithoutFocusableWindow() async throws {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 71, parent: workspace.rootTilingContainer)
        window.isOnForeignNativeDesktopForTest = true
        try await normalizeLayoutReason()
        XCTAssertFalse(workspace.isEffectivelyEmpty)
        XCTAssertNil(workspace.toLiveFocus().windowOrNil)
        Workspace.garbageCollectUnusedWorkspaces()
        XCTAssertTrue(Workspace.all.contains { $0 === workspace })
    }

    func testUnknownMembershipDoesNotRestoreOrFocusAForeignWindow() async throws {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 81, parent: workspace.rootTilingContainer)
        window.isOnForeignNativeDesktopForTest = true
        try await normalizeLayoutReason()

        window.isOnForeignNativeDesktopForTest = false
        window.nativeDesktopMembershipKnownForTest = false
        try await normalizeLayoutReason()
        XCTAssertTrue(window.parent === workspace.macOsForeignDesktopWindowsContainer)
        XCTAssertFalse(window.focusWindow())
        XCTAssertNil(workspace.toLiveFocus().windowOrNil)

        window.nativeDesktopMembershipKnownForTest = true
        try await normalizeLayoutReason()
        XCTAssertTrue(window.parent === workspace.rootTilingContainer)
    }
}
