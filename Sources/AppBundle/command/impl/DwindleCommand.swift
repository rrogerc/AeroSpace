import AppKit
import Common

/// Hyprland's dwindle layout messages. See CDwindleAlgorithm::layoutMsg in Hyprland's DwindleAlgorithm.cpp
struct DwindleCommand: Command {
    let args: DwindleCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        let workspace = target.workspace
        guard workspace.isDwindle else {
            return .fail(io.err("The dwindle layout isn't enabled. See 'dwindle.enabled' in the config"))
        }
        if case .preselect(let direction) = args.message.val {
            workspace.dwindlePreselect = direction
            return .succ
        }
        guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
        guard window.parent is TilingContainer else { return .fail(io.err("The window isn't tiling")) }
        if window.isFullscreen { // Like in Hyprland
            return .fail(io.err("The window is fullscreen"))
        }
        let leaf = dwindleLeaf(window)
        if args.message.val == .movetoroot {
            return moveToRoot(leaf, workspace, stable: !args.unstable, io)
        }
        guard let split = leaf.parent as? TilingContainer, split.layout == .tiles, split.children.count == 2 else {
            return .fail(io.err("The window isn't one half of a split"))
        }
        let rect = dwindleRects(workspace)[ObjectIdentifier(split)] ?? workspace.dwindleRootRect
        switch args.message.val {
            case .togglesplit:
                guard config.dwindle.preserveSplit else {
                    return .fail(io.err("togglesplit requires 'dwindle.preserve-split = true'. Otherwise, the direction of a split follows its shape"))
                }
                split.setDwindleOrientation(split.orientation.opposite, rect)
            case .swapsplit:
                split.swapDwindleHalves()
            case .rotatesplit(let degrees):
                let quarterTurns = (degrees / 90 % 4 + 4) % 4
                // A clockwise quarter turn moves the left half to the top, and the top half to the right
                if quarterTurns == 2 || quarterTurns == 1 && split.orientation == .v || quarterTurns == 3 && split.orientation == .h {
                    split.swapDwindleHalves()
                }
                if quarterTurns % 2 == 1 {
                    split.setDwindleOrientation(split.orientation.opposite, rect)
                }
            case .splitratio(let change):
                let total = rect.getDimension(split.orientation)
                let firstSize = dwindleSizes(split.children.map { $0.getWeight(split.orientation) }, total)[0]
                let ratio = switch change {
                    case .set(let ratio): ratio
                    case .add(let delta): 2 * firstSize / total + delta
                }
                let newFirstSize = total * CGFloat(ratio).coerce(in: 0.1 ... 1.9) / 2
                split.children[0].setWeight(split.orientation, newFirstSize)
                split.children[1].setWeight(split.orientation, total - newFirstSize)
            case .preselect, .movetoroot:
                die("Handled above")
        }
        return .succ
    }
}

/// Hyprland's movetoroot: the node swaps places with the half of the root split that doesn't contain it
@MainActor
private func moveToRoot(_ node: TreeNode, _ workspace: Workspace, stable: Bool, _ io: CmdIo) -> BinaryExitCode {
    let root = workspace.rootTilingContainer
    guard root.layout == .tiles, root.children.count == 2 else {
        return .fail(io.err("The workspace isn't split in two"))
    }
    guard let ancestor = node.parentsWithSelf.first(where: { $0.parent === root }), ancestor !== node else {
        return .fail(io.err("The window is already one half of the workspace"))
    }
    let otherHalf = root.children[0] === ancestor ? root.children[1] : root.children[0]
    let nodeBinding = node.unbindFromParent()
    let otherHalfBinding = otherHalf.unbindFromParent()
    otherHalf.bind(to: nodeBinding.parent, adaptiveWeight: nodeBinding.adaptiveWeight, index: nodeBinding.index)
    node.bind(to: otherHalfBinding.parent, adaptiveWeight: otherHalfBinding.adaptiveWeight, index: otherHalfBinding.index)
    if stable { // The node stays on the side of the screen where it was
        root.swapDwindleHalves()
    }
    return .succ
}
