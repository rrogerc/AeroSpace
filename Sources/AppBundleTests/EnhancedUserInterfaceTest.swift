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

    func testFalseIsNotCachedBecauseAnotherClientCanEnableAttribute() {
        var enabled = false
        var writes: [Bool] = []
        let ui = EnhancedUserInterface(read: { .success(enabled) }, write: { writes.append($0); return .success })
        ui.acquire()
        ui.release()
        enabled = true
        ui.acquire()
        ui.release()
        XCTAssertEqual(writes, [false, true])
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
