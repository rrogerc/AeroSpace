import AppKit
import Common

/// `move` in a dwindle workspace. Mirrors Hyprland's CDwindleAlgorithm::moveTargetInDirection: the window leaves its
/// split, and splits the window just past its edge in the direction of the move, taking the half on that side
@MainActor
func dwindleMove(_ window: Window, _ workspace: Workspace, _ direction: CardinalDirection, _ args: MoveCmdArgs, _ io: CmdIo) -> BinaryExitCode {
    // Inside an accordion, moving along it reorders the windows, like outside of dwindle
    if let accordion = window.parent as? TilingContainer, accordion.layout == .accordion, accordion.orientation == direction.orientation,
       let index = window.ownIndex, accordion.children.indices.contains(index + direction.focusOffset)
    {
        accordion.swapChildren(index, index + direction.focusOffset)
        return .succ
    }

    // A window in an accordion leaves it, starting from where the accordion is
    let leaf = dwindleLeaf(window)
    let rects = dwindleRects(workspace)
    guard let rect = rects[ObjectIdentifier(leaf)] else { return .fail(io.err(bugPrompt())) }
    let focalPoint: CGPoint = switch direction {
        case .left: CGPoint(x: rect.minX - 1, y: rect.center.y)
        case .right: CGPoint(x: rect.maxX + 1, y: rect.center.y)
        case .up: CGPoint(x: rect.center.x, y: rect.minY - 1)
        case .down: CGPoint(x: rect.center.x, y: rect.maxY + 1)
    }

    if !workspace.dwindleRootRect.contains(focalPoint) {
        return dwindleMoveOutOfWorkspace(window, workspace, direction, focalPoint, args, io)
    }

    // Moving toward the other half of the split swaps the two halves, and the split gets the default ratio again.
    // That's Hyprland's override direction for the case when the partner is a single window
    if leaf === window, let split = window.parent as? TilingContainer, split.layout == .tiles, split.children.count == 2,
       split.orientation == direction.orientation, window.ownIndex == (direction.isPositive ? 0 : 1),
       let partner = split.children.first(where: { $0 !== window }), partner is Window || (partner as? TilingContainer)?.layout == .accordion
    {
        split.swapChildren(0, 1)
        let size = (rects[ObjectIdentifier(split)] ?? rect).getDimension(split.orientation)
        let firstSize = size * config.dwindle.defaultSplitRatio / 2
        split.children[0].setWeight(split.orientation, firstSize)
        split.children[1].setWeight(split.orientation, size - firstSize)
        return .succ
    }

    window.unbindFromParent()
    let data = dwindleBindingDataForNewTilingWindow(workspace, focalPoint: focalPoint)
    window.bind(to: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
    return .succ
}

@MainActor
private func dwindleMoveOutOfWorkspace(
    _ window: Window,
    _ workspace: Workspace,
    _ direction: CardinalDirection,
    _ focalPoint: CGPoint,
    _ args: MoveCmdArgs,
    _ io: CmdIo,
) -> BinaryExitCode {
    if args.boundaries == .allMonitorsOuterFrame,
       let (monitors, index) = window.nodeMonitor?.findRelativeMonitor(inDirection: direction),
       let monitor = monitors.getOrNil(atIndex: index)
    {
        // Like Hyprland: the window lands next to the window that is just across the edge of the monitor
        return moveWindowToWorkspace(
            window,
            monitor.activeWorkspace,
            io,
            focusFollowsWindow: focus.windowOrNil == window,
            failIfNoop: false,
            dwindleFocalPoint: focalPoint,
        )
    }
    switch args.boundariesAction {
        case .stop: return .succ
        case .fail: return .fail
        case .createImplicitContainer: // The window becomes one half of the workspace, on the side of the move
            createImplicitContainerAndMoveWindow(window, workspace, direction)
            return .succ
    }
}
