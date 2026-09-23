import AppKit
import Common

/// Where a new tiling window goes in a dwindle workspace. Mirrors Hyprland's CDwindleAlgorithm::addTarget: the most
/// recent tiling window is split in two, side by side if it's wide enough, one above the other otherwise.
///
/// Unlike the non-dwindle placement, this changes the tree right away: the split window moves into a new container
/// that the new window must be bound to. The function is unsafe, the caller must bind the window with the result
@MainActor
func dwindleBindingDataForNewTilingWindow(_ workspace: Workspace) -> BindingData {
    // A refresh changes the tree after its own normalization (closed windows, other new windows), so the tree may
    // still have one-child and empty containers. They would make the rects below wrong
    workspace.normalizeContainers()
    let root = workspace.rootTilingContainer
    guard let target = mostRecentTilingWindow(root), let parent = target.parent as? TilingContainer else {
        return BindingData(parent: root, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }
    if dwindleLeaf(target) !== target {
        // Like new windows in a focused Hyprland group: they join the accordion instead of splitting it
        return BindingData(parent: parent, adaptiveWeight: WEIGHT_AUTO, index: target.ownIndex.orDie() + 1)
    }

    let targetRect = dwindleRects(workspace)[ObjectIdentifier(target)] ?? workspace.dwindleRootRect
    let orientation = dwindleSplitOrientation(targetRect)
    let newWindowFirst = config.dwindle.forceSplit == .left

    // Hyprland's split ratio is the share of the first child: 1 is 50/50, 1.2 is 60/40. Weights are pixel sizes
    let size = targetRect.getDimension(orientation)
    let firstSize = size * config.dwindle.defaultSplitRatio / 2
    let targetWeight = newWindowFirst ? size - firstSize : firstSize
    let newWindowWeight = size - targetWeight
    let newWindowIndex = newWindowFirst ? 0 : INDEX_BIND_LAST

    if parent.isRootContainer && parent.children.count == 1 {
        parent.setOrientationForDwindle(orientation)
        target.setWeight(orientation, targetWeight)
        return BindingData(parent: parent, adaptiveWeight: newWindowWeight, index: newWindowIndex)
    }
    let binding = target.unbindFromParent()
    let split = TilingContainer(parent: binding.parent, adaptiveWeight: binding.adaptiveWeight, orientation, .tiles, index: binding.index)
    target.bind(to: split, adaptiveWeight: targetWeight, index: 0)
    return BindingData(parent: split, adaptiveWeight: newWindowWeight, index: newWindowIndex)
}
