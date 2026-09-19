@testable import AppBundle
import Dispatch
import Foundation
import os
import XCTest

final class NativeFocusPreparationTest: XCTestCase {
    func testActivationCanOverlapFrameWhileRaiseStaysBehindIt() {
        let events = OSAllocatedUnfairLock(initialState: [String]())
        let ready = DispatchSemaphore(value: 0)
        let frameStarted = DispatchSemaphore(value: 0)
        let activationPrepared = DispatchSemaphore(value: 0)
        let finishFrame = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        let thread = Thread {
            let port = Port()
            RunLoop.current.add(port, forMode: .default)
            ready.signal()
            CFRunLoopRun()
            port.invalidate()
            stopped.signal()
        }
        thread.start()
        XCTAssertEqual(ready.wait(timeout: .now() + 3), .success)
        let requests = AppRequestQueue(thread)
        requests.runAsync(job: RunLoopJob(.cancellable)) { _ in
            events.withLock { $0.append("frame begins") }
            frameStarted.signal()
            finishFrame.wait()
            events.withLock { $0.append("frame ends") }
        }
        XCTAssertEqual(frameStarted.wait(timeout: .now() + 3), .success)
        let job = RunLoopJob(.cancellable)
        let prepared = NativeFocusPreparation().prepare(job: job) {
            events.withLock { $0.append("activate") }
            activationPrepared.signal()
            return true
        }
        requests.runAsync(job: job) { job in
            do {
                try performNativeFocus(job: job, activationOnly: true,
                                       makeKeyWindow: { prepared.blockingGet() },
                                       setMain: { XCTFail("Unexpected public main") },
                                       raise: { events.withLock { $0.append("raise") }; return .success },
                                       activate: { XCTFail("Unexpected public activation") })
            } catch { XCTFail("Unexpected cancellation") }
        }
        requests.runAsync(job: RunLoopJob(.nonCancellable), priority: .background) { _ in CFRunLoopStop(CFRunLoopGetCurrent()) }
        XCTAssertEqual(activationPrepared.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(events.withLock { $0 }, ["frame begins", "activate"])
        finishFrame.signal()
        XCTAssertEqual(stopped.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(events.withLock { $0 }, ["frame begins", "activate", "frame ends", "raise"])
    }

    func testCancelledQueuedPreparationDoesNotActivate() {
        let queue = DispatchQueue(label: "test cancelled activation")
        let preparation = NativeFocusPreparation(queue: queue)
        let job = RunLoopJob(.cancellable)
        job.cancel()
        let result = preparation.prepare(job: job) { XCTFail("Cancelled activation ran"); return true }
        queue.sync {}
        XCTAssertFalse(result.blockingGet())
    }

    func testCancelledNativeMoveCannotActivateTheParkingSpace() {
        let queue = DispatchQueue(label: "test cancelled native visibility")
        let visibility = NativeVisibilityGate()
        let preparation = NativeFocusPreparation(queue: queue)
        let job = RunLoopJob(.cancellable)
        let result = preparation.prepare(job: job, visibility: visibility) {
            XCTFail("A window still in the parking Space must not activate")
            return true
        }
        visibility.cancel()
        queue.sync {}
        XCTAssertFalse(result.blockingGet())
    }

    func testAcknowledgedNativeMoveAllowsPreparationWithoutWaitingForAXInventory() {
        let visibility = NativeVisibilityGate()
        visibility.complete(true)
        let queue = DispatchQueue(label: "test visible native window")
        let result = NativeFocusPreparation(queue: queue).prepare(job: RunLoopJob(.cancellable), visibility: visibility) { true }
        queue.sync {}
        XCTAssertTrue(result.blockingGet())
    }

    func testCancellationDuringPreparationPreventsRaise() {
        let queue = DispatchQueue(label: "test interrupted activation")
        let preparation = NativeFocusPreparation(queue: queue)
        let job = RunLoopJob(.cancellable)
        let result = preparation.prepare(job: job) { job.cancel(); return true }
        queue.sync {}
        XCTAssertThrowsError(try performNativeFocus(job: job, activationOnly: true,
                                                    makeKeyWindow: { result.blockingGet() },
                                                    setMain: { XCTFail("Cancelled main") },
                                                    raise: { XCTFail("Cancelled raise"); return .success },
                                                    activate: { XCTFail("Cancelled fallback") }))
    }

    func testRejectedPreparationStillUsesPublicFallback() throws {
        let queue = DispatchQueue(label: "test failed activation")
        let preparation = NativeFocusPreparation(queue: queue)
        let job = RunLoopJob(.cancellable)
        let result = preparation.prepare(job: job) { false }
        queue.sync {}
        var events: [String] = []
        try performNativeFocus(job: job, activationOnly: false,
                               makeKeyWindow: { result.blockingGet() },
                               setMain: { events.append("main") },
                               raise: { events.append("raise"); return .success },
                               activate: { events.append("activate") })
        XCTAssertEqual(events, ["main", "raise", "activate"])
    }

    func testQueuedSupersededRequestCannotRunAfterNewerActivation() {
        let queue = DispatchQueue(label: "test serial activations")
        let preparation = NativeFocusPreparation(queue: queue)
        let events = OSAllocatedUnfairLock(initialState: [Int]())
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        let stale = RunLoopJob(.cancellable)
        let first = preparation.prepare(job: stale) { events.withLock { $0.append(1) }; return true }
        let second = preparation.prepare(job: RunLoopJob(.cancellable)) { events.withLock { $0.append(2) }; return true }
        stale.cancel()
        gate.signal()
        queue.sync {}
        XCTAssertFalse(first.blockingGet())
        XCTAssertTrue(second.blockingGet())
        XCTAssertEqual(events.withLock { $0 }, [2])
    }
}
