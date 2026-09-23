@testable import AppBundle
import Common
import XCTest

@MainActor
final class FullscreenCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testTiledWindowHasTheSameGapOnAllEdges() async throws {
        config.gaps = Gaps(inner: .init(vertical: 13, horizontal: 13), outer: .init(left: 13, bottom: 13, top: 13, right: 13))
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)

        try await workspace.layoutWorkspace()
        let gaps = try await edgeGaps(window)
        assertEquals(gaps, [13, 13, 13, 13])
    }

    func testFullscreenWindowHasTheSameGapsAsTiledWindows() async throws {
        config.gaps = Gaps(inner: .init(vertical: 13, horizontal: 13), outer: .init(left: 13, bottom: 13, top: 13, right: 13))
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        assertEquals(window.focusWindow(), true)

        // The test monitor is 1920px wide. Half of the 1894px between the gaps is centered with 486.5px on both sides
        let cases: [(command: String, gaps: [CGFloat])] = [
            ("fullscreen on", [13, 13, 13, 13]),
            ("fullscreen on --width 0.5", [486.5, 13, 486.5, 13]),
        ]
        for (command, expectedGaps) in cases {
            await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)
            try await workspace.layoutWorkspace()
            let gaps = try await edgeGaps(window)
            assertEquals(gaps, expectedGaps, additionalMsg: command)
            await parseCommand("fullscreen off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        }
    }

    func testWindowsThatReachTheBottomOfTheMonitorStayOnePixelAboveIt() async throws {
        let workspace = Workspace.get(byName: name) // No gaps by default
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        assertEquals(window.focusWindow(), true)

        try await workspace.layoutWorkspace()
        let tiledGaps = try await edgeGaps(window)
        assertEquals(tiledGaps, [0, 0, 0, 1])

        config.gaps = Gaps(inner: .init(vertical: 13, horizontal: 13), outer: .init(left: 13, bottom: 13, top: 13, right: 13))
        await parseCommand("fullscreen --no-outer-gaps").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()
        let fullscreenGaps = try await edgeGaps(window)
        assertEquals(fullscreenGaps, [0, 0, 0, 1])
    }

    func testFullscreenDoesNothingForTheOnlyTilingWindow() async {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer) // Floating windows don't count
        assertEquals(window.focusWindow(), true)

        let result = await parseCommand("fullscreen").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(result.stderr, ["The window already takes up the whole workspace. Tip: use --fail-if-noop to exit with non-zero code"])
        assertEquals(window.isFullscreen, false)

        let failIfNoopResult = await parseCommand("fullscreen on --fail-if-noop").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(failIfNoopResult.exitCode.rawValue, 2)
        assertEquals(window.isFullscreen, false)
    }

    func testFullscreenWithWidthOrNoOuterGapsWorksForTheOnlyTilingWindow() async {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).rootTilingContainer)
        assertEquals(window.focusWindow(), true)

        for command in ["fullscreen --width 0.66", "fullscreen --no-outer-gaps"] {
            let result = await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)
            exitPointlessFullscreen()
            assertEquals(result.exitCode.rawValue, 0, additionalMsg: command)
            assertEquals(window.isFullscreen, true, additionalMsg: command)
            await parseCommand("fullscreen off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        }
    }

    func testFullscreenOffWorksForTheOnlyTilingWindow() async {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).rootTilingContainer)
        assertEquals(window.focusWindow(), true)
        await parseCommand("fullscreen --width 0.66").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(window.isFullscreen, true)

        let result = await parseCommand("fullscreen").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(window.isFullscreen, false)
    }

    func testFullscreenEndsWhenTheOtherWindowsClose() async {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let otherWindow = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        assertEquals(window.focusWindow(), true)
        await parseCommand("fullscreen").cmdOrDie.run(.defaultEnv, .emptyStdin)
        exitPointlessFullscreen()
        assertEquals(window.isFullscreen, true)

        otherWindow.closeAxWindow()
        exitPointlessFullscreen()
        assertEquals(window.isFullscreen, false)

        // So the next toggle centers the window instead of turning fullscreen off
        await parseCommand("fullscreen --width 0.66").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(window.isFullscreen, true)
        assertEquals(window.fullscreenWidth, 0.66)
    }

    func testFullscreenEndsWhenTheWindowMovesToAnEmptyWorkspace() async {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        assertEquals(window.focusWindow(), true)
        await parseCommand("fullscreen").cmdOrDie.run(.defaultEnv, .emptyStdin)

        await parseCommand("move-node-to-workspace empty").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(window.nodeWorkspace?.name, "empty")
        exitPointlessFullscreen()
        assertEquals(window.isFullscreen, false)
    }

    func testFullscreenWorksForTheOnlyFloatingWindow() async {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).floatingWindowsContainer)
        assertEquals(window.focusWindow(), true)

        await parseCommand("fullscreen").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(window.isFullscreen, true)
    }

    /// Distances from the window to the left, top, right, and bottom edges of the monitor
    private func edgeGaps(_ window: Window) async throws -> [CGFloat] {
        let rect = try await window.getAxRect(.nonCancellable).orDie()
        let monitor = window.nodeMonitor.orDie().visibleRect
        return [rect.minX - monitor.minX, rect.minY - monitor.minY, monitor.maxX - rect.maxX, monitor.maxY - rect.maxY]
    }
}
