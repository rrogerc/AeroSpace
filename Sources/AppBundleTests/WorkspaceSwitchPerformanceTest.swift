@testable import AppBundle
import CoreGraphics
import Common
import XCTest

@MainActor
final class WorkspaceSwitchPerformanceTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        updateFocusCache(nil)
    }

    func testWindowServerBoundsUseTopLeftCoordinatesIncludingNegativeMonitors() throws {
        let info = try XCTUnwrap(WindowServerWindowInfo(record(bounds: CGRect(x: -1920, y: -1080, width: 800, height: 600))))
        XCTAssertEqual(info.rect.topLeftCorner, CGPoint(x: -1920, y: -1080))
        XCTAssertEqual(info.rect.size, CGSize(width: 800, height: 600))
    }

    func testRejectsIncompleteAndInvalidWindowServerBounds() {
        XCTAssertNil(WindowServerWindowInfo([:]))
        for bounds in [
            CGRect(x: 0, y: 0, width: 0, height: 600),
            CGRect(x: 0, y: 0, width: -800, height: 600),
            CGRect(x: 0, y: CGFloat.infinity, width: 800, height: 600),
            CGRect(x: 0, y: 0, width: 800, height: CGFloat.nan),
        ] {
            XCTAssertNil(WindowServerWindowInfo(record(bounds: bounds)))
        }
        var missingOwner = record()
        missingOwner[kCGWindowOwnerPID as String] = nil
        XCTAssertNil(WindowServerWindowInfo(missingOwner))
    }

    func testWorkspaceSwitchCanReuseConfirmedNativeFocus() throws {
        let window = focusedWindow()
        let windows = try [XCTUnwrap(WindowServerWindowInfo(record()))]
        XCTAssertTrue(cachedNativeFocusedWindow(frontmostPid: 0, windows: windows) === window)
    }

    func testWorkspaceSwitchFallsBackWhenAnotherAppOrWindowIsFrontmost() throws {
        _ = focusedWindow()
        let windows = try [XCTUnwrap(WindowServerWindowInfo(record()))]
        XCTAssertNil(cachedNativeFocusedWindow(frontmostPid: 99, windows: windows))
        XCTAssertNil(cachedNativeFocusedWindow(frontmostPid: nil, windows: windows))
        let newWindow = try XCTUnwrap(WindowServerWindowInfo(record(windowId: 2)))
        XCTAssertNil(cachedNativeFocusedWindow(frontmostPid: 0, windows: [newWindow] + windows))
        XCTAssertNil(cachedNativeFocusedWindow(frontmostPid: 0, windows: []))
    }

    func testWorkspaceSwitchFallsBackForPopupOrUnconfirmedFocus() throws {
        let window = focusedWindow()
        let popup = try XCTUnwrap(WindowServerWindowInfo(record(windowId: 2, layer: 3)))
        let nativeWindow = try XCTUnwrap(WindowServerWindowInfo(record()))
        XCTAssertNil(cachedNativeFocusedWindow(frontmostPid: 0, windows: [popup, nativeWindow]))
        window.isHiddenInCornerForTest = true
        XCTAssertNil(cachedNativeFocusedWindow(frontmostPid: 0, windows: [nativeWindow]))
        window.isHiddenInCornerForTest = false
        updateFocusCache(nil)
        XCTAssertNil(cachedNativeFocusedWindow(frontmostPid: 0, windows: [nativeWindow]))
    }

    func testOldFocusReplyStaysStaleAfterSwitchingAwayAndBack() {
        let original = focus.workspace
        let token = NativeFocusRefreshToken()
        XCTAssertTrue(token.isCurrent)
        _ = Workspace.get(byName: "other").focusWorkspace()
        XCTAssertFalse(token.isCurrent)
        _ = original.focusWorkspace()
        XCTAssertFalse(token.isCurrent)
    }

    func testVisibleNativeSingleWindowDoesNotNeedASlowAxFocusReply() throws {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        _ = window.focusWindow()
        let windows = try [XCTUnwrap(WindowServerWindowInfo(record()))]
        let gate = NativeVisibilityGate()
        gate.complete(true)
        XCTAssertNil(cachedNativeFocusedWindow(frontmostPid: 0, windows: windows))
        XCTAssertTrue(cachedNativeFocusedWindow(frontmostPid: 0, windows: windows, nativeVisibility: gate, appWindowCount: 1) === window)
    }

    func testNativeFocusShortcutStillRejectsUnacknowledgedMovesAndMultipleWindows() throws {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        _ = window.focusWindow()
        let windows = try [XCTUnwrap(WindowServerWindowInfo(record()))]
        let gate = NativeVisibilityGate()
        XCTAssertNil(cachedNativeFocusedWindow(frontmostPid: 0, windows: windows, nativeVisibility: gate, appWindowCount: 1))
        gate.complete(true)
        XCTAssertNil(cachedNativeFocusedWindow(frontmostPid: 0, windows: windows, nativeVisibility: gate, appWindowCount: 2))
        gate.cancel()
        XCTAssertNil(cachedNativeFocusedWindow(frontmostPid: 0, windows: windows, nativeVisibility: gate, appWindowCount: 1))
    }

    func testNativeFocusShortcutDoesNotMistakeAPopupOrDifferentWindowForTheTarget() throws {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        _ = window.focusWindow()
        let gate = NativeVisibilityGate()
        gate.complete(true)
        let windows = try [XCTUnwrap(WindowServerWindowInfo(record()))]
        XCTAssertNil(cachedNativeFocusedWindow(frontmostPid: 99, windows: windows, nativeVisibility: gate, appWindowCount: 1))
        for front in [record(windowId: 2), record(windowId: 3, layer: 3)] {
            let changed = try [XCTUnwrap(WindowServerWindowInfo(front))] + windows
            XCTAssertNil(cachedNativeFocusedWindow(frontmostPid: 0, windows: changed, nativeVisibility: gate, appWindowCount: 1))
        }
    }

    func testNoOpFocusDoesNotInvalidateRefresh() {
        let token = NativeFocusRefreshToken()
        _ = focus.workspace.focusWorkspace()
        XCTAssertTrue(token.isCurrent)
    }

    func testSwitchWithSameSizeNeedsOnlyPositionWrite() {
        let bounds = CGRect(x: 2047, y: 1120, width: 800, height: 600)
        let update = WindowFrameUpdate(topLeft: CGPoint(x: 13, y: 13), size: bounds.size)
        XCTAssertEqual(update.skippingUnchangedValues(comparedTo: bounds), WindowFrameUpdate(topLeft: update.topLeft, size: nil))
    }

    func testSkipsOnlyObservedUnchangedFrames() {
        let bounds = CGRect(x: 13, y: 13, width: 800, height: 600)
        let update = WindowFrameUpdate(topLeft: bounds.origin, size: bounds.size)
        XCTAssertTrue(update.skippingUnchangedValues(comparedTo: bounds).isEmpty)
        // A later mouse drag must be corrected even when the requested frame did not change.
        let dragged = CGRect(x: 300, y: 200, width: 800, height: 600)
        XCTAssertEqual(update.skippingUnchangedValues(comparedTo: dragged), WindowFrameUpdate(topLeft: bounds.origin, size: nil))
        XCTAssertEqual(update.skippingUnchangedValues(comparedTo: nil), update)
    }

    func testHiddenFrameObservationDoesNotSurviveAQueuedOrCompletedNewMove() throws {
        let oldMove = RunLoopJob(.cancellable)
        oldMove.complete()
        let observation = HiddenWindowFrameObservation(info: try XCTUnwrap(WindowServerWindowInfo(record())), precedingFrame: oldMove)
        XCTAssertTrue(observation.isCurrent(latestFrame: oldMove))
        let newMove = RunLoopJob(.cancellable)
        XCTAssertFalse(observation.isCurrent(latestFrame: newMove))
        newMove.complete()
        XCTAssertFalse(observation.isCurrent(latestFrame: newMove))
        XCTAssertFalse(observation.isCurrent(latestFrame: nil))
    }

    func testCancelledMoveIsNotSettledUntilWorkerFinishesIt() throws {
        let move = RunLoopJob(.cancellable)
        let observation = HiddenWindowFrameObservation(info: try XCTUnwrap(WindowServerWindowInfo(record())), precedingFrame: move)
        move.cancel()
        XCTAssertFalse(observation.isCurrent(latestFrame: move))
        move.complete()
        XCTAssertTrue(observation.isCurrent(latestFrame: move))
    }

    func testResizeRetainsPositionAndRetriesAppClampedSizes() {
        let bounds = CGRect(x: 13, y: 13, width: 800, height: 600)
        let update = WindowFrameUpdate(topLeft: bounds.origin, size: CGSize(width: 1000, height: 600))
        XCTAssertEqual(update.skippingUnchangedValues(comparedTo: bounds), update)
        let clamped = CGRect(x: 13, y: 13, width: 900, height: 600)
        XCTAssertEqual(update.skippingUnchangedValues(comparedTo: clamped), update)
    }

    func testOnlyWorkspaceCommandsAllowCachedNativeFocus() {
        for command in ["workspace 1", "workspace next", "workspace-back-and-forth"] {
            XCTAssertTrue(parseCommand(command).cmdOrDie.flatten().allSatisfy(\.isWorkspaceSwitch))
        }
        for command in ["focus left", "move left", "move-node-to-workspace 1", "close", "fullscreen"] {
            XCTAssertFalse(parseCommand(command).cmdOrDie.flatten().contains(where: \.isWorkspaceSwitch))
        }
    }

    private func focusedWindow() -> TestWindow {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        _ = window.focusWindow()
        updateFocusCache(window)
        return window
    }

    private func record(windowId: UInt32 = 1, layer: Int = 0, bounds: CGRect = CGRect(x: 13, y: 13, width: 800, height: 600)) -> [String: Any] {
        [
            kCGWindowNumber as String: windowId,
            kCGWindowOwnerPID as String: Int32(0),
            kCGWindowLayer as String: layer,
            kCGWindowBounds as String: bounds.dictionaryRepresentation,
        ]
    }
}
