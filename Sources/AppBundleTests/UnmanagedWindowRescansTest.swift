@testable import AppBundle
import XCTest

final class UnmanagedWindowRescansTest: XCTestCase {
    func testBacksOffAndGivesUpOnAWindowThatStaysUnmanaged() {
        var rescans = UnmanagedWindowRescans()
        let game: [UInt32: pid_t] = [10: 1]
        var delays: [Duration] = []
        while let delay = rescans.nextDelay(unmanaged: game) {
            delays.append(delay)
            XCTAssertEqual(rescans.startRescan(unmanaged: game), [1])
        }
        XCTAssertEqual(delays, [.milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(8), .seconds(8)])
        XCTAssertEqual(rescans.startRescan(unmanaged: game), [])
    }

    func testNothingToRescanOnceWindowsAreManaged() {
        var rescans = UnmanagedWindowRescans()
        XCTAssertNil(rescans.nextDelay(unmanaged: [:]))
        _ = rescans.startRescan(unmanaged: [10: 1])
        XCTAssertNil(rescans.nextDelay(unmanaged: [:]))
    }

    func testNewWindowIsRescannedPromptlyAfterAnotherWindowWasGivenUpOn() {
        var rescans = UnmanagedWindowRescans()
        for _ in 0 ..< UnmanagedWindowRescans.maxRescans { _ = rescans.startRescan(unmanaged: [10: 1]) }
        XCTAssertNil(rescans.nextDelay(unmanaged: [10: 1]))

        XCTAssertEqual(rescans.nextDelay(unmanaged: [10: 1, 11: 2]), .milliseconds(250))
        XCTAssertEqual(rescans.startRescan(unmanaged: [10: 1, 11: 2]), [2])
    }

    func testWindowStartsOverOnceItWasManaged() {
        var rescans = UnmanagedWindowRescans()
        _ = rescans.startRescan(unmanaged: [10: 1])
        _ = rescans.startRescan(unmanaged: [10: 1])
        XCTAssertEqual(rescans.nextDelay(unmanaged: [10: 1]), .seconds(1))

        XCTAssertNil(rescans.nextDelay(unmanaged: [:])) // Managed now
        XCTAssertEqual(rescans.nextDelay(unmanaged: [10: 1]), .milliseconds(250))
    }
}
