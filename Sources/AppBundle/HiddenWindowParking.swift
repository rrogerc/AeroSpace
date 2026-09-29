import Common
import Foundation
import PrivateApi

protocol HiddenWindowParkingDriver: Sendable {
    func display() -> NativeDisplaySpaces?
    func owners(_ ids: [UInt32]) -> [UInt32: Int32]?
    func isAppTerminated(_ pid: Int32) -> Bool
    func membership(_ id: UInt32) -> [UInt64]?
    func create(_ name: String) -> UInt64
    func hide(_ ids: [UInt32], in group: WorkspaceVisibilityGroup) -> Bool
    func reveal(_ ids: [UInt32], from group: WorkspaceVisibilityGroup, home: UInt64) -> Bool
    func restore(_ group: WorkspaceVisibilityGroup, home: UInt64) -> Bool
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

    func restore(_ group: WorkspaceVisibilityGroup, home: UInt64) -> Bool {
        AeroSpaceRestoreWorkspaceGroups([NSNumber(value: group.id): group.name] as CFDictionary, home)
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

    private let driver: any HiddenWindowParkingDriver
    private let didRecover: @Sendable () -> Void
    private let retryDelay: Duration
    private var home: Home?
    private var group: WorkspaceVisibilityGroup?
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
        didRecover: @escaping @Sendable () -> Void = {
            Task.startUnstructured { @MainActor in await recoverNativeWorkspaceVisibility() }
        },
    ) {
        self.driver = driver
        self.retryDelay = retryDelay
        self.didRecover = didRecover
    }

    func context() -> (home: UInt64?, group: UInt64?) { (home?.id, group?.id) }

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

    func apply(_ windows: [NativeVisibilityWindow], request: UInt64? = nil) -> NativeVisibilityPlan {
        guard !Task.isCancelled, !terminating, accept(request), !recovering else { return currentPlan }
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
        if Task.isCancelled {
            beginRecovery(clearHome: false, restartDelay: .zero)
            return currentPlan
        }
        if group == nil, !hide.isEmpty {
            let name = "AeroSpace hidden windows \(getuid()) \(getpid()) \(UUID().uuidString)"
            let id = driver.create(name)
            guard id != 0 else {
                beginRecovery(clearHome: false)
                return currentPlan
            }
            group = WorkspaceVisibilityGroup(id: id, name: name)
        }
        if Task.isCancelled {
            beginRecovery(clearHome: false, restartDelay: .zero)
            return currentPlan
        }
        if (!hide.isEmpty || !reveal.isEmpty), !isActive(home) {
            suspended = true
            beginRecovery(clearHome: false, restartDelay: .zero)
            return currentPlan
        }
        // Reveal before hiding the outgoing workspace, without activating either
        // app. Both operations acknowledge membership before releasing any gate.
        if let group, !reveal.isEmpty {
            guard driver.reveal(reveal, from: group, home: home.id) else {
                beginRecovery(clearHome: false)
                return currentPlan
            }
            for id in reveal { memberships[id] = [home.id] }
        }
        if Task.isCancelled {
            beginRecovery(clearHome: false, restartDelay: .zero)
            return currentPlan
        }
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
        if Task.isCancelled {
            beginRecovery(clearHome: false, restartDelay: .zero)
            return currentPlan
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
        return .native(entries.mapValues { ($0.window.pid, $0.gate) })
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
        guard let restoreHome, driver.restore(group, home: restoreHome.id) else { return false }
        self.group = nil
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
