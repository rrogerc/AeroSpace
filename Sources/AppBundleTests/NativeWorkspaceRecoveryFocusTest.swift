@testable import AppBundle
import XCTest

@MainActor
final class NativeWorkspaceRecoveryFocusTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        TrayMenuModel.shared.isEnabled = true
    }

    func testRecoveryRestoresLogicalDestinationAfterLayoutWithoutReadingOldNativeFocus() async throws {
        let source = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        source.nativeFocus()
        let target = TestWindow.new(id: 2, parent: Workspace.get(byName: "target").rootTilingContainer)
        _ = target.focusWindow()
        try await restoreFocusAfterNativeWorkspaceRecovery {
            XCTAssertTrue(TestApp.shared.focusedWindow === source, "Focus must wait for layout")
        }
        XCTAssertTrue(TestApp.shared.focusedWindow === target)
        XCTAssertTrue(focus.windowOrNil === target)
    }

    func testNewCommandDuringRecoveryCannotBeOverwrittenByTheOldDestination() async throws {
        let original = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        _ = original.focusWindow()
        let target = TestWindow.new(id: 2, parent: Workspace.get(byName: "target").rootTilingContainer)
        try await restoreFocusAfterNativeWorkspaceRecovery {
            _ = target.focusWindow()
        }
        XCTAssertNil(TestApp.shared.focusedWindow, "The newer command owns native activation")
        XCTAssertTrue(focus.windowOrNil === target)
    }

    func testSwitchingAwayAndBackAlsoInvalidatesTheOldRecovery() async throws {
        let original = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        _ = original.focusWindow()
        try await restoreFocusAfterNativeWorkspaceRecovery {
            _ = Workspace.get(byName: "other").focusWorkspace()
            _ = original.focusWindow()
        }
        XCTAssertNil(TestApp.shared.focusedWindow)
    }

    func testDisableDuringRecoveryDoesNotActivateAWindow() async throws {
        let original = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        _ = original.focusWindow()
        defer { TrayMenuModel.shared.isEnabled = true }
        try await restoreFocusAfterNativeWorkspaceRecovery { TrayMenuModel.shared.isEnabled = false }
        XCTAssertNil(TestApp.shared.focusedWindow)
    }

    func testFailedLayoutDoesNotActivateAWindow() async {
        let original = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        _ = original.focusWindow()
        do {
            try await restoreFocusAfterNativeWorkspaceRecovery { throw CancellationError() }
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertNil(TestApp.shared.focusedWindow)
    }
}
