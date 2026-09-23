import AppKit
import Common

extension Workspace {
    /// Keeps the tree of a dwindle workspace binary and, without preserve-split, lets every split pick its orientation
    /// from its shape. Runs on every normalization and right before the layout pass
    @MainActor
    func normalizeDwindleShape() {
        let root = rootTilingContainer
        let rect = dwindleRootRect
        let tilingMru = mostRecentTilingWindow(root)
        let workspaceMru = mostRecentWindowRecursive
        if root.foldIntoBinaryShape(rect) {
            // Folding binds nodes to new parents, which reorders MRU. Put the most recent windows back on top
            tilingMru?.markAsMostRecentChild()
            workspaceMru?.markAsMostRecentChild()
        }
        if !config.dwindle.preserveSplit {
            root.applyDwindleOrientations(rect)
        }
    }
}

extension TilingContainer {
    /// Normally, windows arrive one split at a time and every container stays binary. This is the safety net for
    /// everything else: dwindle turned on in config, `flatten-workspace-tree`, `layout tiles` on a big accordion, the
    /// closed windows cache. The first child stays, the rest move into a new container next to it, recursively, which
    /// makes a spiral. Returns whether anything was folded
    @MainActor
    fileprivate func foldIntoBinaryShape(_ rect: Rect) -> Bool {
        guard layout == .tiles else { return false } // Accordions are left alone, like Hyprland groups
        var folded = false
        if children.count > 2 {
            folded = true
            let savedMru = Array(mruChildren)
            let rest = Array(children.dropFirst())
            let half = rect.getDimension(orientation) / 2
            let wrapperRect: Rect = switch orientation {
                case .h: Rect(topLeftX: rect.topLeftX + half, topLeftY: rect.topLeftY, width: half, height: rect.height)
                case .v: Rect(topLeftX: rect.topLeftX, topLeftY: rect.topLeftY + half, width: rect.width, height: half)
            }
            let wrapperOrientation = dwindleSplitOrientation(wrapperRect)
            children[0].setWeight(orientation, half)
            let wrapper = TilingContainer(parent: self, adaptiveWeight: half, wrapperOrientation, .tiles, index: 1)
            let restWeight = wrapperRect.getDimension(wrapperOrientation) / CGFloat(rest.count)
            for node in rest { // Keep the order. Binding at later indices first would be out of range
                node.bind(to: wrapper, adaptiveWeight: restWeight, index: INDEX_BIND_LAST)
            }
            for node in savedMru.reversed() {
                node.markAsMostRecentChild()
            }
        }
        for (child, childRect) in zip(children, dwindleChildRects(rect, orientation)) {
            if let child = child as? TilingContainer, child.foldIntoBinaryShape(childRect) {
                folded = true
            }
        }
        return folded
    }

    /// Hyprland's default: the direction of a split isn't permanent, it follows the shape of the split area
    @MainActor
    fileprivate func applyDwindleOrientations(_ rect: Rect) {
        guard layout == .tiles else { return }
        let newOrientation = dwindleSplitOrientation(rect)
        if newOrientation != orientation {
            let sizes = dwindleSizes(children.map { $0.getWeight(orientation) }, rect.getDimension(newOrientation))
            setOrientationForDwindle(newOrientation)
            for (child, size) in zip(children, sizes) { // Weights are pixel sizes along the orientation
                child.setWeight(newOrientation, size)
            }
        }
        for (child, childRect) in zip(children, dwindleChildRects(rect, orientation)) {
            (child as? TilingContainer)?.applyDwindleOrientations(childRect)
        }
    }
}
