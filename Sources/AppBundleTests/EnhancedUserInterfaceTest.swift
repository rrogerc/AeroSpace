@testable import AppBundle
import ApplicationServices
import XCTest

final class EnhancedUserInterfaceTest: XCTestCase {
    func testBatchAndNestedCallsRestoreOnlyAfterLastRelease() {
        var reads = 0
        var writes: [Bool] = []
        let ui = EnhancedUserInterface(read: { reads += 1; return .success(true) }, write: { writes.append($0); return .success })
        ui.acquireForBatch()
        ui.acquireForBatch()
        ui.acquire()
        ui.release()
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(writes, [false])
        ui.release()
        XCTAssertEqual(writes, [false, true])
    }

    func testCachesOnlyConfirmedMissingAttribute() {
        for error: AXError in [.attributeUnsupported, .noValue, .cannotComplete, .invalidUIElement, .failure] {
            var reads = 0
            let ui = EnhancedUserInterface(read: { reads += 1; return .failure(error) }, write: { _ in XCTFail("No writes after a failed read"); return .failure })
            for _ in 0 ..< 3 { ui.acquire(); ui.release() }
            XCTAssertEqual(reads, error == .attributeUnsupported || error == .noValue ? 1 : 3)
        }
    }

    /// A game answers an AX request only every frame or two. Its frames must not wait for an answer that was false
    /// the last time
    func testFramesDontWaitForTheAnswerThatWasFalseLastTime() {
        var events: [String] = []
        let ui = EnhancedUserInterface(read: { events.append("read"); return .success(false) }, write: { _ in XCTFail("Nothing to disable"); return .failure })
        for _ in 0 ..< 3 {
            ui.acquireForBatch()
            events.append("frames")
            ui.release()
        }
        XCTAssertEqual(events, ["read", "frames", "frames", "read", "frames", "read"])
    }

    func testAttributeEnabledByAnotherClientIsNoticedAfterTheBatchAndDisabledInTheNextOne() {
        var enabled = false
        var events: [String] = []
        let ui = EnhancedUserInterface(read: { events.append("read"); return .success(enabled) }, write: { events.append("write \($0)"); return .success })
        ui.acquire()
        ui.release()
        enabled = true
        events = []
        for _ in 0 ..< 2 {
            ui.acquire()
            events.append("frames")
            ui.release()
        }
        XCTAssertEqual(events, ["frames", "read", "read", "write false", "frames", "write true"])
    }

    func testFailedAnswerAfterTheBatchIsNotTakenForFalse() {
        var answers: [AxAttributeResult<Bool>] = [.success(false), .failure(.cannotComplete), .success(false)]
        var events: [String] = []
        let ui = EnhancedUserInterface(read: { events.append("read"); return answers.removeFirst() }, write: { _ in XCTFail("Nothing to disable"); return .failure })
        for _ in 0 ..< 3 {
            ui.acquire()
            events.append("frames")
            ui.release()
        }
        // The second batch doesn't wait, the third one does: nobody knows the value after the failure
        XCTAssertEqual(events, ["read", "frames", "frames", "read", "read", "frames"])
    }

    func testFailedDisableDoesNotRestoreOrCacheTransientFailure() {
        var reads = 0
        var writes: [Bool] = []
        let ui = EnhancedUserInterface(read: { reads += 1; return .success(true) }, write: { writes.append($0); return .cannotComplete })
        for _ in 0 ..< 2 { ui.acquire(); ui.release() }
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(writes, [false, false])
    }

    func testFailedRestorationIsRetriedWithoutLosingOriginalValue() {
        var reads = 0
        var writes: [Bool] = []
        let ui = EnhancedUserInterface(read: { reads += 1; return .success(true) }, write: {
            writes.append($0)
            return writes.count == 2 ? .cannotComplete : .success
        })
        ui.acquire()
        ui.release()
        ui.acquire()
        ui.release()
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(writes, [false, true, true])
        ui.restoreIfNeeded()
        XCTAssertEqual(writes.count, 3)
    }
}
