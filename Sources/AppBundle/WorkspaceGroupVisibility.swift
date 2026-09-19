import AppKit
import Common
import Foundation
import os
import PrivateApi

struct WorkspaceVisibilityGroup: Equatable, Sendable {
    let id: UInt64
    let name: String
}

/// Synchronous operations run on the visibility actor, never the main actor.
/// Assignment acknowledges membership; commit acknowledges one atomic show/hide.
protocol WorkspaceGroupDriver: Sendable {
    func display() -> NativeDisplaySpaces?
    func owners(_ ids: [UInt32]) -> [UInt32: Int32]?
    func membership(_ id: UInt32) -> [UInt64]?
    func create(_ name: String) -> UInt64
    func assign(_ ids: [UInt32], to group: WorkspaceVisibilityGroup) -> Bool
    func commit(show: [WorkspaceVisibilityGroup], hide: [WorkspaceVisibilityGroup]) -> Bool
    func restore(_ groups: [WorkspaceVisibilityGroup], home: UInt64) -> Bool
}

struct WindowServerGroupDriver: WorkspaceGroupDriver {
    func display() -> NativeDisplaySpaces? {
        guard AeroSpaceWorkspaceGroupsAvailable(),
              let raw = AeroSpaceCopyNativeDisplays(), let layout = NativeDisplaySpaces.decode(raw),
              layout.current == AeroSpaceActiveNativeSpace()
        else { return nil }
        return layout
    }

    func owners(_ ids: [UInt32]) -> [UInt32: Int32]? {
        if ids.isEmpty { return [:] }
        return getWindowServerWindows(ids)?.reduce(into: [:]) { $0[$1.windowId] = $1.pid }
    }

    func membership(_ id: UInt32) -> [UInt64]? {
        (AeroSpaceCopyAllWindowSpaces(id) as? [NSNumber])?.map(\.uint64Value)
    }

    func create(_ name: String) -> UInt64 { AeroSpaceCreateWorkspaceGroup(name as CFString) }

    func assign(_ ids: [UInt32], to group: WorkspaceVisibilityGroup) -> Bool {
        unsafe ids.withUnsafeBufferPointer {
            unsafe AeroSpaceAssignWindowsToWorkspaceGroup($0.baseAddress, $0.count, group.id, group.name as CFString)
        }
    }

    func commit(show: [WorkspaceVisibilityGroup], hide: [WorkspaceVisibilityGroup]) -> Bool {
        AeroSpaceCommitWorkspaceGroupVisibility(records(show), records(hide))
    }

    func restore(_ groups: [WorkspaceVisibilityGroup], home: UInt64) -> Bool {
        AeroSpaceRestoreWorkspaceGroups(records(groups), home)
    }

    private func records(_ groups: [WorkspaceVisibilityGroup]) -> CFDictionary {
        Dictionary(uniqueKeysWithValues: groups.map { (NSNumber(value: $0.id), $0.name) }) as CFDictionary
    }
}

