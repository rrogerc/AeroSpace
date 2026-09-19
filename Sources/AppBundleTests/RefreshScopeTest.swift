@testable import AppBundle
import XCTest

final class RefreshScopeTest: XCTestCase {
    func testCoalescedScopesRetainBothApplicationsAndFullRefreshes() {
        XCTAssertEqual(RefreshScope.app(1).union(.app(2)), .apps([1, 2]))
        XCTAssertEqual(RefreshScope.app(1).union(.all), .all)
        XCTAssertEqual(RefreshScope.all.union(.app(2)), .all)
        XCTAssertEqual(RefreshScope.app(nil), .all)
    }

    func testPartialDiscoveryCannotCollectOtherApplicationsWindows() {
        let scope = RefreshScope.app(1)
        XCTAssertFalse(scope.shouldCollectWindow(pid: 2, appTerminated: false, aliveIds: [], windowId: 20))
        XCTAssertFalse(scope.shouldCollectWindow(pid: 1, appTerminated: false, aliveIds: [10], windowId: 10))
        XCTAssertTrue(scope.shouldCollectWindow(pid: 1, appTerminated: false, aliveIds: [], windowId: 10))
        XCTAssertTrue(scope.shouldCollectWindow(pid: 2, appTerminated: true, aliveIds: [], windowId: 20))
    }
}
