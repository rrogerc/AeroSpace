@testable import AppBundle
import Foundation
import os
import XCTest

/// Exercises the real worker with an in-memory recovery backend. No Space or
/// window APIs, child processes or desktop changes are used by these tests.
final class NativeWorkspaceRecoveryLifecycleTest: XCTestCase {
    func testOlderLayoutAndStopCannotOverwriteANewerNativeRequest() async {
        let recorder = RecoveryRecorder(failures: 0)
        let worker = makeWorker(recorder, latestRequest: 20)
        _ = await worker.apply([], request: 19)
        _ = await worker.apply([], request: 20)
        _ = await worker.stop(request: 18)
        XCTAssertTrue(recorder.attempts.isEmpty, "Stale requests must not mutate the active desktop")
        XCTAssertEqual(recorder.releases, 0)
        _ = await worker.stop(retry: false, request: 21)
        XCTAssertEqual(recorder.attempts.count, 1)
        XCTAssertEqual(recorder.releases, 1)
    }

    func testTerminationRejectsQueuedLayoutsEvenWithANewerRequest() async {
        let recorder = RecoveryRecorder(failures: 0)
        let worker = makeWorker(recorder)
        _ = await worker.stop(retry: false, restartDelay: .zero, request: 1)
        _ = await worker.apply([], request: 2)
        XCTAssertEqual(recorder.attempts.count, 1)
        XCTAssertEqual(recorder.releases, 1)
    }

    func testCancelledLayoutCannotMutateOrRetireTheActiveLease() async {
        let recorder = RecoveryRecorder(failures: 0)
        let worker = makeWorker(recorder)
        let proceed = AwaitableOneTimeBroadcastLatch()
        let task = Task.detached {
            try? await proceed.await()
            return await worker.apply([])
        }
        task.cancel()
        _ = await task.value
        XCTAssertTrue(recorder.attempts.isEmpty, "Stale layout must not reach native Space work")
        XCTAssertEqual(recorder.releases, 0, "Stale layout must not retire the current lease")
        _ = await worker.stop(retry: false)
    }

    func testFailedCleanupKeepsTheLeaseAndPreventsNativeReuse() async {
        let recorder = RecoveryRecorder(failures: 1)
        let worker = makeWorker(recorder)
        let stopped = await worker.stop()
        XCTAssertFalse(stopped)
        if case .recovering = await worker.apply([]) {} else { XCTFail("Must keep recovery pending") }
        XCTAssertEqual(recorder.releases, 0, "The crash watchdog must remain armed")
        let recovered = await worker.retryRecovery()
        XCTAssertTrue(recovered)
        if case .offscreen = await worker.apply([]) {} else { XCTFail("Must use fallback during cooldown") }
        XCTAssertEqual(recorder.attempts.map(\.0), [42, 42])
        XCTAssertEqual(recorder.attempts.map(\.1), ["owned-space", "owned-space"])
        XCTAssertEqual(recorder.releases, 1)
        XCTAssertEqual(recorder.notifications, 1)
    }

    func testRepeatedStopDoesNotDuplicateRecoveryOrDisarmTheWatchdog() async {
        let recorder = RecoveryRecorder(failures: 1)
        let worker = makeWorker(recorder)
        _ = await worker.stop()
        _ = await worker.stop()
        _ = await worker.stop()
        XCTAssertEqual(recorder.attempts.count, 1)
        XCTAssertEqual(recorder.releases, 0)
        _ = await worker.retryRecovery()
        _ = await worker.stop()
        _ = await worker.retryRecovery()
        XCTAssertEqual(recorder.attempts.count, 2)
        XCTAssertEqual(recorder.notifications, 1, "A stale retry cannot refocus after recovery")
    }

    func testTerminationHandsUnfinishedRecoveryToTheIndependentWatchdog() async {
        let recorder = RecoveryRecorder(failures: 10)
        let worker = makeWorker(recorder)
        _ = await worker.stop()
        let recovered = await worker.stop(retry: false)
        XCTAssertFalse(recovered)
        XCTAssertEqual(recorder.attempts.count, 2)
        XCTAssertEqual(recorder.releases, 1)
        XCTAssertEqual(recorder.notifications, 0, "Termination must not schedule UI work")
    }

    func testAutomaticRetryRepairsTheDesktopWithoutAnotherCommand() async {
        let recorder = RecoveryRecorder(failures: 1)
        let recovered = expectation(description: "Automatic recovery")
        let worker = makeWorker(recorder, retryDelay: .milliseconds(1), onRecovery: { recovered.fulfill() })
        let stopped = await worker.stop()
        XCTAssertFalse(stopped)
        await fulfillment(of: [recovered], timeout: 1)
        XCTAssertEqual(recorder.attempts.count, 2)
        XCTAssertEqual(recorder.releases, 1)
        XCTAssertEqual(recorder.notifications, 1)
        _ = await worker.stop(retry: false)
    }

    private func makeWorker(
        _ recorder: RecoveryRecorder,
        latestRequest: UInt64 = 0,
        retryDelay: Duration = .seconds(3600),
        onRecovery: @escaping @Sendable () -> Void = {},
    ) -> NativeVisibilityWorker {
        NativeVisibilityWorker(
            lease: .init(home: 1, parking: 42, name: "owned-space", display: "display", watchdog: recorder),
            latestRequest: latestRequest,
            retryDelay: retryDelay,
            recover: { recorder.recover($0, $1) },
            didRecover: { recorder.didRecover(); onRecovery() },
        )
    }
}

private final class RecoveryRecorder: NativeVisibilityRecoveryWatchdog {
    private struct State {
        var failures: Int
        var attempts: [(UInt64, String)] = []
        var releases = 0
        var notifications = 0
    }

    private let state: OSAllocatedUnfairLock<State>

    init(failures: Int) { state = OSAllocatedUnfairLock(initialState: State(failures: failures)) }
    var isRunning: Bool { state.withLock { $0.releases == 0 } }
    var releases: Int { state.withLock { $0.releases } }
    var attempts: [(UInt64, String)] { state.withLock { $0.attempts } }
    var notifications: Int { state.withLock { $0.notifications } }

    func release() { state.withLock { $0.releases += 1 } }
    func didRecover() { state.withLock { $0.notifications += 1 } }

    func recover(_ id: UInt64, _ name: String) -> Bool {
        state.withLock { state in
            state.attempts.append((id, name))
            if state.failures > 0 {
                state.failures -= 1
                return false
            }
            return true
        }
    }
}
