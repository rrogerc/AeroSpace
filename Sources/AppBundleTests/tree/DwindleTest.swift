@testable import AppBundle
import Common
import XCTest

// The test monitor is 1920x1080. Tiling windows touch its bottom, so the layout height is 1079
@MainActor
final class DwindleTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.dwindle.enabled = true
    }

    func testNewWindowsSplitTheMostRecentWindowByShape() async throws {
        let workspace = Workspace.get(byName: name)
        for id: UInt32 in 1 ... 5 {
            try await openWindow(id, in: workspace)
        }
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .window(1),
            .v_tiles([
                .window(2),
                .h_tiles([
                    .window(3),
                    .v_tiles([.window(4), .window(5)]),
                ]),
            ]),
        ]))

        try await workspace.layoutWorkspace()
        assertEquals(try await frame(of: 1), [0, 0, 960, 1079])
        assertEquals(try await frame(of: 2), [960, 0, 960, 539.5])
        assertEquals(try await frame(of: 3), [960, 539.5, 480, 539.5])
        assertEquals(try await frame(of: 4), [1440, 539.5, 480, 269.75])
        assertEquals(try await frame(of: 5), [1440, 809.25, 480, 269.75])
    }

    func testForceSplitLeft() async throws {
        config.dwindle.forceSplit = .left
        let workspace = Workspace.get(byName: name)
        for id: UInt32 in 1 ... 3 {
            try await openWindow(id, in: workspace)
        }
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .v_tiles([.window(3), .window(2)]),
            .window(1),
        ]))
    }

    func testDefaultSplitRatioIsTheShareOfTheFirstWindow() async throws {
        config.dwindle.defaultSplitRatio = 1.2
        let workspace = Workspace.get(byName: name)
        try await openWindow(1, in: workspace)
        try await openWindow(2, in: workspace)

        try await workspace.layoutWorkspace()
        assertEquals(try await rect(of: 1)?.width, 1152)
        assertEquals(try await rect(of: 2)?.width, 768)
    }

    func testSplitWidthMultiplier() async throws {
        config.dwindle.splitWidthMultiplier = 2
        let workspace = Workspace.get(byName: name)
        try await openWindow(1, in: workspace)
        try await openWindow(2, in: workspace)
        // 1920 isn't wider than 2 * 1079
        assertEquals(workspace.rootTilingContainer.layoutDescription, .v_tiles([.window(1), .window(2)]))
    }

    func testFocusedFloatingWindowDoesntGetSplit() async throws {
        let workspace = Workspace.get(byName: name)
        let window1 = try await openWindow(1, in: workspace)
        try await openWindow(2, in: workspace)
        assertEquals(window1.focusWindow(), true)
        assertEquals(TestWindow.new(id: 3, parent: workspace.floatingWindowsContainer).focusWindow(), true)

        try await openWindow(4, in: workspace)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .v_tiles([.window(1), .window(4)]),
            .window(2),
        ]))
    }

    func testNewWindowJoinsTheFocusedAccordion() async throws {
        let workspace = Workspace.get(byName: name)
        try await openWindow(1, in: workspace)
        try await openWindow(2, in: workspace)
        try await openWindow(3, in: workspace)
        await parseCommand("layout v_accordion").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .window(1),
            .v_accordion([.window(2), .window(3)]),
        ]))

        try await openWindow(4, in: workspace)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .window(1),
            .v_accordion([.window(2), .window(3), .window(4)]),
        ]))
    }

    func testTilingAFloatingWindowSplitsTheMostRecentTilingWindow() async throws {
        let workspace = Workspace.get(byName: name)
        let window1 = try await openWindow(1, in: workspace)
        try await openWindow(2, in: workspace)
        let window3 = try await openWindow(3, in: workspace)
        await parseCommand("layout floating").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2)]))

        assertEquals(window1.focusWindow(), true)
        assertEquals(window3.focusWindow(), true)
        await parseCommand("layout tiling").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .v_tiles([.window(1), .window(3)]),
            .window(2),
        ]))
    }

    func testEmptyMostRecentContainerIsSkipped() async throws {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 1, parent: root)
        _ = TilingContainer.newVTiles(parent: root, adaptiveWeight: 1, index: INDEX_BIND_LAST) // Now the most recent child

        try await openWindow(2, in: workspace)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2)]))
    }

    func testClosedWindowGivesItsSpaceToTheOtherHalf() async throws {
        // The flatten normalization is off in tests. Dwindle relies on it, so it's always on in dwindle workspaces
        let workspace = Workspace.get(byName: name)
        try await openWindow(1, in: workspace)
        try await openWindow(2, in: workspace)
        let window3 = try await openWindow(3, in: workspace)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .window(1),
            .v_tiles([.window(2), .window(3)]),
        ]))

        window3.closeAxWindow()
        try await workspace.layoutWorkspace()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2)]))
        assertEquals(try await frame(of: 2), [960, 0, 960, 1079])
    }

    func testSplitsKeepTheirProportionsWhenTheyGrow() async throws {
        let workspace = Workspace.get(byName: name)
        let window1 = try await openWindow(1, in: workspace)
        for id: UInt32 in 2 ... 4 {
            try await openWindow(id, in: workspace)
        }
        let window3 = Window.get(byId: 3).orDie()
        let window4 = Window.get(byId: 4).orDie()
        window3.setWeight(.h, 288) // 30% of 960
        window4.setWeight(.h, 672)

        window1.closeAxWindow()
        try await workspace.layoutWorkspace()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .v_tiles([
            .window(2),
            .h_tiles([.window(3), .window(4)]),
        ]))
        assertEquals(try await rect(of: 3)?.width, 576) // Still 30%
        assertEquals(try await rect(of: 4)?.width, 1344)
    }

    func testNonPositiveWeightsFallBackToTheAdditiveRule() async throws {
        let workspace = Workspace.get(byName: name)
        try await openWindow(1, in: workspace)
        try await openWindow(2, in: workspace)
        // Both commands run before the next layout, like they would in one binding
        await parseCommand("balance-sizes").cmdOrDie.run(.defaultEnv, .emptyStdin)
        await parseCommand("resize smart +50").cmdOrDie.run(.defaultEnv, .emptyStdin)

        try await workspace.layoutWorkspace()
        assertEquals(try await rect(of: 1)?.width, 910)
        assertEquals(try await rect(of: 2)?.width, 1010)
    }

    func testClosingAWindowDoesntEndFullscreenOfAnotherOne() async throws {
        let workspace = Workspace.get(byName: name)
        let window1 = try await openWindow(1, in: workspace)
        for id: UInt32 in 2 ... 4 {
            try await openWindow(id, in: workspace)
        }
        assertEquals(window1.focusWindow(), true)
        await parseCommand("fullscreen").cmdOrDie.run(.defaultEnv, .emptyStdin)

        // The split of 3 and 4 goes away, which must not make 3 the most recent window
        Window.get(byId: 4).orDie().closeAxWindow()
        try await workspace.layoutWorkspace()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2), .window(3)])]))
        assertEquals(workspace.mostRecentWindowRecursive?.windowId, 1)
        assertEquals(window1.isFullscreen, true)
    }

    func testWithoutPreserveSplitSplitsFollowTheirShape() async throws {
        config.dwindle.preserveSplit = false
        let workspace = Workspace.get(byName: name)
        let window1 = try await openWindow(1, in: workspace)
        try await openWindow(2, in: workspace)
        try await openWindow(3, in: workspace)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .window(1),
            .v_tiles([.window(2), .window(3)]),
        ]))

        window1.closeAxWindow()
        workspace.normalizeContainers()
        // The split of 2 and 3 is now as wide as the monitor
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(2), .window(3)]))
    }

    func testWithPreserveSplitSplitsKeepTheirDirection() async throws {
        let workspace = Workspace.get(byName: name)
        let window1 = try await openWindow(1, in: workspace)
        try await openWindow(2, in: workspace)
        try await openWindow(3, in: workspace)

        window1.closeAxWindow()
        workspace.normalizeContainers()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .v_tiles([.window(2), .window(3)]))
    }

    func testNestedSplitsCanHaveTheSameOrientation() {
        config.enableNormalizationOppositeOrientationForNestedContainers = true
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1, index: INDEX_BIND_LAST).apply {
                TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
            }
        }
        workspace.normalizeContainers()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .window(1),
            .h_tiles([.window(2), .window(3)]),
        ]))
    }

    func testLayoutOrientationDoesntFlipTheAncestors() async throws {
        config.enableNormalizationOppositeOrientationForNestedContainers = true
        let workspace = Workspace.get(byName: name)
        for id: UInt32 in 1 ... 3 {
            try await openWindow(id, in: workspace)
        }
        await parseCommand("layout horizontal").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .window(1),
            .h_tiles([.window(2), .window(3)]),
        ]))
    }

    func testContainersWithMoreThanTwoChildrenAreFoldedIntoASpiral() async throws {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            for id: UInt32 in 1 ... 4 {
                TestWindow.new(id: id, parent: $0)
            }
            TilingContainer(parent: $0, adaptiveWeight: 1, .v, .accordion, index: INDEX_BIND_LAST).apply {
                for id: UInt32 in 5 ... 7 {
                    TestWindow.new(id: id, parent: $0)
                }
            }
        }
        assertEquals(Window.get(byId: 3)?.focusWindow(), true)

        workspace.normalizeContainers()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .window(1),
            .v_tiles([
                .window(2),
                .h_tiles([
                    .window(3),
                    .v_tiles([
                        .window(4),
                        .v_accordion([.window(5), .window(6), .window(7)]), // Accordions are left alone
                    ]),
                ]),
            ]),
        ]))
        assertEquals(workspace.mostRecentWindowRecursive?.windowId, 3)

        try await workspace.layoutWorkspace()
        assertEquals(try await rect(of: 1)?.width, 960) // Every fold splits in halves
        assertEquals(try await rect(of: 2)?.height, 539.5)
    }

    func testNewRootIsTilesEvenIfTheDefaultIsAccordion() {
        config.defaultRootContainerLayout = .accordion
        assertEquals(Workspace.get(byName: name).rootTilingContainer.layout, .tiles)
    }

    func testWindowMovedToWorkspaceSplitsItsMostRecentWindow() async throws {
        let workspaceA = Workspace.get(byName: "a")
        let window1 = try await openWindow(1, in: workspaceA)
        try await openWindow(2, in: workspaceA)
        assertEquals(window1.focusWindow(), true)
        try await openWindow(3, in: Workspace.get(byName: "b"))

        await parseCommand("move-node-to-workspace a").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(workspaceA.rootTilingContainer.layoutDescription, .h_tiles([
            .v_tiles([.window(1), .window(3)]),
            .window(2),
        ]))
    }
}

/// Opens a tiling window the way AeroSpace places new windows, and focuses it like macOS does
@MainActor
@discardableResult
func openWindow(_ id: UInt32, in workspace: Workspace) async throws -> TestWindow {
    let window = TestWindow.new(id: id, parent: workspace.floatingWindowsContainer)
    try await window.relayoutWindow(on: workspace, .nonCancellable, forceTile: true)
    check(window.focusWindow())
    return window
}

@MainActor
func rect(of windowId: UInt32) async throws -> Rect? {
    try await Window.get(byId: windowId).orDie().getAxRect(.nonCancellable)
}

/// [x, y, width, height]
@MainActor
func frame(of windowId: UInt32) async throws -> [CGFloat]? {
    try await rect(of: windowId).map { [$0.topLeftX, $0.topLeftY, $0.width, $0.height] }
}
