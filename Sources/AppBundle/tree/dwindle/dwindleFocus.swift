import AppKit
import Common

@MainActor private var focusCounter = 0
private let focusOrderKey = TreeNodeUserDataKey<Int>(key: "dwindleFocusOrder")

extension Window {
    /// Hyprland picks among the windows in a direction by focus history. Stamped on every focus change
    @MainActor func stampFocusOrder() {
        focusCounter += 1
        putUserData(key: focusOrderKey, data: focusCounter)
    }
}

@MainActor private func focusOrder(_ window: Window) -> Int { window.getUserData(key: focusOrderKey) ?? 0 }

/// Whether `focus <direction>` and `swap <direction>` look for the window geometrically, like Hyprland does
@MainActor
func usesDwindleGeometry(_ window: Window, _ direction: CardinalDirection) -> Bool {
    window.nodeWorkspace?.isDwindle == true && window.parent is TilingContainer && !isDwindleStepWithinAccordion(window, direction)
}

/// Mirrors Hyprland's CWindowQuery::inDirection: the windows whose edge touches the window's edge on that side, and
/// that overlap it along that edge. The most recently focused one wins. Unlike the tree, it never picks a window
/// diagonally across a split. For an accordion, its most recent window
@MainActor
func dwindleWindowInDirection(_ window: Window, _ direction: CardinalDirection) -> Window? {
    guard let workspace = window.nodeWorkspace else { return nil }
    let rects = dwindleRects(workspace)
    let leaf = dwindleLeaf(window)
    guard let source = rects[ObjectIdentifier(leaf)] else { return nil }
    return dwindleLeaves(workspace.rootTilingContainer)
        .filter { $0 !== leaf && rects[ObjectIdentifier($0)].map { isNeighbor(source, $0, direction) } == true }
        .compactMap(mostRecentTilingWindow)
        .maxBy(focusOrder)
}

private func isNeighbor(_ source: Rect, _ candidate: Rect, _ direction: CardinalDirection) -> Bool {
    let gap = switch direction {
        case .left: source.minX - candidate.maxX
        case .right: candidate.minX - source.maxX
        case .up: source.minY - candidate.maxY
        case .down: candidate.minY - source.maxY
    }
    let overlap = switch direction.orientation {
        case .h: min(source.maxY, candidate.maxY) - max(source.minY, candidate.minY)
        case .v: min(source.maxX, candidate.maxX) - max(source.minX, candidate.minX)
    }
    return abs(gap) < 2 && overlap > 1 // Hyprland's thresholds
}
