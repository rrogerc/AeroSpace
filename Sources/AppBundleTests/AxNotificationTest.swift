@testable import AppBundle
import XCTest

final class AxNotificationTest: XCTestCase {
    func testWindowSubscriptionAvoidsAXLookupIncludingHighWindowIds() {
        for id: UInt32 in [1, 239_092, UInt32.max] {
            let context = unsafe UnsafeMutableRawPointer(bitPattern: UInt(id))
            XCTAssertEqual(unsafe notificationWindowId(context) {
                XCTFail("A known window notification must not wait on the application")
                return nil
            }, id)
        }
    }

    func testApplicationSubscriptionRetainsLookupFallback() {
        var queries = 0
        XCTAssertEqual(notificationWindowId(nil) { queries += 1; return 42 }, 42)
        XCTAssertNil(notificationWindowId(nil) { queries += 1; return nil })
        XCTAssertEqual(queries, 2)
    }

    func testInvalidContextCannotTruncateIntoAnotherWindowId() {
        let context = unsafe UnsafeMutableRawPointer(bitPattern: UInt(UInt32.max) + 2)
        var queries = 0
        XCTAssertEqual(unsafe notificationWindowId(context) { queries += 1; return 42 }, 42)
        XCTAssertEqual(queries, 1)
    }
}
