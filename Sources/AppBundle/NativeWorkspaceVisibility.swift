import AppKit
import Common
import Foundation
import os
import PrivateApi

struct NativeVisibilityWindow: Equatable, Sendable {
    let id: UInt32
    let pid: Int32
    let visible: Bool
    var workspace: String = ""
}

enum NativeVisibilityPlan: Sendable {
    case offscreen
    case native([UInt32: (Int32, NativeVisibilityGate)])
    case recovering
}

/// A move request is not an acknowledgement. Frame/focus workers wait for the
/// destination's observed membership; cancellation also releases every waiter.
final class NativeVisibilityGate: Sendable {
    private struct State { var result: Bool?; var cancelled = false; var observing = false }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let group = DispatchGroup()
    private let observe: (@Sendable () -> Bool)?

    init(observe: (@Sendable () -> Bool)? = nil) {
        self.observe = observe
        group.enter()
    }

    func complete(_ result: Bool) {
        let signal = state.withLock { state in
            guard state.result == nil else { return false }
            state.result = result
            return true
        }
        if signal { group.leave() }
    }

    func cancel() {
        state.withLock { $0.cancelled = true }
        complete(false)
    }

    var isReady: Bool { state.withLock { $0.result == true && !$0.cancelled } }

    func wait(for job: RunLoopJob) -> Bool {
        let deadline = DispatchTime.now() + .seconds(2)
        while !job.isCancelled {
            // A move may already have committed since the actor last polled.
            // Observe before sleeping so an available destination does not wait
            // for another timer or actor scheduling hop.
            if let observe, !job.isCancelled {
                let shouldObserve = state.withLock { state in
                    guard state.result == nil, !state.cancelled, !state.observing else { return false }
                    state.observing = true
                    return true
                }
                if shouldObserve {
                    let ready = observe()
                    state.withLock { $0.observing = false }
                    if ready { complete(true) }
                }
            }
            if group.wait(timeout: .now() + .milliseconds(1)) == .success {
                return state.withLock { $0.result == true && !$0.cancelled } && !job.isCancelled
            }
            if DispatchTime.now() >= deadline { return false }
        }
        return false
    }
}

private func nativeWindowSpaces(_ id: UInt32) -> [UInt64]? {
    let state = signposter.beginInterval("observeNativeMembership", "window: \(id, privacy: .public)")
    defer { signposter.endInterval("observeNativeMembership", state) }
    guard let values = AeroSpaceCopyNativeWindowSpaces(id) as? [NSNumber] else { return nil }
    return values.map(\.uint64Value)
}

/// The registry is shared with per-app AX workers, but contains no AX objects.
final class NativeVisibilityGates: Sendable {
    static let shared = NativeVisibilityGates()
    private let gates = OSAllocatedUnfairLock(initialState: [UInt32: (Int32, NativeVisibilityGate)]())

    func get(_ id: UInt32, pid: Int32) -> NativeVisibilityGate? {
        gates.withLock { $0[id].flatMap { $0.0 == pid ? $0.1 : nil } }
    }

    func replace(_ next: [UInt32: (Int32, NativeVisibilityGate)]) {
        gates.withLock { gates in
            for (id, entry) in gates where next[id]?.1 !== entry.1 { entry.1.cancel() }
            gates = next
        }
    }
}

struct NativeDisplaySpaces: Sendable {
    struct Space: Sendable {
        let id: UInt64
        let type: Int
        let name: String?
    }
    let display: String
    let current: UInt64
    let spaces: [Space]

    static func decode(_ value: Any) -> NativeDisplaySpaces? {
        guard let displays = value as? [[String: Any]], displays.count == 1,
              let display = displays[0]["Display Identifier"] as? String,
              let current = displays[0]["Current Space"] as? [String: Any],
              let currentNumber = current["id64"] as? NSNumber,
              CFGetTypeID(currentNumber) != CFBooleanGetTypeID(),
              let currentId = UInt64(currentNumber.stringValue), currentId != 0,
              let values = displays[0]["Spaces"] as? [[String: Any]]
        else { return nil }
        var spaces: [Space] = []
        for value in values {
            guard let idNumber = value["id64"] as? NSNumber, CFGetTypeID(idNumber) != CFBooleanGetTypeID(),
                  let id = UInt64(idNumber.stringValue), id != 0,
                  let typeNumber = value["type"] as? NSNumber, CFGetTypeID(typeNumber) != CFBooleanGetTypeID(),
                  let type = Int(typeNumber.stringValue)
            else { return nil }
            guard !spaces.contains(where: { $0.id == id }) else { return nil }
            spaces.append(Space(id: id, type: type, name: value["name"] as? String))
        }
        guard !display.isEmpty, spaces.contains(where: { $0.id == currentId }) else { return nil }
        return NativeDisplaySpaces(display: display, current: currentId, spaces: spaces)
    }
}

