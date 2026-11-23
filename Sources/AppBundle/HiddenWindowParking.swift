import Common
import CoreGraphics
import Foundation
import PrivateApi

protocol HiddenWindowParkingDriver: Sendable {
    func display() -> NativeDisplaySpaces?
    func owners(_ ids: [UInt32]) -> [UInt32: Int32]?
    func isAppTerminated(_ pid: Int32) -> Bool
    func membership(_ id: UInt32) -> [UInt64]?
    func onScreenWindows(_ ids: [UInt32]) -> Set<UInt32>?
    func create(_ name: String) -> UInt64
    func hide(_ ids: [UInt32], in group: WorkspaceVisibilityGroup) -> Bool
    func reveal(_ ids: [UInt32], from group: WorkspaceVisibilityGroup, home: UInt64) -> Bool
    func restore(_ groups: [WorkspaceVisibilityGroup], home: UInt64) -> Bool
    /// See ActiveLook.events
    func lookActive(_ id: UInt32, pid: Int32) -> Bool
    /// nil if the windows of two workspaces can't change places in one transaction
    func createSwapGroups(home: UInt64) -> WindowSwapGroups?
    /// `reveal` joins the desktop unseen, and `hide` stays on it as it is
    func stage(reveal: [UInt32], hide: [UInt32], parking: WorkspaceVisibilityGroup, swap: WindowSwapGroups, home: UInt64) -> Bool
    /// One transaction: the staged windows to reveal show up, and the ones to hide are gone
    func commit(_ swap: WindowSwapGroups) -> Bool
    /// The revealed windows end up on the desktop only, and the hidden ones in `parking` only. Nothing of it shows
    func settle(reveal: [UInt32], hide: [UInt32], parking: WorkspaceVisibilityGroup, swap: WindowSwapGroups, home: UInt64) -> Bool
}

/// A workspace switch used to reveal the windows of the next workspace, and to hide the windows of the previous one
/// once the next ones were on screen. A frame in between had both, with their shadows on top of each other: the gaps
/// went dark for that frame, in about half of the switches.
///
/// No transaction of this process can move a window of another app between the desktop and a group, so the two steps
/// can't be one. But while a group is shown, its alpha applies to its windows, also to a window that is on the
/// desktop as well, and the alpha of a group of our own does change in a transaction. So besides the hidden group
/// that parks the windows, there are two shown groups, both empty between switches:
/// - `arriving` has alpha 0. The windows of the next workspace join it, and the desktop after that. Nobody sees
///   them while WindowManager takes its few milliseconds to show them
/// - `leaving` has alpha 1. The windows of the previous workspace join it, and stay on the desktop as they are
///
/// Then one transaction swaps the two alphas, and after it the windows go where they would be without all this:
/// the revealed ones on the desktop only, the hidden ones in the parking group only
struct WindowSwapGroups: Equatable, Sendable {
    let arriving: WorkspaceVisibilityGroup
    let leaving: WorkspaceVisibilityGroup
}

struct WindowServerHiddenParkingDriver: HiddenWindowParkingDriver {
    func display() -> NativeDisplaySpaces? {
        guard AeroSpaceWorkspaceGroupsAvailable(), let raw = AeroSpaceCopyNativeDisplays(),
              let layout = NativeDisplaySpaces.decode(raw), layout.current == AeroSpaceActiveNativeSpace()
        else { return nil }
        return layout
    }

    func owners(_ ids: [UInt32]) -> [UInt32: Int32]? {
        if ids.isEmpty { return [:] }
        return getWindowServerWindows(ids)?.reduce(into: [:]) { $0[$1.windowId] = $1.pid }
    }

    func isAppTerminated(_ pid: Int32) -> Bool {
        // Signal 0 only checks existence. Permission errors do not prove exit.
        kill(pid, 0) == -1 && errno == ESRCH
    }

    func membership(_ id: UInt32) -> [UInt64]? {
        (AeroSpaceCopyAllWindowSpaces(id) as? [NSNumber])?.map(\.uint64Value)
    }

    func onScreenWindows(_ ids: [UInt32]) -> Set<UInt32>? {
        guard let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let requested = Set(ids)
        return Set(records.compactMap { $0[kCGWindowNumber as String] as? UInt32 }.filter { requested.contains($0) })
    }

