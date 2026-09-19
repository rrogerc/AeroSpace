@testable import AppBundle
import Common
import Foundation
import os
import XCTest

final class AppRequestQueueTest: XCTestCase {
    func testMovementOvertakesDiscoveryWithoutReorderingWritesReadsOrFocus() {
        let events = OSAllocatedUnfairLock(initialState: [String]())
        withPausedQueue { queue in
            queue.runAsync(job: RunLoopJob(.cancellable), priority: .background) { _ in events.withLock { $0.append("discovery") } }
            for event in ["frame", "geometry read", "focus"] {
                queue.runAsync(job: RunLoopJob(.cancellable)) { _ in events.withLock { $0.append(event) } }
            }
        }
        XCTAssertEqual(events.withLock { $0 }, ["frame", "geometry read", "focus", "discovery"])
    }

    func testBatchEndsBeforeFocusAndAfterCancelledFrames() {
        let events = OSAllocatedUnfairLock(initialState: [String]())
        let cancelled = RunLoopJob(.cancellable)
        cancelled.cancel()
        withPausedQueue(
            begin: { events.withLock { $0.append("begin") } },
            end: { events.withLock { $0.append("end") } },
        ) { queue in
            for event in ["frame 1", "frame 2"] {
                queue.runAsync(job: RunLoopJob(.cancellable), suppressAnimations: true) { _ in events.withLock { $0.append(event) } }
            }
            queue.runAsync(job: cancelled, suppressAnimations: true) { _ in XCTFail("Cancelled frame ran") }
            queue.runAsync(job: RunLoopJob(.cancellable)) { _ in events.withLock { $0.append("focus") } }
        }
        XCTAssertTrue(cancelled.isComplete)
        XCTAssertEqual(events.withLock { $0 }, ["begin", "frame 1", "frame 2", "end", "focus"])
    }

    func testCancelledContinuationWrapperStillRunsExactlyOnce() {
        let events = OSAllocatedUnfairLock(initialState: [String]())
        let job = RunLoopJob(.cancellable)
        withPausedQueue { queue in
            queue.runAsync(job: job, priority: .background, autoCheckCancelled: false) { job in
                do {
                    try job.checkCancellation()
                    XCTFail("Expected cancellation")
                } catch {
                    events.withLock { $0.append("resume cancellation") }
                }
            }
            job.cancel()
        }
        XCTAssertTrue(job.isComplete)
        XCTAssertEqual(events.withLock { $0 }, ["resume cancellation"])
    }

    func testFocusCanKeepTheFrameBatchSuppressedUntilRaiseCompletes() {
        let events = OSAllocatedUnfairLock(initialState: [String]())
        withPausedQueue(
            begin: { events.withLock { $0.append("begin") } },
            end: { events.withLock { $0.append("restore") } },
        ) { queue in
            queue.runAsync(job: RunLoopJob(.cancellable), suppressAnimations: true) { _ in events.withLock { $0.append("frame") } }
            queue.runAsync(job: RunLoopJob(.cancellable), suppressAnimations: true) { _ in events.withLock { $0.append("raise") } }
        }
        XCTAssertEqual(events.withLock { $0 }, ["begin", "frame", "raise", "restore"])
    }

    func testLongBatchYieldsWithoutLosingRequestsOrCleanup() {
        let events = OSAllocatedUnfairLock(initialState: [Int]())
        withPausedQueue { queue in
            for i in 0 ..< 70 {
                queue.runAsync(job: RunLoopJob(.cancellable)) { _ in events.withLock { $0.append(i) } }
            }
        }
        XCTAssertEqual(events.withLock { $0 }, Array(0 ..< 70))
    }

    func testCancellationDuringBlockingReadRejectsItsLateReply() async {
        switch await readCancelledWhileRunning(.cancellable) {
            case .success: XCTFail("Cancelled refresh received a stale AX reply")
            case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
    }

    func testNonCancellableReadStillReturnsAfterCallerCancellation() async throws {
        let result = await readCancelledWhileRunning(.nonCancellable)
        XCTAssertEqual(try result.get(), "reply")
    }

    private func readCancelledWhileRunning(_ cm: CancellationMode) async -> Result<String, any Error> {
        let ready = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let releaseRead = DispatchSemaphore(value: 0)
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
        let queue = AppRequestQueue(thread)
        let task = Task.detached {
            try await queue.run(cm) { _ in
                entered.signal()
                releaseRead.wait()
                return "reply"
            }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        task.cancel()
        releaseRead.signal()
        let result = await task.result
        queue.runAsync(job: RunLoopJob(.nonCancellable)) { _ in CFRunLoopStop(CFRunLoopGetCurrent()) }
        XCTAssertEqual(stopped.wait(timeout: .now() + 3), .success)
        return result
    }

    private func withPausedQueue(
        begin: @escaping @Sendable () -> () = {},
        end: @escaping @Sendable () -> () = {},
        _ body: (AppRequestQueue) -> (),
    ) {
        let ready = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            let port = Port()
            RunLoop.current.add(port, forMode: .default)
            ready.signal()
            CFRunLoopRun()
            port.invalidate()
            finished.signal()
        }
        thread.start()
        XCTAssertEqual(ready.wait(timeout: .now() + 3), .success)
        let queue = AppRequestQueue(thread, beginFrameBatch: begin, endFrameBatch: end)
        queue.runAsync(job: RunLoopJob(.nonCancellable)) { _ in
            entered.signal()
            gate.wait()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        body(queue)
        queue.runAsync(job: RunLoopJob(.nonCancellable), priority: .background) { _ in CFRunLoopStop(CFRunLoopGetCurrent()) }
        gate.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 3), .success)
    }
}
