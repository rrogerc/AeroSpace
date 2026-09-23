@testable import AppBundle
import Common
import XCTest

@MainActor
final class DwindleCommandTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.dwindle.enabled = true
    }

    func testParse() {
        assertEquals(parsedMessage("dwindle togglesplit"), .togglesplit)
        assertEquals(parsedMessage("dwindle rotatesplit"), .rotatesplit(degrees: 90))
        assertEquals(parsedMessage("dwindle rotatesplit -90"), .rotatesplit(degrees: -90))
        assertEquals(parsedMessage("dwindle rotatesplit --window-id 1"), .rotatesplit(degrees: 90))
        assertEquals(parsedMessage("dwindle splitratio -0.1"), .splitratio(.add(-0.1)))
        assertEquals(parsedMessage("dwindle splitratio +0.2"), .splitratio(.add(0.2)))
        assertEquals(parsedMessage("dwindle splitratio 1.2"), .splitratio(.set(1.2)))
        assertEquals(parsedMessage("dwindle preselect up"), .preselect(.up))
        assertEquals(parsedMessage("dwindle preselect none"), .preselect(nil))
        assertEquals(parsedCommand("dwindle movetoroot --unstable")?.args.unstable, true)

        assertTrue(parseCommand("dwindle rotatesplit 45").errorOrNil?.contains("The angle must be a multiple of 90. Got: 45") == true)
        assertTrue(parseCommand("dwindle splitratio nan").errorOrNil?.contains("Can't parse ratio 'nan'") == true)
        assertTrue(parseCommand("dwindle splitratio").errorOrNil?.contains("splitratio must be followed by [+|-]<ratio>") == true)
        assertTrue(parseCommand("dwindle preselect diagonal").errorOrNil?.contains("Can't parse 'diagonal'") == true)
        assertTrue(parseCommand("dwindle foo").errorOrNil?.contains("Unknown argument 'foo'") == true)
        assertEquals(parseCommand("dwindle swapsplit --unstable").errorOrNil, "--unstable is only allowed with 'movetoroot'")
    }

    func testFailsWithoutDwindle() async throws {
        let workspace = Workspace.get(byName: name)
        try await openWindow(1, in: workspace)
        config.dwindle.enabled = false
        let result = await parseCommand("dwindle swapsplit").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr, ["The dwindle layout isn't enabled. See 'dwindle.enabled' in the config"])
    }

    func testTogglesplit() async throws {
        let workspace = Workspace.get(byName: name)
        try await openWindow(1, in: workspace)
        try await openWindow(2, in: workspace)

        await runCommand("dwindle togglesplit")
        assertEquals(workspace.rootTilingContainer.layoutDescription, .v_tiles([.window(1), .window(2)]))

        config.dwindle.preserveSplit = false
        let result = await parseCommand("dwindle togglesplit").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
    }

    func testSwapsplitKeepsTheSizesAndTheFocus() async throws {
        let workspace = Workspace.get(byName: name)
        let window1 = try await openWindow(1, in: workspace)
        let window2 = try await openWindow(2, in: workspace)
        window1.setWeight(.h, 576) // 30%
        window2.setWeight(.h, 1344)

        await runCommand("dwindle swapsplit")
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(2), .window(1)]))
        assertTrue(workspace.rootTilingContainer.mostRecentChild === window2)
        try await workspace.layoutWorkspace()
        assertEquals(try await frame(of: 2), [0, 0, 576, 1079])
    }

    func testRotatesplit() async throws {
        let workspace = Workspace.get(byName: name)
        try await openWindow(1, in: workspace)
        try await openWindow(2, in: workspace)
        let expected: [LayoutDescription] = [
            .v_tiles([.window(1), .window(2)]),
            .h_tiles([.window(2), .window(1)]),
            .v_tiles([.window(2), .window(1)]),
            .h_tiles([.window(1), .window(2)]),
        ]
        for layout in expected {
            await runCommand("dwindle rotatesplit")
            assertEquals(workspace.rootTilingContainer.layoutDescription, layout)
        }

        await runCommand("dwindle rotatesplit 180")
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(2), .window(1)]))
        await runCommand("dwindle rotatesplit -90")
        assertEquals(workspace.rootTilingContainer.layoutDescription, .v_tiles([.window(1), .window(2)]))
    }

    func testSplitratio() async throws {
        let workspace = Workspace.get(byName: name)
        try await openWindow(1, in: workspace)
        try await openWindow(2, in: workspace)
        let cases: [(command: String, width: CGFloat)] = [
            ("dwindle splitratio 1.2", 1152),
            ("dwindle splitratio -0.4", 768),
            ("dwindle splitratio +5", 1824), // Clamped to 1.9
            ("dwindle splitratio 0", 96), // Clamped to 0.1
        ]
        for (command, width) in cases {
            await runCommand(command)
            try await workspace.layoutWorkspace()
            assertEquals(try await rect(of: 1)?.width.rounded(), width, additionalMsg: command) // 1.2 - 0.4 isn't exactly 0.8
        }
    }

    func testPreselectAppliesOnce() async throws {
        let workspace = Workspace.get(byName: name)
        try await openWindow(1, in: workspace)
        try await openWindow(2, in: workspace)

        await runCommand("dwindle preselect up")
        try await openWindow(3, in: workspace)
        try await openWindow(4, in: workspace)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .window(1),
            .v_tiles([
                .h_tiles([.window(3), .window(4)]),
                .window(2),
            ]),
        ]))
    }

    func testPermanentPreselect() async throws {
        config.dwindle.permanentDirectionOverride = true
        let workspace = Workspace.get(byName: name)
        try await openWindow(1, in: workspace)
        try await openWindow(2, in: workspace)

        await runCommand("dwindle preselect left")
        try await openWindow(3, in: workspace)
        try await openWindow(4, in: workspace)
        await runCommand("dwindle preselect none")
        try await openWindow(5, in: workspace)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .window(1),
            .h_tiles([
                .h_tiles([
                    .v_tiles([.window(4), .window(5)]),
                    .window(3),
                ]),
                .window(2),
            ]),
        ]))
    }

    func testMovetoroot() async throws {
        let workspace = Workspace.get(byName: name)
        try await openWindow(1, in: workspace)
        try await openWindow(2, in: workspace)
        try await openWindow(3, in: workspace)

        await runCommand("dwindle movetoroot") // Window 3 stays on the right side
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .v_tiles([.window(2), .window(1)]),
            .window(3),
        ]))
        let result = await parseCommand("dwindle movetoroot").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.stderr, ["The window is already one half of the workspace"])

        assertEquals(Window.get(byId: 1)?.focusWindow(), true)
        await runCommand("dwindle movetoroot --unstable") // Window 1 swaps places with window 3
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .v_tiles([.window(2), .window(3)]),
            .window(1),
        ]))
    }

    func testMovetorootWithOneWindow() async throws {
        try await openWindow(1, in: Workspace.get(byName: name))
        let result = await parseCommand("dwindle movetoroot").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.stderr, ["The workspace isn't split in two"])
    }

    func testAccordionIsOneHalfOfTheSplit() async throws {
        let workspace = Workspace.get(byName: name)
        try await openWindow(1, in: workspace)
        try await openWindow(2, in: workspace)
        try await openWindow(3, in: workspace)
        await runCommand("layout v_accordion")

        await runCommand("dwindle swapsplit")
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .v_accordion([.window(2), .window(3)]),
            .window(1),
        ]))

        await runCommand("layout h_accordion --root") // The accordion inside is now within the root accordion
        let result = await parseCommand("dwindle swapsplit").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.stderr, ["The window isn't one half of a split"])
    }

    func testSplitCommandIsNotAvailable() async throws {
        try await openWindow(1, in: Workspace.get(byName: name))
        let result = await parseCommand("split horizontal").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertTrue(result.stderr.first?.starts(with: "'split' isn't available in the dwindle layout") == true)
    }
}

private func parsedCommand(_ command: String) -> DwindleCommand? {
    parseCommand(command).cmdOrNil?.flatten().singleOrNil() as? DwindleCommand
}

private func parsedMessage(_ command: String) -> DwindleMessage? {
    parsedCommand(command)?.args.message.val
}

@MainActor
private func runCommand(_ command: String) async {
    let result = await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)
    assertEquals(result.exitCode.rawValue, 0, additionalMsg: "\(command): \(result.stderr)")
}
