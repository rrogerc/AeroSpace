import AppKit
import Common

struct FullscreenCommand: Command {
    let args: FullscreenCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else {
            return .fail(io.err(noWindowIsFocused))
        }
        let newState: Bool = switch args.toggle {
            case .on: true
            case .off: false
            case .toggle: !window.isFullscreen
        }
        if newState == window.isFullscreen {
            switch args.failIfNoop {
                case true: return .fail
                case false:
                    let msg = newState
                        ? "Already fullscreen. Tip: use --fail-if-noop to exit with non-zero code"
                        : "Already not fullscreen. Tip: use --fail-if-noop to exit with non-zero code"
                    return .succ(io.err(msg))
            }
        }
        if newState && window.isPointlessFullscreen(width: args.width.map { CGFloat($0) }, noOuterGaps: args.noOuterGaps) {
            return switch args.failIfNoop {
                case true: .fail
                case false:
                    .succ(io.err("The window already takes up the whole workspace. Tip: use --fail-if-noop to exit with non-zero code"))
            }
        }
        window.isFullscreen = newState
        window.noOuterGapsInFullscreen = args.noOuterGaps
        window.fullscreenWidth = args.width.map { CGFloat($0) }

        // Focus on its own workspace
        window.markAsMostRecentChild()
        return .succ
    }
}

let noWindowIsFocused = "No window is focused"

extension Window {
    /// The only tiling window already takes up the whole workspace. Plain fullscreen (without --width and
    /// --no-outer-gaps) wouldn't change how it looks, it would only leave the window in a fullscreen mode that the
    /// next fullscreen toggle (e.g. --width) turns off
    @MainActor
    func isPointlessFullscreen(width: CGFloat?, noOuterGaps: Bool) -> Bool {
        width == nil && !noOuterGaps && nodeWorkspace?.rootTilingContainer.allLeafWindowsRecursive == [self]
    }
}

/// The fullscreen command doesn't enter pointless fullscreen, but fullscreen can become pointless later, e.g. when
/// the other windows of the workspace close, or when the fullscreen window moves to an empty workspace
@MainActor
func exitPointlessFullscreen() {
    for workspace in Workspace.all {
        for window in workspace.rootTilingContainer.allLeafWindowsRecursive where window.isFullscreen {
            if window.isPointlessFullscreen(width: window.fullscreenWidth, noOuterGaps: window.noOuterGapsInFullscreen) {
                window.isFullscreen = false
            }
        }
    }
}
