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

    /// Zen enables the attribute by itself: whenever it creates a window, and half a second after somebody disabled
    /// it. And it says "not implemented" when it's disabled, although it does what it's asked
    func testAppThatEnablesTheAttributeAgainAndAgainIsAskedBeforeEveryBatch() {
        var enabled = true
        var events: [String] = []
        let ui = EnhancedUserInterface(read: { events.append("read \(enabled)"); return .success(enabled) }, write: {
            events.append("write \($0)")
            enabled = $0
            return .notImplemented
        })
        // A new window: its frames, and the frames of the layout that follows 100 ms later
        for _ in 0 ..< 2 {
            ui.acquireForBatch()
            events.append("frames")
            ui.release()
        }
        XCTAssertEqual(events, ["read true", "write false", "frames", "read false", "frames"])
        // The next new window. The answer was false the last time, and it's not the answer anymore
        enabled = true
        events = []
        ui.acquireForBatch()
        events.append("frames")
        ui.release()
        XCTAssertEqual(events, ["read true", "write false", "frames"], "Asked after the frames, they were animated")
    }

    func testFramesOfANewWindowWaitForTheAnswerWhateverItWasLastTime() {
        var enabled = false
        var events: [String] = []
        let ui = EnhancedUserInterface(read: { events.append("read"); return .success(enabled) }, write: { events.append("write \($0)"); return .success })
        ui.acquire()
        ui.release()
        // The app never had the attribute enabled, as far as anybody knows. It has now
        enabled = true
        events = []
        ui.acquireForBatch(askFirst: true)
        events.append("frames")
        ui.release()
        XCTAssertEqual(events, ["read", "write false", "frames", "write true"])

        // The same in a batch that began with the frame of another window
        let other = EnhancedUserInterface(read: { events.append("read"); return .success(enabled) }, write: { events.append("write \($0)"); return .success })
        enabled = false
        other.acquire()
        other.release()
        enabled = true
        events = []
        other.acquireForBatch()
        events.append("frames of another window")
        other.acquireForBatch(askFirst: true)
        events.append("frames of the new window")
        other.release()
        XCTAssertEqual(events, ["frames of another window", "read", "write false", "frames of the new window", "write true"])
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
