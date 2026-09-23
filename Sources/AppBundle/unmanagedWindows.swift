import AppKit
import Common

// Scoped refreshes only look at the apps that an event names. An app that isn't ready for AX when its window
// appears (e.g. a game that is still loading) may never be named again, and then its window is never managed.
// WindowServer knows every window without asking its app, so apps that show windows AeroSpace doesn't manage are
// rescanned on their own.

@MainActor private var unmanagedWindowRescans = UnmanagedWindowRescans()
@MainActor private var isUnmanagedWindowRescanScheduled = false

@MainActor func rescanAppsWithUnmanagedWindowsLater() {
    guard !isUnmanagedWindowRescanScheduled,
          let delay = unmanagedWindowRescans.nextDelay(unmanaged: unmanagedWindows())
    else { return }
    isUnmanagedWindowRescanScheduled = true
    Task.startUnstructured { @MainActor in
        try? await Task.sleep(for: delay)
        isUnmanagedWindowRescanScheduled = false
        let apps = unmanagedWindowRescans.startRescan(unmanaged: unmanagedWindows())
        if !apps.isEmpty && TrayMenuModel.shared.isEnabled {
            scheduleCancellableCompleteRefreshSession(.globalObserver("unmanagedWindows"), scope: .apps(apps))
        }
    }
}

/// Window ID -> pid
@MainActor private func unmanagedWindows() -> [UInt32: pid_t] {
    var result: [UInt32: pid_t] = [:]
    for window in getOnScreenNormalWindows() where window.pid != myPid && MacWindow.allWindowsMap[window.windowId] == nil {
        // Refreshes don't discover other kinds of apps anyway
        if NSRunningApplication(processIdentifier: window.pid)?.activationPolicy == .regular {
            result[window.windowId] = window.pid
        }
    }
    return result
}

/// Rescans back off per window. AX never reports some windows (e.g. invisible helper windows), so they're given up on
struct UnmanagedWindowRescans {
    static let maxRescans = 8 // Over ~30 seconds
    private var rescans: [UInt32: Int] = [:]

    /// nil if there's nothing left to rescan
    mutating func nextDelay(unmanaged: [UInt32: pid_t]) -> Duration? {
        rescans = rescans.filter { unmanaged[$0.key] != nil } // Forget windows that are gone, or managed by now
        guard let fewest = unmanaged.keys.map({ rescans[$0, default: 0] }).filter({ $0 < Self.maxRescans }).min() else { return nil }
        return min(.milliseconds(250) * (1 << fewest), .seconds(8))
    }

    /// Returns the apps to rescan
    mutating func startRescan(unmanaged: [UInt32: pid_t]) -> Set<pid_t> {
        var apps: Set<pid_t> = []
        for (windowId, pid) in unmanaged where rescans[windowId, default: 0] < Self.maxRescans {
            rescans[windowId, default: 0] += 1
            apps.insert(pid)
        }
        return apps
    }
}
