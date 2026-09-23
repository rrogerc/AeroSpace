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
        // The only tiling window already takes up the whole workspace. Plain fullscreen wouldn't change how it looks,
        // it would only leave the window in a fullscreen mode that the next fullscreen toggle (e.g. --width) turns off
        let isOnlyTilingWindow = target.workspace.rootTilingContainer.allLeafWindowsRecursive == [window]
        if newState && args.width == nil && !args.noOuterGaps && isOnlyTilingWindow {
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