    func create(_ name: String) -> UInt64 { AeroSpaceCreateWorkspaceGroup(name as CFString) }

    func hide(_ ids: [UInt32], in group: WorkspaceVisibilityGroup) -> Bool {
        unsafe ids.withUnsafeBufferPointer {
            unsafe AeroSpaceAssignWindowsToWorkspaceGroup($0.baseAddress, $0.count, group.id, group.name as CFString)
        }
    }

    func reveal(_ ids: [UInt32], from group: WorkspaceVisibilityGroup, home: UInt64) -> Bool {
        unsafe ids.withUnsafeBufferPointer {
            unsafe AeroSpaceReturnWindowsFromWorkspaceGroup($0.baseAddress, $0.count, group.id, group.name as CFString, home)
        }
    }

    func restore(_ groups: [WorkspaceVisibilityGroup], home: UInt64) -> Bool {
        AeroSpaceRestoreWorkspaceGroups(names(groups), home)
    }

    func lookActive(_ id: UInt32, pid: Int32) -> Bool { AeroSpaceSetAppLooksActive(pid, id, true) == .success }

    func createSwapGroups(home: UInt64) -> WindowSwapGroups? {
        guard AeroSpaceWindowSwapAvailable() else { return nil }
        let groups = ["arriving", "leaving"].map { role in
            let name = "AeroSpace \(role) windows \(getuid()) \(getpid()) \(UUID().uuidString)"
            return WorkspaceVisibilityGroup(id: create(name), name: name)
        }
        let created = groups.filter { $0.id != 0 }
        if created.count == 2, AeroSpacePrepareWindowSwapGroups(groups[0].id, groups[1].id, names(groups)) {
            return WindowSwapGroups(arriving: groups[0], leaving: groups[1])
        }
        // Nothing is in them yet: this only removes the groups
        if !created.isEmpty { _ = restore(created, home: home) }
        return nil
    }

    func stage(reveal: [UInt32], hide: [UInt32], parking: WorkspaceVisibilityGroup, swap: WindowSwapGroups, home: UInt64) -> Bool {
        AeroSpaceStageWindowSwap(numbers(reveal), numbers(hide), spaces(parking: parking, swap: swap, home: home))
    }

    func commit(_ swap: WindowSwapGroups) -> Bool {
        AeroSpaceCommitWindowSwap(AeroSpaceWindowSwapSpaces(home: 0, parking: 0, arriving: swap.arriving.id, leaving: swap.leaving.id))
    }

    func settle(reveal: [UInt32], hide: [UInt32], parking: WorkspaceVisibilityGroup, swap: WindowSwapGroups, home: UInt64) -> Bool {
        AeroSpaceSettleWindowSwap(numbers(reveal), numbers(hide), spaces(parking: parking, swap: swap, home: home))
    }

    private func numbers(_ ids: [UInt32]) -> CFArray { ids.map { NSNumber(value: $0) } as CFArray }

    private func spaces(parking: WorkspaceVisibilityGroup, swap: WindowSwapGroups, home: UInt64) -> AeroSpaceWindowSwapSpaces {
        AeroSpaceWindowSwapSpaces(home: home, parking: parking.id, arriving: swap.arriving.id, leaving: swap.leaving.id)
    }

    private func names(_ groups: [WorkspaceVisibilityGroup]) -> CFDictionary {
        Dictionary(uniqueKeysWithValues: groups.map { (NSNumber(value: $0.id), $0.name) }) as CFDictionary
    }
}

