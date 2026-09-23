import CoreGraphics
import Foundation
import os

/// A workspace switch moves the windows of the next workspace on screen before it hides the windows of the previous one.
/// But apps move their windows at their own pace: a browser can take a frame longer than a terminal, even after it
/// accepts the move. Hiding right away would show the wallpaper in between, so hides wait until WindowServer shows
/// the revealed windows. A busy app can't hold the hides back for longer than `timeout`
final class PendingReveals: Sendable {
    static let shared = PendingReveals()

    private struct Reveal {
        let pid: pid_t
        let screen: CGRect
        let deadline: ContinuousClock.Instant
    }

    private let reveals = OSAllocatedUnfairLock(initialState: [UInt32: Reveal]())
    private let timeout: Duration
    private let windowServerBounds: @Sendable ([UInt32]) -> [UInt32: CGRect]?

    init(
        timeout: Duration = .milliseconds(250),
        windowServerBounds: @escaping @Sendable ([UInt32]) -> [UInt32: CGRect]? = { windowIds in
            getWindowServerWindows(windowIds).map { Dictionary($0.map { ($0.windowId, $0.bounds) }, uniquingKeysWith: { first, _ in first }) }
        },
    ) {
        self.timeout = timeout
        self.windowServerBounds = windowServerBounds
    }

    func add(_ windowId: UInt32, pid: pid_t, screen: Rect) {
        let reveal = Reveal(
            pid: pid,
            screen: CGRect(x: screen.topLeftX, y: screen.topLeftY, width: screen.width, height: screen.height),
            deadline: .now + timeout,
        )
        reveals.withLock { $0[windowId] = reveal }
    }

    /// The window is hidden again instead
    func remove(_ windowId: UInt32) {
        _ = reveals.withLock { $0.removeValue(forKey: windowId) }
    }

    /// Blocks the AX thread of the app that hides a window. Reveals of the same app aren't waited for:
    /// its AX thread has submitted them already
    func wait(for job: RunLoopJob, pid: pid_t) {
        let state = signposter.beginInterval("waitForReveals", "pid: \(pid, privacy: .public)")
        defer { signposter.endInterval("waitForReveals", state) }
        if pendingReveals(except: pid).isEmpty { return }
        // Otherwise, macOS may delay the timer below by tens of milliseconds, because AeroSpace is a background app
        ProcessInfo.processInfo.performActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Switching workspaces") { [self] in
            let deadline = ContinuousClock.now + timeout
            while !job.isCancelled && ContinuousClock.now < deadline {
                let pending = pendingReveals(except: pid)
                if pending.isEmpty { return }
                guard let bounds = windowServerBounds(Array(pending.keys)) else { return }
                // WindowServer doesn't know destroyed windows
                if pending.allSatisfy({ windowId, reveal in bounds[windowId].map { isOnScreen($0, reveal.screen) } ?? true }) { return }
                usleep(4000) // WindowServer queries aren't free, and a frame takes 16 ms anyway
            }
        }
    }

    private func pendingReveals(except pid: pid_t) -> [UInt32: Reveal] {
        let now = ContinuousClock.now
        return reveals.withLock { reveals in
            reveals = reveals.filter { $0.value.deadline > now }
            return reveals.filter { $0.value.pid != pid }
        }
    }
}

/// Hidden windows keep a one-point sliver on screen
private func isOnScreen(_ bounds: CGRect, _ screen: CGRect) -> Bool {
    let visible = bounds.intersection(screen)
    return !visible.isNull && visible.width > 1 && visible.height > 1
}
