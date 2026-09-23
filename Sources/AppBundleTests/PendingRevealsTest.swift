@testable import AppBundle
import CoreGraphics
import Foundation
import os
import XCTest

private let screen = Rect(topLeftX: 0, topLeftY: 0, width: 2048, height: 1152)
private let onScreen = CGRect(x: 13, y: 13, width: 2022, height: 1125)
private let hidden = CGRect(x: 2047, y: 1120, width: 2022, height: 1125) // One-point sliver in the corner
private let terminal: pid_t = 1
private let browser: pid_t = 2

final class PendingRevealsTest: XCTestCase {
    func testHideDoesNotWaitWithoutReveals() {
        let windowServer = FakeWindowServer { _, _ in [:] }
        PendingReveals(windowServerBounds: windowServer.bounds).wait(for: RunLoopJob(.cancellable), pid: terminal)
        XCTAssertEqual(windowServer.queries, [])
    }

    func testHideWaitsUntilWindowServerShowsTheRevealedWindow() {
        let windowServer = FakeWindowServer { query, _ in [10: query < 3 ? hidden : onScreen] }
        let reveals = PendingReveals(windowServerBounds: windowServer.bounds)
        reveals.add(10, pid: browser, screen: screen)
        reveals.wait(for: RunLoopJob(.cancellable), pid: terminal)
        XCTAssertEqual(windowServer.queries.count, 4)

        // Later hides don't wait either
        reveals.wait(for: RunLoopJob(.cancellable), pid: terminal)
        XCTAssertEqual(windowServer.queries.count, 5)
    }

    func testRevealsOfTheHidingAppAreNotWaitedFor() {
        let windowServer = FakeWindowServer { _, _ in [10: hidden] }
        let reveals = PendingReveals(windowServerBounds: windowServer.bounds)
        reveals.add(10, pid: browser, screen: screen)
        reveals.wait(for: RunLoopJob(.cancellable), pid: browser)
        XCTAssertEqual(windowServer.queries, [])
    }

    func testWindowThatIsHiddenAgainIsNotWaitedFor() {
        let windowServer = FakeWindowServer { _, _ in [10: hidden] }
        let reveals = PendingReveals(windowServerBounds: windowServer.bounds)
        reveals.add(10, pid: browser, screen: screen)
        reveals.remove(10)
        reveals.wait(for: RunLoopJob(.cancellable), pid: terminal)
        XCTAssertEqual(windowServer.queries, [])
    }

    func testDestroyedWindowIsNotWaitedFor() {
        let windowServer = FakeWindowServer { _, _ in [:] }
        let reveals = PendingReveals(windowServerBounds: windowServer.bounds)
        reveals.add(10, pid: browser, screen: screen)
        reveals.wait(for: RunLoopJob(.cancellable), pid: terminal)
        XCTAssertEqual(windowServer.queries.count, 1)
    }

    func testUnavailableWindowServerDoesNotHoldHidesBack() {
        let windowServer = FakeWindowServer { _, _ in nil }
        let reveals = PendingReveals(windowServerBounds: windowServer.bounds)
        reveals.add(10, pid: browser, screen: screen)
        reveals.wait(for: RunLoopJob(.cancellable), pid: terminal)
        XCTAssertEqual(windowServer.queries.count, 1)
    }

    func testBusyAppHoldsHidesBackNoLongerThanTimeout() {
        let windowServer = FakeWindowServer { _, _ in [10: hidden] }
        let reveals = PendingReveals(timeout: .milliseconds(50), windowServerBounds: windowServer.bounds)
        reveals.add(10, pid: browser, screen: screen)
        let elapsed = ContinuousClock().measure { reveals.wait(for: RunLoopJob(.cancellable), pid: terminal) }
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(50))
        XCTAssertLessThan(elapsed, .seconds(1))

        // The reveal is given up on, so later hides don't wait for it again
        let queries = windowServer.queries.count
        reveals.wait(for: RunLoopJob(.cancellable), pid: terminal)
        XCTAssertEqual(windowServer.queries.count, queries)
    }

    func testSupersededHideStopsWaiting() {
        let job = RunLoopJob(.cancellable)
        let windowServer = FakeWindowServer { query, _ in
            if query == 2 { job.cancel() } // E.g. a newer switch reveals the window again
            return [10: hidden]
        }
        let reveals = PendingReveals(timeout: .seconds(10), windowServerBounds: windowServer.bounds)
        reveals.add(10, pid: browser, screen: screen)
        let elapsed = ContinuousClock().measure { reveals.wait(for: job, pid: terminal) }
        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertEqual(windowServer.queries.count, 3)
    }

    func testRevealThatStartsWhileWaitingIsWaitedForToo() {
        let revealsRef = OSAllocatedUnfairLock<PendingReveals?>(initialState: nil)
        let windowServer = FakeWindowServer { query, windowIds in
            switch query {
                case 0:
                    // The next switch starts while the previous one is in flight
                    revealsRef.withLock { $0 }?.add(11, pid: browser, screen: screen)
                    return [10: hidden]
                case 1: return [10: onScreen, 11: hidden]
                default: return Dictionary(uniqueKeysWithValues: windowIds.map { ($0, onScreen) })
            }
        }
        let reveals = PendingReveals(windowServerBounds: windowServer.bounds)
        revealsRef.withLock { $0 = reveals }
        reveals.add(10, pid: browser, screen: screen)
        reveals.wait(for: RunLoopJob(.cancellable), pid: terminal)
        XCTAssertEqual(windowServer.queries, [[10], [10, 11], [10, 11]])
    }
}

/// Answers WindowServer queries with `respond(queryIndex, windowIds)`
private final class FakeWindowServer: Sendable {
    private let log = OSAllocatedUnfairLock(initialState: [[UInt32]]())
    private let respond: @Sendable (Int, [UInt32]) -> [UInt32: CGRect]?

    init(_ respond: @escaping @Sendable (Int, [UInt32]) -> [UInt32: CGRect]?) { self.respond = respond }

    var queries: [[UInt32]] { log.withLock { $0 } }

    var bounds: @Sendable ([UInt32]) -> [UInt32: CGRect]? {
        { [self] windowIds in
            let windowIds = windowIds.sorted()
            let query = log.withLock { log in
                log.append(windowIds)
                return log.count - 1
            }
            return respond(query, windowIds)
        }
    }
}