/// Only inactive windows enter the hidden group. Visible windows retain the
/// managed desktop membership needed for normal AppKit pointer tracking.
actor HiddenWindowParkingWorker {
    private struct Home {
        let id: UInt64
        let display: String
    }

    private struct Entry {
        let window: NativeVisibilityWindow
        let gate: NativeVisibilityGate
    }

    /// The app was asked to make a window its main window (ActiveLook.mainWindow), and has until `deadline` to do it
    private struct MainWindowRequest {
        let job: RunLoopJob
        let deadline: ContinuousClock.Instant
    }

    private let driver: any HiddenWindowParkingDriver
    private let didRecover: @Sendable () -> Void
    private let retryDelay: Duration
    private let mainWindowTimeout: Duration
    private var home: Home?
    private var group: WorkspaceVisibilityGroup?
    /// They exist for as long as `group` does. nil if the windows of two workspaces can't be swapped
    private var swapGroups: WindowSwapGroups?
    private var entries: [UInt32: Entry] = [:]
    private var latestRequest: UInt64 = 0
    private var terminating = false
    private var suspended = false
    private var recovering = false
    private var clearHomeAfterRecovery = false
    private var retryAfter = ContinuousClock.now
    private var restartDelay: Duration = .zero
    private var recoveryTask: Task<Void, Never>?

    init(
        driver: any HiddenWindowParkingDriver = WindowServerHiddenParkingDriver(),
        retryDelay: Duration = .seconds(1),
        mainWindowTimeout: Duration = .milliseconds(50),
        didRecover: @escaping @Sendable () -> Void = {
            Task.startUnstructured { @MainActor in await recoverNativeWorkspaceVisibility() }
        },
    ) {
        self.driver = driver
        self.retryDelay = retryDelay
        self.mainWindowTimeout = mainWindowTimeout
        self.didRecover = didRecover
    }

    func context() -> (home: UInt64?, group: UInt64?, swapGroups: [UInt64]) {
        (home?.id, group?.id, swapGroups.map { [$0.arriving.id, $0.leaving.id] } ?? [])
    }

    private func accept(_ request: UInt64?) -> Bool {
        guard let request else { return true }
        guard request > latestRequest else { return false }
        latestRequest = request
        return true
    }

    private var currentPlan: NativeVisibilityPlan {
        if recovering { return .recovering }
        if suspended { return .suspended }
        if group != nil || !entries.isEmpty {
            return .native(entries.mapValues { ($0.window.pid, $0.gate) })
        }
        return .offscreen
    }

    func apply(_ windows: [NativeVisibilityWindow], request: UInt64? = nil, focus: RevealedFocus? = nil) -> NativeVisibilityPlan {
        guard !Task.isCancelled, !terminating, accept(request), !recovering else { return currentPlan }
        // Workspace commands routinely cancel background refreshes. Once this
        // synchronous transition starts, finish observing and recording its moves:
        // recovery would reveal every parked workspace just because it was interrupted.
        let previousGates = entries.mapValues(\.gate)
        var validated = false
        // Cancellation must not publish new acknowledgements, but an unchanged
        // window can still have a focus job queued against its existing gate.
        // Keep that gate only after this request validated its membership and
        // checked that cancellation did not accompany a native desktop switch.
        defer {
            if Task.isCancelled {
                let keepExisting = validated && home.map(isActive) == true
                for (id, entry) in entries where !keepExisting || previousGates[id] !== entry.gate {
                    entry.gate.cancel()
                }
            }
        }
        guard let layout = driver.display() else {
            suspended = home != nil
            beginRecovery(clearHome: false)
            return currentPlan
        }
        let normalSpaces = layout.spaces.filter { $0.type == 0 }
        if let home, !normalSpaces.contains(where: { $0.id == home.id }) || home.display != layout.display {
            // Removing our original desktop requires restoring its parked windows
            // before adopting a surviving desktop. Never create another Space.
            if group != nil {
                beginRecovery(clearHome: false, restartDelay: .zero)
                return currentPlan
            }
            self.home = replacementHome(layout)
        }
        if home == nil, normalSpaces.contains(where: { $0.id == layout.current }) {
            home = Home(id: layout.current, display: layout.display)
        }
        guard let home else {
            suspended = true
            return currentPlan
        }
        suspended = layout.current != home.id
        if suspended {
            beginRecovery(clearHome: false, restartDelay: .zero)
            return currentPlan
        }
        guard ContinuousClock.now >= retryAfter else { return .offscreen }
        guard Set(windows.map(\.id)).count == windows.count,
              windows.allSatisfy({ $0.id != 0 && $0.pid > 0 })
        else {
            beginRecovery(clearHome: false)
            return currentPlan
        }
        let requested = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        guard var owners = driver.owners(Array(Set(windows.map(\.id) + Array(entries.keys)))) else {
            beginRecovery(clearHome: false)
            return currentPlan
        }
        for entry in entries.values where requested[entry.window.id]?.pid != entry.window.pid {
            entry.gate.cancel()
            if owners[entry.window.id] == entry.window.pid, let group, !driver.isAppTerminated(entry.window.pid) {
                // AX can retire a closing tile before WindowServer drops its
                // owner. Only a window still parked here needs restoration;
                // restoring the group for a visible tile flashes other workspaces.
                // An unknown membership must still take the safe recovery path.
                if let membership = driver.membership(entry.window.id), !membership.contains(group.id) { continue }
                beginRecovery(clearHome: false, restartDelay: .zero)
                return currentPlan
            }
        }

        var memberships: [UInt32: [UInt64]] = [:]
        var hide: [UInt32] = []
        var reveal: [UInt32] = []
        for window in windows where owners[window.id] == window.pid {
            guard let membership = driver.membership(window.id) else {
                beginRecovery(clearHome: false)
                return currentPlan
            }
            memberships[window.id] = membership
            if window.visible, let group, membership == [group.id] { reveal.append(window.id) }
            if !window.visible, membership == [home.id] { hide.append(window.id) }
        }
        // Cancel outgoing frame/focus waiters before submitting any transition.
        for (id, entry) in entries where requested[id] != entry.window ||
            owners[id] != entry.window.pid || memberships[id] != [home.id]
        {
            entry.gate.cancel()
        }
        if group == nil, !hide.isEmpty {
            let name = "AeroSpace hidden windows \(getuid()) \(getpid()) \(UUID().uuidString)"
            let id = driver.create(name)
            guard id != 0 else {
                beginRecovery(clearHome: false)
                return currentPlan
            }
            group = WorkspaceVisibilityGroup(id: id, name: name)
            // They're shown here, long before the first swap: a window that joins a group right after the
            // transaction that showed the group gets there a frame later
            swapGroups = driver.createSwapGroups(home: home.id)
        }
        if (!hide.isEmpty || !reveal.isEmpty), !isActive(home) {
            suspended = true
            beginRecovery(clearHome: false, restartDelay: .zero)
            return currentPlan
        }
        // The window that gets the focus arrives with its active look: see ActiveLook
        let mainWindow = focus.flatMap { reveal.contains($0.windowId) && owners[$0.windowId] == $0.pid ? showAsActive($0) : nil }
        if let group, let swapGroups, !reveal.isEmpty, !hide.isEmpty {
            guard swap(reveal: reveal, hide: hide, parking: group, groups: swapGroups, home: home, mainWindow: mainWindow) else { return currentPlan }
            for id in reveal { memberships[id] = [home.id] }
            for id in hide { memberships[id] = [group.id] }
        } else {
            // Without a swap: reveal before hiding the outgoing workspace, without activating either
            // app. Both operations acknowledge membership before releasing any gate.
            waitFor(mainWindow)
            if let group, !reveal.isEmpty {
                guard driver.reveal(reveal, from: group, home: home.id) else {
                    beginRecovery(clearHome: false)
                    return currentPlan
                }
                for id in reveal { memberships[id] = [home.id] }
            }
            if !reveal.isEmpty, !hide.isEmpty { waitForOnScreenReveals(reveal, home: home) }
            if !hide.isEmpty, !isActive(home) {
                suspended = true
                beginRecovery(clearHome: false, restartDelay: .zero)
                return currentPlan
            }
            if let group, !hide.isEmpty {
                guard driver.hide(hide, in: group) else {
                    beginRecovery(clearHome: false)
                    return currentPlan
                }
                for id in hide { memberships[id] = [group.id] }
            }
        }
        if !hide.isEmpty || !reveal.isEmpty {
            guard let finalLayout = driver.display(), finalLayout.display == home.display,
                  finalLayout.current == home.id,
                  finalLayout.spaces.contains(where: { $0.id == home.id && $0.type == 0 })
            else {
                suspended = true
                beginRecovery(clearHome: false, restartDelay: .zero)
                return currentPlan
            }
            guard let observedOwners = driver.owners(windows.map(\.id)) else {
                beginRecovery(clearHome: false)
                return currentPlan
            }
            owners = observedOwners
            for window in windows where owners[window.id] == window.pid {
                guard let membership = driver.membership(window.id) else {
                    beginRecovery(clearHome: false)
                    return currentPlan
                }
                if (hide.contains(window.id) || reveal.contains(window.id)), membership != memberships[window.id] {
                    beginRecovery(clearHome: false)
                    return currentPlan
                }
                memberships[window.id] = membership
            }
        }
        var next: [UInt32: Entry] = [:]
        for window in windows {
            let ready = window.visible && owners[window.id] == window.pid && memberships[window.id] == [home.id]
            if let previous = entries[window.id], previous.window == window, ready, previous.gate.isReady {
                next[window.id] = previous
            } else {
                entries[window.id]?.gate.cancel()
                let gate = NativeVisibilityGate()
                if ready { gate.complete(true) } else { gate.cancel() }
                next[window.id] = Entry(window: window, gate: gate)
            }
        }
        entries = next
        validated = true
        return .native(entries.mapValues { ($0.window.pid, $0.gate) })
    }

    /// The returned request is nil if there's no answer of the app to wait for
    private func showAsActive(_ focus: RevealedFocus) -> MainWindowRequest? {
        let state = signposter.beginInterval("showAsActive", "window: \(focus.windowId, privacy: .public)")
        defer { signposter.endInterval("showAsActive", state) }
        switch focus.look {
            // The app reads the events while the window is on its way to the screen: there's nothing to wait for
            case .events:
                focus.looksActive = driver.lookActive(focus.windowId, pid: focus.pid)
                return nil
            // The window that is leaving has the active look until the new one is on screen, so the new one must
            // not show up before the app has answered. But a busy app mustn't hold the switch back: without the
            // answer the window just arrives with the look of an inactive window, as it used to
            case .mainWindow(let send): return MainWindowRequest(job: send(), deadline: .now + mainWindowTimeout)
        }
    }

    private func waitFor(_ mainWindow: MainWindowRequest?) {
        guard let mainWindow, !mainWindow.job.isComplete else { return }
        let state = signposter.beginInterval("awaitMainWindow")
        defer { signposter.endInterval("awaitMainWindow", state) }
        ProcessInfo.processInfo.performActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Switching workspaces") {
            while !mainWindow.job.isComplete && ContinuousClock.now < mainWindow.deadline { usleep(500) }
        }
    }

    /// Shows `reveal` and hides `hide` in the same frame: see WindowSwapGroups. false if the worker recovers instead
    private func swap(
        reveal: [UInt32], hide: [UInt32], parking: WorkspaceVisibilityGroup, groups: WindowSwapGroups, home: Home,
        mainWindow: MainWindowRequest?,
    ) -> Bool {
        var state = signposter.beginInterval("stageWindowSwap")
        let staged = driver.stage(reveal: reveal, hide: hide, parking: parking, swap: groups, home: home.id)
        signposter.endInterval("stageWindowSwap", state)
        guard staged else {
            beginRecovery(clearHome: false)
            return false
        }
        // The app had the time of the staging to answer. Its window isn't seen before the swap
        waitFor(mainWindow)
        // The windows are on the desktop by now, but WindowManager shows them when it gets to it. Until then a
        // swap would show the wallpaper. Asking takes a millisecond, so a short pause doesn't ask much more often
        waitForOnScreenReveals(reveal, home: home, pollMicroseconds: 500)
        guard isActive(home) else {
            suspended = true
            beginRecovery(clearHome: false, restartDelay: .zero)
            return false
        }
        state = signposter.beginInterval("commitWindowSwap")
        let committed = driver.commit(groups)
        signposter.endInterval("commitWindowSwap", state)
        // The hidden windows are still on the desktop, unseen, and the revealed ones still in their group. That
        // ends here, before anybody focuses a revealed window: as long as the window that had the keyboard is on
        // the desktop, macOS draws the window that gets the keyboard as inactive at first (a frame or more, in 27
        // of 40 switches between two test windows)
        state = signposter.beginInterval("settleWindowSwap")
        let settled = committed && driver.settle(reveal: reveal, hide: hide, parking: parking, swap: groups, home: home.id)
        signposter.endInterval("settleWindowSwap", state)
        if !settled { beginRecovery(clearHome: false) }
        return settled
    }

    private func waitForOnScreenReveals(_ ids: [UInt32], home: Home, pollMicroseconds: UInt32 = 4000) {
        let state = signposter.beginInterval("waitForNativeReveals")
        defer { signposter.endInterval("waitForNativeReveals", state) }
        let wanted = Set(ids)
        let deadline = ContinuousClock.now + .milliseconds(250)
        var homeChecked: ContinuousClock.Instant? = nil
        // Membership can change before WindowServer includes the incoming window
        // on screen. This observation narrows that gap, but does not prove that
        // pixels have been presented. Keep focus and frame gates closed until hiding.
        ProcessInfo.processInfo.performActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Switching workspaces") { [self] in
            while !Task.isCancelled && ContinuousClock.now < deadline {
                guard let visible = driver.onScreenWindows(ids) else { return }
                if wanted.isSubset(of: visible) { return }
                // Not more often than it used to be asked: it takes two requests to WindowServer
                if homeChecked.map({ ContinuousClock.now - $0 >= .milliseconds(4) }) ?? true {
                    guard isActive(home) else { return }
                    homeChecked = .now
                }
                usleep(pollMicroseconds)
            }
        }
    }

    @discardableResult
    func stop(retry: Bool = true, restartDelay: Duration = .seconds(5), request: UInt64? = nil) -> Bool {
        guard accept(request) else { return !recovering && group == nil }
        if !retry { terminating = true }
        return beginRecovery(clearHome: true, retry: retry, restartDelay: restartDelay)
    }

    @discardableResult
    private func beginRecovery(clearHome: Bool, retry: Bool = true, restartDelay: Duration = .seconds(5)) -> Bool {
        for entry in entries.values { entry.gate.cancel() }
        entries = [:]
        clearHomeAfterRecovery = clearHomeAfterRecovery || clearHome
        if !recovering { self.restartDelay = restartDelay }
        guard group != nil else {
            recovering = false
            if clearHomeAfterRecovery { home = nil; suspended = false }
            clearHomeAfterRecovery = false
            retryAfter = .now.advanced(by: restartDelay)
            return true
        }
        recovering = true
        if !retry {
            recoveryTask?.cancel()
            recoveryTask = nil
            return retryRecovery(notify: false)
        }
        guard recoveryTask == nil else { return false }
        if retryRecovery() { return true }
        recoveryTask = Task.startUnstructured { await self.recoverUntilRemoved() }
        return false
    }

    private func replacementHome(_ layout: NativeDisplaySpaces) -> Home? {
        let normal = layout.spaces.filter { $0.type == 0 }
        return (normal.first(where: { $0.id == layout.current }) ?? normal.first)
            .map { Home(id: $0.id, display: layout.display) }
    }

    private func isActive(_ home: Home) -> Bool {
        guard let layout = driver.display() else { return false }
        return layout.display == home.display && layout.current == home.id &&
            layout.spaces.contains(where: { $0.id == home.id && $0.type == 0 })
    }

    @discardableResult
    func retryRecovery(notify: Bool = true) -> Bool {
        guard recovering, let group, let home else { return !recovering }
        let layout = driver.display()
        let restoreHome: Home? = if let layout {
            layout.spaces.contains(where: { $0.id == home.id && $0.type == 0 })
                ? Home(id: home.id, display: layout.display) : replacementHome(layout)
        } else {
            // The native recovery helper independently verifies the destination.
            home
        }
        let groups = [group] + (swapGroups.map { [$0.arriving, $0.leaving] } ?? [])
        guard let restoreHome, driver.restore(groups, home: restoreHome.id) else { return false }
        self.group = nil
        swapGroups = nil
        self.home = clearHomeAfterRecovery ? nil : restoreHome
        suspended = !clearHomeAfterRecovery && (layout == nil || layout?.current != restoreHome.id)
        clearHomeAfterRecovery = false
        recovering = false
        recoveryTask?.cancel()
        recoveryTask = nil
        retryAfter = .now.advanced(by: restartDelay)
        if notify { didRecover() }
        return true
    }

    private func recoverUntilRemoved() async {
        while !Task.isCancelled, recovering {
            do { try await Task.sleep(for: retryDelay) }
            catch { return }
            guard !Task.isCancelled else { return }
            if retryRecovery() { return }
        }
    }
}
