@testable import AppBundle
import Common
import XCTest

@MainActor
final class DwindleMoveFocusTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.dwindle.enabled = true
    }

    // Hyprland's dwindleIssue13349 test: moving puts the window next to the window just past its edge
    func testMoveSplitsTheWindowJustPastTheEdge() async throws {
        let workspace = Workspace.get(byName: name)
        for id: UInt32 in 1 ... 3 {
            try await openWindow(id, in: workspace)
        }

        await runCommand("move left") // From the bottom right to the bottom left
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .v_tiles([.window(1), .window(3)]),
            .window(2),
        ]))

        await runCommand("move right") // And back
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .window(1),
            .v_tiles([.window(2), .window(3)]),
        ]))
    }

    // Hyprland's dwindleMoveAcrossToggledSplit test
    func testMovingAcrossTheSplitSwapsTheHalvesAndKeepsTheDirection() async throws {
        let workspace = Workspace.get(byName: name)
        let window1 = try await openWindow(1, in: workspace)
        try await openWindow(2, in: workspace)
        await runCommand("dwindle togglesplit")
        assertEquals(window1.focusWindow(), true)

        await runCommand("move down")
        assertEquals(workspace.rootTilingContainer.layoutDescription, .v_tiles([.window(2), .window(1)]))
    }

    // Hyprland's dwindleMoveSmallWindowAcrossSplit test
    func testMovingAcrossTheSplitResetsTheRatio() async throws {
        config.dwindle.forceSplit = .left
        config.dwindle.defaultSplitRatio = 1.2
        let workspace = Workspace.get(byName: name)
        let window1 = try await openWindow(1, in: workspace)
        try await openWindow(2, in: workspace)
        window1.setWeight(.h, 1728) // Window 2 on the left gets 10%
        Window.get(byId: 2).orDie().setWeight(.h, 192)

        await runCommand("move right")
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2)]))
        try await workspace.layoutWorkspace()
        assertEquals(try await frame(of: 2), [1152, 0, 768, 1079])
    }

    // Hyprland's dwindleForceSplitOnMoveToWorkspace test
    func testMoveNodeToWorkspaceRespectsForceSplit() async throws {
        let workspaceA = Workspace.get(byName: "a")
        try await openWindow(1, in: workspaceA)
        try await openWindow(2, in: Workspace.get(byName: "b"))

        await runCommand("move-node-to-workspace a")
        assertEquals(workspaceA.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2)]))
    }

    func testMoveAtTheEdgeOfTheWorkspace() async throws {
        let workspace = Workspace.get(byName: name)
        for id: UInt32 in 1 ... 3 {
            try await openWindow(id, in: workspace)
        }

        let failResult = await parseCommand("move down --boundaries-action fail").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(failResult.exitCode.rawValue, 2)
        await runCommand("move down --boundaries-action stop")
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .window(1),
            .v_tiles([.window(2), .window(3)]),
        ]))

        await runCommand("move down") // The default is create-implicit-container: the window takes the bottom half
        assertEquals(workspace.rootTilingContainer.layoutDescription, .v_tiles([
            .h_tiles([.window(1), .window(2)]),
            .window(3),
        ]))
    }

    func testMoveInAndOutOfAnAccordion() async throws {
        let workspace = Workspace.get(byName: name)
        for id: UInt32 in 1 ... 3 {
            try await openWindow(id, in: workspace)
        }
        await runCommand("layout v_accordion")

        await runCommand("move up") // Along the accordion: reorders it
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .window(1),
            .v_accordion([.window(3), .window(2)]),
        ]))

        await runCommand("move left") // Across the accordion: leaves it
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .v_tiles([.window(1), .window(3)]),
            .window(2),
        ]))
    }
}

@MainActor
func runCommand(_ command: String) async {
    let result = await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)
    assertEquals(result.exitCode.rawValue, 0, additionalMsg: "\(command): \(result.stderr)")
}
