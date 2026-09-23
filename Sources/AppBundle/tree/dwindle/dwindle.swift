import AppKit
import Common

// Hyprland-style dwindle layout: every new window splits the most recent window in two. It's built on the regular
// tiling tree: a dwindle workspace keeps every `tiles` container binary, and the weights keep their proportions.
// The reference implementation is Hyprland's src/layout/algorithm/tiled/dwindle/DwindleAlgorithm.cpp

extension Workspace {
    @MainActor var isDwindle: Bool { config.dwindle.enabled }

    /// The rect that the layout pass gives to the root tiling container
    @MainActor var dwindleRootRect: Rect {
        let monitor = workspaceMonitor
        let rect = monitor.visibleRectPaddedByOuterGaps
        return rect.copy(\.height, monitor.layoutHeight(of: rect))
    }
}

/// Hyprland's rule: split side by side when the area is wide enough, one above the other otherwise
@MainActor
func dwindleSplitOrientation(_ rect: Rect) -> Orientation {
    rect.width > rect.height * config.dwindle.splitWidthMultiplier ? .h : .v
}

/// Splits `total` between `weights`. Weights keep their proportions, like splits do in Hyprland. If a weight isn't
/// positive (e.g. `balance-sizes` followed by `resize` before a layout), falls back to the additive rule that the
/// layout pass uses outside of dwindle
func dwindleSizes(_ weights: [CGFloat], _ total: CGFloat) -> [CGFloat] {
    let sum = weights.reduce(0, +)
    if weights.allSatisfy({ $0.isFinite && $0 > 0 }) {
        return weights.map { $0 * total / sum }
    }
    let delta = (total - sum) / CGFloat(max(weights.count, 1))
    return weights.map { $0 + delta }
}

/// Rects of all tiling nodes of the workspace, derived from the tree the same way the layout pass does it. Inner gaps
/// are ignored, like in `lastAppliedLayoutVirtualRect`. Unlike the rects of the last layout pass, they are up to date
/// right after the tree changes, and they exist for invisible workspaces too
@MainActor
func dwindleRects(_ workspace: Workspace) -> [ObjectIdentifier: Rect] {
    var result: [ObjectIdentifier: Rect] = [:]
    workspace.rootTilingContainer.collectDwindleRects(workspace.dwindleRootRect, &result)
    return result
}

extension TreeNode {
    @MainActor
    fileprivate func collectDwindleRects(_ rect: Rect, _ result: inout [ObjectIdentifier: Rect]) {
        result[ObjectIdentifier(self)] = rect
        guard let container = self as? TilingContainer else { return }
        switch container.layout {
            case .accordion:
                for child in children {
                    child.collectDwindleRects(rect, &result)
                }
            case .tiles:
                // Without preserve-split, the orientation that is stored in the tree may be stale until the next
                // normalization. Derive it from the rect instead
                let orientation = config.dwindle.preserveSplit ? container.orientation : dwindleSplitOrientation(rect)
                for (child, childRect) in zip(children, container.dwindleChildRects(rect, orientation)) {
                    child.collectDwindleRects(childRect, &result)
                }
        }
    }
}

extension TilingContainer {
    /// Splits `rect` between the children along `orientation`, in proportion to their weights
    @MainActor
    func dwindleChildRects(_ rect: Rect, _ orientation: Orientation) -> [Rect] {
        let sizes = dwindleSizes(children.map { $0.getWeight(self.orientation) }, rect.getDimension(orientation))
        var offset: CGFloat = 0
        return sizes.map { size in
            defer { offset += size }
            return switch orientation {
                case .h: Rect(topLeftX: rect.topLeftX + offset, topLeftY: rect.topLeftY, width: size, height: rect.height)
                case .v: Rect(topLeftX: rect.topLeftX, topLeftY: rect.topLeftY + offset, width: rect.width, height: size)
            }
        }
    }
}

/// The node that dwindle treats as one tile: the outermost accordion around the window (like a Hyprland group), or
/// the window itself
@MainActor
func dwindleLeaf(_ window: Window) -> TreeNode {
    window.parentsWithSelf.last(where: { ($0 as? TilingContainer)?.layout == .accordion }) ?? window
}

/// The most recently used tiling window. Unlike `mostRecentWindowRecursive`, doesn't give up at an empty container,
/// which can be the most recent child for a moment (e.g. after the closed windows cache is partially restored)
@MainActor
func mostRecentTilingWindow(_ node: TreeNode) -> Window? {
    if let window = node as? Window { return window }
    for child in node.mruChildren {
        if let window = mostRecentTilingWindow(child) { return window }
    }
    return nil
}

private let dwindlePreselectKey = TreeNodeUserDataKey<CardinalDirection>(key: "dwindlePreselect")

extension Workspace {
    /// Set by `dwindle preselect`: the direction of the next split in the workspace, and the side of the new window
    @MainActor var dwindlePreselect: CardinalDirection? {
        get { getUserData(key: dwindlePreselectKey) }
        set {
            if let newValue {
                putUserData(key: dwindlePreselectKey, data: newValue)
            } else {
                cleanUserData(key: dwindlePreselectKey)
            }
        }
    }
}

extension TilingContainer {
    /// Like in Hyprland, the sizes stay where they are: the ratio belongs to the split, not to its halves
    @MainActor
    func swapDwindleHalves() {
        let weights = children.map { $0.getWeight(orientation) }
        swapChildren(0, 1)
        for (child, weight) in zip(children, weights) {
            child.setWeight(orientation, weight)
        }
    }

    /// Weights are pixel sizes along the orientation, so they are rescaled to the new axis, keeping their proportions
    @MainActor
    func setDwindleOrientation(_ newOrientation: Orientation, _ rect: Rect) {
        if newOrientation == orientation { return }
        let sizes = dwindleSizes(children.map { $0.getWeight(orientation) }, rect.getDimension(newOrientation))
        setOrientationForDwindle(newOrientation)
        for (child, size) in zip(children, sizes) {
            child.setWeight(newOrientation, size)
        }
    }
}