private let nativeVisibilityNamePrefix = "AeroSpace private windows \(getuid()) "

/// Pipe EOF runs recovery even after SIGKILL. The waiting process does not poll,
/// and the recovery entry point never starts a second window manager or UI.
protocol NativeVisibilityRecoveryWatchdog: Sendable {
    var isRunning: Bool { get }
    func release()
}

private final class NativeVisibilityWatchdog: NativeVisibilityRecoveryWatchdog {
    private let process = Process()
    private let pipe = Pipe()

    var isRunning: Bool { process.isRunning }

    init(space: UInt64, name: String) throws {
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", "/bin/cat >/dev/null\nexec \"$@\"", "aerospace-window-recovery",
            Bundle.main.executableURL.orDie().path, "--recover-private-space", String(space), name,
        ]
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try? pipe.fileHandleForReading.close()
    }

    func release() { try? pipe.fileHandleForWriting.close() }
    deinit { release() }
}

/// Called before SwiftUI/AppKit initialization by the short-lived recovery process.
public func runNativeVisibilityRecoveryIfRequested() -> Bool {
    let args = CommandLine.arguments
    guard args.count > 1, args[1] == "--recover-private-space" else { return false }
    guard args.count == 4, let space = UInt64(args[2]), space != 0,
          args[3].hasPrefix(nativeVisibilityNamePrefix)
    else { return true }
    for _ in 0 ..< 3 {
        if AeroSpaceRecoverParkingSpace(space, args[3] as CFString) { break }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return true
}

actor NativeVisibilityWorker {
    struct Lease: Sendable {
        let home: UInt64
        let parking: UInt64
        let name: String
        let display: String
        let watchdog: (any NativeVisibilityRecoveryWatchdog)?
    }
    struct Entry {
        let window: NativeVisibilityWindow
        let gate: NativeVisibilityGate
        var pending: Bool
        let deadline: ContinuousClock.Instant
    }
    private var lease: Lease?
    private var retiringLease: Lease?
    private var entries: [UInt32: Entry] = [:]
    private var generation: UInt64 = 0
    private var latestRequest: UInt64
    private var isTerminating = false
    private var pollTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var retryAfter = ContinuousClock.now
    private var restartDelay: Duration = .seconds(5)
    private let retryDelay: Duration
    private let recover: @Sendable (UInt64, String) -> Bool
    private let didRecover: @Sendable () -> Void

    init(
        lease: Lease? = nil,
        latestRequest: UInt64 = 0,
        retryDelay: Duration = .seconds(1),
        recover: @escaping @Sendable (UInt64, String) -> Bool = { AeroSpaceRecoverParkingSpace($0, $1 as CFString) },
        didRecover: @escaping @Sendable () -> Void = {
            Task.startUnstructured { @MainActor in await recoverNativeWorkspaceVisibility() }
        },
    ) {
        self.lease = lease
        self.latestRequest = latestRequest
        self.retryDelay = retryDelay
        self.recover = recover
        self.didRecover = didRecover
    }

    private func displaySpaces() -> NativeDisplaySpaces? {
        let state = signposter.beginInterval("observeNativeDisplays")
        defer { signposter.endInterval("observeNativeDisplays", state) }
        return AeroSpaceCopyNativeDisplays().flatMap { NativeDisplaySpaces.decode($0) }
    }

    private func spaces(_ id: UInt32) -> [UInt64]? {
        nativeWindowSpaces(id)
    }

    private func start() -> Bool {
        // A failed cleanup still owns a desktop containing user windows. Do not
        // reuse it or create another one until its removal has been confirmed.
        if retiringLease != nil { return false }
        if lease != nil { return true }
        guard ContinuousClock.now >= retryAfter, AeroSpaceNativeVisibilityAvailable(), var layout = displaySpaces() else { return false }
        // Recover an interrupted installation/relaunch when its pipe watcher could
        // not exec the app. A live owner and unrelated native Spaces are untouched.
        for space in layout.spaces {
            guard let name = space.name, name.hasPrefix(nativeVisibilityNamePrefix) else { continue }
            let identity = name.dropFirst(nativeVisibilityNamePrefix.count).split(separator: " ")
            guard identity.count == 2, let owner = Int32(identity[0]), UUID(uuidString: String(identity[1])) != nil,
                  owner != getpid(), kill(owner, 0) != 0, errno == ESRCH
            else { continue }
            _ = AeroSpaceRecoverParkingSpace(space.id, name as CFString)
        }
        guard let refreshed = displaySpaces() else { return false }
        layout = refreshed
        // Native fullscreen and multiple native desktops/monitors keep the existing
        // backend. Returning to one desktop automatically retries this backend.
        guard layout.spaces.count == 1, layout.spaces[0].type == 0 else { return false }
        let name = "\(nativeVisibilityNamePrefix)\(getpid()) \(UUID().uuidString)"
        let parking = AeroSpaceCreateParkingSpace(name as CFString)
        guard parking != 0 else { retryAfter = .now.advanced(by: .seconds(5)); return false }
        do {
            let watchdog = try NativeVisibilityWatchdog(space: parking, name: name)
            lease = Lease(home: layout.current, parking: parking, name: name, display: layout.display, watchdog: watchdog)
            return true
        } catch {
            lease = Lease(home: layout.current, parking: parking, name: name, display: layout.display, watchdog: nil)
            stop()
            retryAfter = .now.advanced(by: .seconds(5))
            return false
        }
    }

    private func acceptRequest(_ request: UInt64?) -> Bool {
        guard let request else { return true }
        guard request > latestRequest else { return false }
        latestRequest = request
        return true
    }

    func apply(_ windows: [NativeVisibilityWindow], request: UInt64? = nil) -> NativeVisibilityPlan {
        let state = signposter.beginInterval("applyNativeVisibility", "request: \(request ?? 0, privacy: .public)")
        defer { signposter.endInterval("applyNativeVisibility", state) }
        // Actor jobs can arrive out of order. Main-actor validation after this
        // call is too late to undo an obsolete WindowServer mutation.
        guard !Task.isCancelled, !isTerminating, acceptRequest(request) else { return inactivePlan }
        guard start(), let lease else { return inactivePlan }
        guard lease.watchdog?.isRunning == true, let layout = displaySpaces() else { stop(); return inactivePlan }
        guard AeroSpaceActiveNativeSpace() == lease.home, layout.display == lease.display,
              layout.spaces.count == 2, layout.spaces.allSatisfy({ $0.type == 0 }),
              layout.spaces.contains(where: { $0.id == lease.home }),
              layout.spaces.contains(where: { $0.id == lease.parking && $0.name == lease.name })
        else {
            // Fullscreen and display changes are normal transitions. Eligibility
            // prevents restarting until the topology supports this backend again;
            // fault backoff could otherwise outlast its final change notification.
            stop(restartDelay: .zero)
            return inactivePlan
        }
        generation &+= 1
        let generation = generation
        pollTask?.cancel()
        let requested = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        let changedIds = windows.filter { entries[$0.id]?.window != $0 }.map(\.id)
        let retiredIds = entries.filter { requested[$0.key]?.pid != $0.value.window.pid }.map(\.key)
        // Validate the changed windows in one WindowServer round trip. These
        // records belong only to this synchronous apply; they are never cached
        // across visibility requests or reused for later frame writes.
        let records = getWindowServerWindows(Array(Set(changedIds + retiredIds)))
        let owners = records?.reduce(into: [UInt32: Int32]()) { $0[$1.windowId] = $1.pid }
        func hasExpectedOwner(_ id: UInt32, pid: Int32) -> Bool {
            if let owners { return owners[id] == pid }
            return getWindowServerWindow(id, pid: pid) != nil
        }
        var incoming: [UInt32] = []
        var outgoing: [UInt32] = []
        for (id, entry) in entries where requested[id]?.pid != entry.window.pid {
            entry.gate.cancel()
            if hasExpectedOwner(id, pid: entry.window.pid), spaces(id) == [lease.parking] { incoming.append(id) }
            entries.removeValue(forKey: id)
        }
        for window in windows {
            let previous = entries[window.id]
            if let previous, previous.window == window {
                continue
            }
            previous?.gate.cancel()
            let gate = if window.visible {
                NativeVisibilityGate(observe: { nativeWindowSpaces(window.id) == [lease.home] })
            } else { NativeVisibilityGate() }
            guard hasExpectedOwner(window.id, pid: window.pid) else { gate.cancel(); continue }
            guard let membership = spaces(window.id) else { stop(); return inactivePlan }
            let target = window.visible ? lease.home : lease.parking
            // Never steal a window from a native fullscreen/other user Space.
            guard membership == [lease.home] || membership == [lease.parking] else {
                gate.cancel()
                entries.removeValue(forKey: window.id)
                continue
            }
            // A rapid return can observe the desired Space before an older
            // opposite move has arrived. Reassert every changed visibility
            // request so that delayed move cannot become the final state.
            let pending = previous != nil || membership != [target]
            entries[window.id] = Entry(window: window, gate: gate, pending: pending, deadline: .now.advanced(by: .seconds(1)))
            if !pending { gate.complete(true) }
            else if window.visible { incoming.append(window.id) }
            else { outgoing.append(window.id) }
        }
        // Submit both batches before activation. Activating before parking caused
        // a large regression with the loaded game in the independent prototype.
        guard move(incoming, to: lease.home), move(outgoing, to: lease.parking) else { stop(); return inactivePlan }
        // Membership acknowledgement unblocks interactive focus workers. Give
        // that task explicit priority even when layout came from a background refresh.
        pollTask = Task.detached(priority: .high) { await self.poll(generation, deadline: .now.advanced(by: .seconds(1))) }
        return .native(entries.reduce(into: [:]) { result, entry in
            if entry.value.window.visible { result[entry.key] = (entry.value.window.pid, entry.value.gate) }
        })
    }

    private var inactivePlan: NativeVisibilityPlan { retiringLease == nil ? .offscreen : .recovering }

    private func move(_ windows: [UInt32], to space: UInt64) -> Bool {
        guard !windows.isEmpty else { return true }
        let state = signposter.beginInterval("submitNativeVisibility", "space: \(space, privacy: .public) count: \(windows.count, privacy: .public)")
        defer { signposter.endInterval("submitNativeVisibility", state) }
        return unsafe windows.withUnsafeBufferPointer { buffer in
            unsafe AeroSpaceMoveWindowsToNativeSpace(buffer.baseAddress, buffer.count, space)
        }
    }

    private func poll(_ expectedGeneration: UInt64, deadline: ContinuousClock.Instant) async {
        while !Task.isCancelled, generation == expectedGeneration, let lease {
            var pending = false
            // Release incoming focus/frame gates before checking outgoing windows.
            // A slow outgoing query must not delay an already visible destination.
            let pendingIds = entries.filter { $0.value.pending }.sorted { $0.value.window.visible && !$1.value.window.visible }.map(\.key)
            for id in pendingIds {
                guard var entry = entries[id] else { continue }
                if entry.gate.isReady || spaces(id) == [entry.window.visible ? lease.home : lease.parking] {
                    entry.pending = false
                    entry.gate.complete(true)
                    entries[id] = entry
                } else { pending = true }
            }
            if !pending { return }
            if ContinuousClock.now >= deadline || entries.values.contains(where: { $0.pending && ContinuousClock.now >= $0.deadline }) {
                stop()
                return
            }
            // Focus is waiting on this observation. Default clock tolerance can
            // coalesce the timer with later work and postpone an otherwise ready window.
            try? await Task.sleep(for: .milliseconds(3), tolerance: .zero)
        }
    }

    @discardableResult
    func stop(retry: Bool = true, restartDelay: Duration = .seconds(5), request: UInt64? = nil) -> Bool {
        guard acceptRequest(request) else { return retiringLease == nil }
        if !retry { isTerminating = true }
        generation &+= 1
        pollTask?.cancel()
        pollTask = nil
        for entry in entries.values { entry.gate.cancel() }
        entries = [:]
        if let lease {
            retiringLease = lease
            self.lease = nil
            self.restartDelay = restartDelay
        }
        guard retiringLease != nil else { return true }
        if !retry {
            recoveryTask?.cancel()
            recoveryTask = nil
            let recovered = retryRecovery(notify: false)
            // On termination the independent helper gets a final chance even if
            // this process could not confirm cleanup. Keep its identity intact.
            retiringLease?.watchdog?.release()
            return recovered
        }
        if recoveryTask != nil { return false }
        if retryRecovery() { return true }
        recoveryTask = Task.startUnstructured { await self.recoverUntilRemoved() }
        return false
    }

    @discardableResult
    func retryRecovery(notify: Bool = true) -> Bool {
        guard let retiringLease else { return true }
        guard recover(retiringLease.parking, retiringLease.name) else { return false }
        self.retiringLease = nil
        retiringLease.watchdog?.release()
        recoveryTask?.cancel()
        recoveryTask = nil
        retryAfter = .now.advanced(by: restartDelay)
        if notify { didRecover() }
        return true
    }

    private func recoverUntilRemoved() async {
        while !Task.isCancelled, retiringLease != nil {
            do { try await Task.sleep(for: retryDelay) }
            catch { return }
            guard !Task.isCancelled else { return }
            if retryRecovery() { return }
        }
    }
}

@MainActor
final class NativeWorkspaceVisibility {
    static let shared = NativeWorkspaceVisibility()
    // Experimental native visibility can break mouse tracking in other apps.
    // Keep it opt-in until ordinary pointer interaction is verified as well as focus.
    private let requested = ProcessInfo.processInfo.environment["AEROSPACE_NATIVE_WORKSPACE_VISIBILITY"] == "1"
    private let worker = NativeVisibilityWorker()
    private let groupWorker = WorkspaceGroupVisibilityWorker()
    private let useGroups = ProcessInfo.processInfo.environment["AEROSPACE_WORKSPACE_GROUPS"] != "0"
    private var request: UInt64 = 0
    private var hasNativeWork = false

    func prepareFocus(_ window: Window?) -> WorkspaceFocusPreparation? {
        guard requested, useGroups, !isUnitTest, monitorInfos.count == 1,
              let window = window as? MacWindow, window.layoutReason == .standard,
              focus.workspace.allLeafWindowsRecursive.count == 1
        else { return nil }
        return window.macAppUnsafe.prepareWorkspaceFocus(window.windowId)
    }

    func apply(earlyFocus: WorkspaceFocusPreparation? = nil) async throws -> NativeVisibilityPlan {
        // A cancelled AX refresh may finish after a foreground command starts.
        // It must not invalidate that command's request or submit another layout.
        try checkCancellation()
        guard requested, !isUnitTest, !serverArgs.isReadOnly, monitorInfos.count == 1 else {
            return await stop() ? .offscreen : .recovering
        }
        request &+= 1
        let request = request
        let windows = Workspace.all.flatMap { workspace in
            workspace.allLeafWindowsRecursive.compactMap { window -> NativeVisibilityWindow? in
                guard window.layoutReason == .standard else { return nil }
                if !workspace.isVisible { window.macAppUnsafe.cancelPendingFrame(window.windowId) }
                return NativeVisibilityWindow(id: window.windowId, pid: window.app.pid, visible: workspace.isVisible, workspace: workspace.name)
            }
        }
        hasNativeWork = true // Includes a startup still running on the worker.
        let state = signposter.beginInterval("awaitNativeVisibility", "request: \(request, privacy: .public)")
        let plan = if useGroups { await groupWorker.apply(windows, request: request, earlyFocus: earlyFocus) }
        else { await worker.apply(windows, request: request) }
        signposter.endInterval("awaitNativeVisibility", state)
        try checkCancellation()
        guard request == self.request else { throw CancellationError() }
        switch plan {
            case .native(let gates): NativeVisibilityGates.shared.replace(gates)
            case .offscreen:
                hasNativeWork = false
                NativeVisibilityGates.shared.replace([:])
            case .recovering: blockWindowWorkDuringRecovery()
        }
        return plan
    }

    @discardableResult
    func stop() async -> Bool {
        guard hasNativeWork else { return true }
        request &+= 1
        let request = request
        blockWindowWorkDuringRecovery()
        // A deliberate disable must not impose fault backoff on the next enable.
        let recovered = if useGroups { await groupWorker.stop(restartDelay: .zero, request: request) }
        else { await worker.stop(restartDelay: .zero, request: request) }
        guard request == self.request else { return false }
        if recovered {
            hasNativeWork = false
            NativeVisibilityGates.shared.replace([:])
        }
        return recovered
    }

    private func blockWindowWorkDuringRecovery() {
        let gate = NativeVisibilityGate()
        gate.cancel()
        var gates: [UInt32: (Int32, NativeVisibilityGate)] = [:]
        for window in MacWindow.allWindows where window.layoutReason == .standard {
            gates[window.windowId] = (window.app.pid, gate)
        }
        NativeVisibilityGates.shared.replace(gates)
    }

    func stopBeforeTermination() {
        NativeVisibilityGates.shared.replace([:])
        let semaphore = DispatchSemaphore(value: 0)
        let worker = worker
        let groupWorker = groupWorker
        let useGroups = useGroups
        Task.detached {
            if useGroups { await groupWorker.stop(retry: false) }
            else { await worker.stop(retry: false) }
            semaphore.signal()
        }
        semaphore.wait()
    }
}
