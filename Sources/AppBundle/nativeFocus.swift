import ApplicationServices
import Common
import Dispatch
import Foundation
import os
import PrivateApi

enum PrivateWindowFocus {
    // Allows a same-binary A/B comparison and an escape hatch without changing config.
    static let isEnabled = ProcessInfo.processInfo.environment["AEROSPACE_PRIVATE_FOCUS"] != "0"

    static func makeKeyWindow(pid: Int32, windowId: UInt32) -> Bool {
        let state = signposter.beginInterval("makeKeyWindow", "pid: \(pid, privacy: .public) window: \(windowId, privacy: .public)")
        defer { signposter.endInterval("makeKeyWindow", state) }
        return isEnabled && AeroSpaceMakeKeyWindow(pid, windowId) == .success
    }
}

/// One activation shared by the visibility actor and the final AX focus job.
/// The actor starts it immediately after revealing a fixed-membership group.
/// The shared serial queue prevents an older activation overtaking it.
final class WorkspaceFocusPreparation: Sendable {
    let pid: Int32
    let windowId: UInt32
    let job: RunLoopJob
    private let preparation: NativeFocusPreparation
    private let activate: @Sendable () -> Bool
    private struct State { var started = false; var result: Bool? }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let completion = DispatchGroup()

    init(
        pid: Int32,
        windowId: UInt32,
        job: RunLoopJob,
        preparation: NativeFocusPreparation = .shared,
        activate: (@Sendable () -> Bool)? = nil,
    ) {
        self.pid = pid
        self.windowId = windowId
        self.job = job
        self.preparation = preparation
        self.activate = activate ?? { PrivateWindowFocus.makeKeyWindow(pid: pid, windowId: windowId) }
    }

    var result: Bool? { state.withLock { $0.result } }
    var hasStarted: Bool { state.withLock { $0.started } }

    func start() {
        let start = state.withLock { state in
            guard !state.started, !job.isCancelled else { return false }
            completion.enter()
            state.started = true
            return true
        }
        if start {
            _ = preparation.prepare(job: job, onCompletion: { [self] result in
                state.withLock { $0.result = result }
                completion.leave()
            }, makeKeyWindow: activate)
        }
    }

    func waitForResult() -> Bool? {
        guard hasStarted else { return nil }
        completion.wait()
        return result
    }
}

/// Prepare single-window activation independently of its AX frame queue. The final
/// raise remains on that queue, after the frame, and uses the same cancellation job.
final class NativeFocusPreparation: Sendable {
    static let isEnabled = ProcessInfo.processInfo.environment["AEROSPACE_EARLY_PRIVATE_FOCUS"] == "1"
    static let shared = NativeFocusPreparation()
    private let queue: DispatchQueue

    init(queue: DispatchQueue = DispatchQueue(label: "AeroSpace native activation", qos: .userInteractive)) {
        self.queue = queue
    }

    func prepare(
        job: RunLoopJob,
        visibility: NativeVisibilityGate? = nil,
        onCompletion: @Sendable @escaping (Bool) -> Void = { _ in },
        makeKeyWindow: @Sendable @escaping () -> Bool,
    ) -> CompletableFuture<Bool> {
        let result = CompletableFuture<Bool>()
        let state = signposter.beginInterval("prepareNativeFocus")
        queue.async {
            var succeeded = false
            defer {
                result.complete(succeeded)
                onCompletion(succeeded)
                signposter.endInterval("prepareNativeFocus", state)
            }
            guard !job.isCancelled else { return }
            // The hotkey callback has already returned. Keep its asynchronous
            // visibility/focus work interactive until completion, so background
            // timer throttling cannot defer an otherwise ready destination.
            ProcessInfo.processInfo.performActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "Switching workspaces",
            ) {
                if let visibility {
                    let waitState = signposter.beginInterval("waitForNativeFocusVisibility")
                    let ready = visibility.wait(for: job)
                    signposter.endInterval("waitForNativeFocusVisibility", waitState)
                    if !ready { return }
                }
                succeeded = makeKeyWindow()
            }
        }
        return result
    }
}

/// Completes focus on the destination app's worker after its frame writes. A prepared
/// activation and every fallback stage share the same global cancellation job.
func performNativeFocus(
    job: RunLoopJob,
    activationOnly: Bool,
    privateRaiseRequired: Bool = true,
    makeKeyWindow: () -> Bool,
    setMain: () -> (),
    raise: () -> AXError,
    activate: () -> (),
) throws {
    try job.checkCancellation()
    if makeKeyWindow() {
        // Preparation may have completed earlier; only raise if this job is still current.
        try job.checkCancellation()
        if !privateRaiseRequired { return }
        if raise() == .success { return }
    }

    // Missing symbols, rejected activation/events, or an AX raise failure retain
    // the existing public path. Recheck cancellation after every blocking call.
    try job.checkCancellation()
    if !activationOnly {
        setMain()
        try job.checkCancellation()
        _ = raise()
    }
    try job.checkCancellation()
    activate()
}
