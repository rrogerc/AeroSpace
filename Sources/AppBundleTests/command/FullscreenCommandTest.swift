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

    /// Distances from the window to the left, top, right, and bottom edges of the monitor
    private func edgeGaps(_ window: Window) async throws -> [CGFloat] {
        let rect = try await window.getAxRect(.nonCancellable).orDie()
        let monitor = window.nodeMonitor.orDie().visibleRect
        return [rect.minX - monitor.minX, rect.minY - monitor.minY, monitor.maxX - rect.maxX, monitor.maxY - rect.maxY]
    }
}
