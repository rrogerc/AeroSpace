import AppKit
import Common

/// Where a new tiling window goes in a dwindle workspace. Mirrors Hyprland's CDwindleAlgorithm::addTarget: the most
/// recent tiling window is split in two, side by side if it's wide enough, one above the other otherwise.
///
/// With `focalPoint`, the tile closest to the point is split instead, and the window takes the half the point is in.
/// That's how Hyprland moves windows: `move` points just past the edge of the moved window.
///
/// Unlike the non-dwindle placement, this changes the tree right away: the split window moves into a new container
/// that the new window must be bound to. The function is unsafe, the caller must bind the window with the result
@MainActor
func dwindleBindingDataForNewTilingWindow(_ workspace: Workspace, focalPoint: CGPoint? = nil) -> BindingData {
    // A refresh changes the tree after its own normalization (closed windows, other new windows), so the tree may
    // still have one-child and empty containers. They would make the rects below wrong
    workspace.normalizeContainers()
    let root = workspace.rootTilingContainer
    let rects = dwindleRects(workspace)
    let target: TreeNode
    if let focalPoint {
        guard let closest = dwindleLeaves(root).minBy({ rects[ObjectIdentifier($0)].map(focalPoint.distance(toOuterFrame:)) ?? .infinity }) else {
            return BindingData(parent: root, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        }
        target = closest
    } else {
        guard let window = mostRecentTilingWindow(root), let parent = window.parent as? TilingContainer else {
            return BindingData(parent: root, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        }
        if dwindleLeaf(window) !== window {
            // Like new windows in a focused Hyprland group: they join the accordion instead of splitting it
            return BindingData(parent: parent, adaptiveWeight: WEIGHT_AUTO, index: window.ownIndex.orDie() + 1)
        }
        target = window
    }

    let targetRect = rects[ObjectIdentifier(target)] ?? workspace.dwindleRootRect
    let preselect = workspace.dwindlePreselect
    if !config.dwindle.permanentDirectionOverride {
        workspace.dwindlePreselect = nil
    }
    let orientation = preselect?.orientation ?? dwindleSplitOrientation(targetRect)
    let newWindowFirst: Bool = if let preselect {
        !preselect.isPositive
    } else if let focalPoint {
        orientation == .h ? focalPoint.x < targetRect.center.x : focalPoint.y < targetRect.center.y
    } else {
        config.dwindle.forceSplit == .left
    }

    // Hyprland's split ratio is the share of the first child: 1 is 50/50, 1.2 is 60/40. Weights are pixel sizes
    let size = targetRect.getDimension(orientation)
    let firstSize = size * config.dwindle.defaultSplitRatio / 2
    let targetWeight = newWindowFirst ? size - firstSize : firstSize
    let newWindowWeight = size - targetWeight
    let newWindowIndex = newWindowFirst ? 0 : INDEX_BIND_LAST

    if let parent = target.parent as? TilingContainer, parent.isRootContainer && parent.children.count == 1 {
        parent.setOrientationForDwindle(orientation)
        target.setWeight(orientation, targetWeight)
        return BindingData(parent: parent, adaptiveWeight: newWindowWeight, index: newWindowIndex)
    }
    let binding = target.unbindFromParent()
    let split = TilingContainer(parent: binding.parent, adaptiveWeight: binding.adaptiveWeight, orientation, .tiles, index: binding.index)
    target.bind(to: split, adaptiveWeight: targetWeight, index: 0)
    return BindingData(parent: split, adaptiveWeight: newWindowWeight, index: newWindowIndex)
}

/// The tiles that dwindle splits: windows, and accordions as a whole
@MainActor
private func dwindleLeaves(_ node: TreeNode) -> [TreeNode] {
    switch node.nodeCases {
        case .window: [node]
        case .tilingContainer(let container) where container.layout == .accordion: container.isEffectivelyEmpty ? [] : [container]
        default: node.children.flatMap(dwindleLeaves)
    }
}