/// Each workspace keeps its own connection-owned visibility group. A normal
/// switch changes visibility only; it does not move any window between Spaces.
actor WorkspaceGroupVisibilityWorker {
    private struct Entry {
        let window: NativeVisibilityWindow
        let gate: NativeVisibilityGate
    }

    private let driver: any WorkspaceGroupDriver
    private let didRecover: @Sendable () -> Void
    private let retryDelay: Duration
    private var home: NativeDisplaySpaces?
    private var groups: [String: WorkspaceVisibilityGroup] = [:]
    private var visible: Set<String> = []
    private var entries: [UInt32: Entry] = [:]
    private var recovering = false
    private var terminating = false
    private var latestRequest: UInt64 = 0
    private var retryAfter = ContinuousClock.now
    private var restartDelay: Duration = .zero
    private var recoveryTask: Task<Void, Never>?

    init(
        driver: any WorkspaceGroupDriver = WindowServerGroupDriver(),
        retryDelay: Duration = .seconds(1),
        didRecover: @escaping @Sendable () -> Void = {
            Task.startUnstructured { @MainActor in await recoverNativeWorkspaceVisibility() }
        },
    ) {
        self.driver = driver
        self.retryDelay = retryDelay
        self.didRecover = didRecover
    }

    private func accept(_ request: UInt64?) -> Bool {
        guard let request else { return true }
        guard request > latestRequest else { return false }
        latestRequest = request
        return true
    }

    private var inactivePlan: NativeVisibilityPlan { recovering ? .recovering : .offscreen }

    func apply(_ windows: [NativeVisibilityWindow], request: UInt64? = nil, earlyFocus: WorkspaceFocusPreparation? = nil) -> NativeVisibilityPlan {
        let interval = signposter.beginInterval("applyWorkspaceGroups", "request: \(request ?? 0, privacy: .public)")
        defer { signposter.endInterval("applyWorkspaceGroups", interval) }
        guard !Task.isCancelled, earlyFocus?.job.isCancelled != true, !terminating, accept(request), !recovering else { return inactivePlan }
        guard ContinuousClock.now >= retryAfter else { return .offscreen }
        guard let layout = driver.display(), layout.spaces.count == 1, layout.spaces[0].type == 0,
              home == nil || (home?.display == layout.display && home?.current == layout.current)
        else {
            stop(restartDelay: .zero)
            return inactivePlan
        }
        // Reject an inconsistent projection before issuing any window mutations.
        guard Set(windows.map(\.id)).count == windows.count,
              Set(windows.filter(\.visible).map(\.workspace)).count <= 1,
              windows.allSatisfy({ !$0.workspace.isEmpty && $0.id != 0 && $0.pid > 0 }),
              Dictionary(grouping: windows, by: \.workspace).values.allSatisfy({ Set($0.map(\.visible)).count == 1 })
        else {
            stop()
            return inactivePlan
        }
        if home == nil { home = layout }
        let requested = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        let changed = windows.filter {
            entries[$0.id]?.window.pid != $0.pid || entries[$0.id]?.window.workspace != $0.workspace
        }
        let retired = entries.values.filter { requested[$0.window.id]?.pid != $0.window.pid }
        guard let owners = driver.owners(Array(Set(changed.map(\.id) + retired.map { $0.window.id }))) else {
            stop()
            return inactivePlan
        }
        for entry in retired {
            entry.gate.cancel()
            if owners[entry.window.id] == entry.window.pid {
                // A live window left the normal tiling model (e.g. fullscreen).
                // Restore memberships before allowing fallback AX work. Cleanup
                // preserves any independently acquired native-Space membership.
                stop(restartDelay: .zero)
                return inactivePlan
            }
            entries.removeValue(forKey: entry.window.id)
        }
        var assignments: [String: [UInt32]] = [:]
        for window in changed {
            guard owners[window.id] == window.pid else { continue }
            guard let membership = driver.membership(window.id) else {
                stop()
                return inactivePlan
            }
            let previousMembership = entries[window.id].flatMap { groups[$0.window.workspace]?.id }.map { [$0] }
            // Never take a window from fullscreen, another user's desktop or an
            // unrelated connection-owned group.
            guard membership == [layout.current] || membership == previousMembership else {
                stop(restartDelay: .zero)
                return inactivePlan
            }
            if groups[window.workspace] == nil {
                let name = "AeroSpace workspace group \(getuid()) \(getpid()) \(UUID().uuidString)"
                let id = driver.create(name)
                guard id != 0 else { stop(); return inactivePlan }
                groups[window.workspace] = WorkspaceVisibilityGroup(id: id, name: name)
            }
            assignments[window.workspace, default: []].append(window.id)
        }
        for (workspace, ids) in assignments {
            guard let group = groups[workspace], driver.assign(ids, to: group) else {
                stop()
                return inactivePlan
            }
        }
        let nextVisible = Set(windows.filter { $0.visible && groups[$0.workspace] != nil }.map(\.workspace))
        // Cancel outgoing waiters before hiding their groups. A cancelled frame
        // or focus job must not be released by an older visibility acknowledgement.
        for (id, entry) in entries where requested[id] != entry.window { entry.gate.cancel() }
        let show = nextVisible.subtracting(visible).compactMap { groups[$0] }
        let hide = visible.subtracting(nextVisible).compactMap { groups[$0] }
        guard !Task.isCancelled, earlyFocus?.job.isCancelled != true else { return inactivePlan }
        guard driver.commit(show: show, hide: hide) else { stop(); return inactivePlan }
        visible = nextVisible
        if let earlyFocus, changed.isEmpty, !show.isEmpty,
           windows.filter(\.visible).count == 1,
           requested[earlyFocus.windowId]?.pid == earlyFocus.pid,
           requested[earlyFocus.windowId]?.visible == true
        {
            // Begin activation as soon as visibility is acknowledged, before
            // returning to main-actor layout. Concurrent WindowServer visibility
            // queries and activation contend on the same connection; issuing the
            // transaction first also prevents activating a failed destination.
            earlyFocus.start()
        }
        for window in windows {
            guard entries[window.id] != nil || assignments[window.workspace]?.contains(window.id) == true else { continue }
            if let previous = entries[window.id], previous.window == window, !window.visible || previous.gate.isReady { continue }
            let gate = NativeVisibilityGate()
            if window.visible { gate.complete(true) }
            entries[window.id] = Entry(window: window, gate: gate)
        }
        let wantedWorkspaces = Set(windows.map(\.workspace))
        let unused = groups.filter { !wantedWorkspaces.contains($0.key) }
        if !unused.isEmpty {
            // Workspace names are not bounded: closing or moving the last window
            // must release its group without rebuilding other workspaces.
            guard driver.restore(Array(unused.values), home: layout.current) else { stop(); return inactivePlan }
            for name in unused.keys { groups.removeValue(forKey: name) }
        }
        return .native(entries.reduce(into: [:]) { result, entry in
            if entry.value.window.visible { result[entry.key] = (entry.value.window.pid, entry.value.gate) }
        })
    }

    @discardableResult
    func stop(retry: Bool = true, restartDelay: Duration = .seconds(5), request: UInt64? = nil) -> Bool {
        guard accept(request) else { return !recovering }
        if !retry { terminating = true }
        for entry in entries.values { entry.gate.cancel() }
        entries = [:]
        visible = []
        guard !groups.isEmpty else {
            if home != nil { retryAfter = .now.advanced(by: restartDelay) }
            home = nil
            return true
        }
        if !recovering { self.restartDelay = restartDelay }
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

    @discardableResult
    func retryRecovery(notify: Bool = true) -> Bool {
        guard recovering, let home else { return !recovering }
        guard driver.restore(Array(groups.values), home: home.current) else { return false }
        groups = [:]
        self.home = nil
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
