import Collections
import Common
import Foundation
import os

enum AppRequestPriority: Sendable { case interactive, background }

@TaskLocal
var appRequestPriority: AppRequestPriority = .interactive

/// One queue per AX thread. Writes and command reads can overtake discovery, but retain
/// their own FIFO ordering so a geometry read or activation cannot overtake a frame write.
final class AppRequestQueue: Sendable {
    private struct Request: Sendable {
        let action: RunLoopAction
        let suppressAnimations: Bool
    }

    private struct State {
        var interactive: Deque<Request> = []
        var background: Deque<Request> = []
        var scheduled = false

        mutating func next() -> Request? { interactive.popFirst() ?? background.popFirst() }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    // Immutable; used only to submit perform(on:) work, never to mutate Thread's state.
    nonisolated(unsafe) private let thread: Thread
    private let beginFrameBatch: @Sendable () -> ()
    private let endFrameBatch: @Sendable () -> ()

    init(_ thread: Thread, beginFrameBatch: @escaping @Sendable () -> () = {}, endFrameBatch: @escaping @Sendable () -> () = {}) {
        unsafe self.thread = thread
        self.beginFrameBatch = beginFrameBatch
        self.endFrameBatch = endFrameBatch
    }

    @discardableResult
    func runAsync(
        job: RunLoopJob,
        priority: AppRequestPriority = .interactive,
        suppressAnimations: Bool = false,
        autoCheckCancelled: Bool = true,
        _ body: @Sendable @escaping (RunLoopJob) -> (),
    ) -> RunLoopJob {
        let request = Request(
            action: RunLoopAction(job: job, autoCheckCancelled: autoCheckCancelled, body),
            suppressAnimations: suppressAnimations,
        )
        let schedule = state.withLock { state in
            switch priority {
                case .interactive: state.interactive.append(request)
                case .background: state.background.append(request)
            }
            if state.scheduled { return false }
            state.scheduled = true
            return true
        }
        if schedule { scheduleDrain() }
        return job
    }

    func run<T>(_ cm: CancellationMode, _ body: @Sendable @escaping (RunLoopJob) throws -> T) async throws -> T {
        try checkCancellation(cm)
        let job = RunLoopJob(cm)
        let priority = appRequestPriority
        let result: T = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Even a cancelled request must run this wrapper to resume its continuation.
                runAsync(job: job, priority: priority, autoCheckCancelled: false) { job in
                    do {
                        try job.checkCancellation()
                        continuation.resume(returning: try body(job))
                    } catch {
                        if cm == .nonCancellable { die() }
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: { job.cancel() }
        // AX calls cannot be interrupted once running. Their late reply must
        // not let a cancelled refresh resume model/layout work after a command.
        try checkCancellation(cm)
        return result
    }

    private func scheduleDrain() {
        unsafe thread.runInLoopAsync(job: RunLoopJob(.nonCancellable)) { _ in self.drain() }
    }

    private func drain() {
        var inFrameBatch = false
        defer { if inFrameBatch { endFrameBatch() } }
        // Yield to AX notifications after a bounded batch. Each next request rechecks priority.
        for _ in 0 ..< 32 {
            let request = state.withLock { state in
                let request = state.next()
                if request == nil { state.scheduled = false }
                return request
            }
            guard let request else { return }
            let suppress = request.suppressAnimations && !request.action.job.isCancelled
            if inFrameBatch && !suppress { endFrameBatch(); inFrameBatch = false }
            if suppress && !inFrameBatch { beginFrameBatch(); inFrameBatch = true }
            request.action.action()
        }
        let hasMore = state.withLock { state in
            if state.interactive.isEmpty && state.background.isEmpty {
                state.scheduled = false
                return false
            }
            return true
        }
        if hasMore { scheduleDrain() }
    }
}
