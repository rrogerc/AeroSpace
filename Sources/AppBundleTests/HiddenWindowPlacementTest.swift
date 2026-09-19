@testable import AppBundle
import CoreGraphics
import XCTest

final class HiddenWindowPlacementTest: XCTestCase {
    private let screen = Rect(topLeftX: 0, topLeftY: 0, width: 2048, height: 1152)
    private let target = CGPoint(x: 2047, y: 1151)
    private let clamped = CGRect(x: 2047, y: 1120, width: 800, height: 600)

    func testAcceptsObservedNativeClampWithoutRepeatedWrites() throws {
        let job = RunLoopJob(.cancellable)
        job.complete()
        var placement = HiddenWindowPlacement(target: target, frame: job)
        let observation = try observation(clamped, job)
        for _ in 0 ..< 3 {
            XCTAssertTrue(placement.matches(observation: observation, target: target, latestFrame: job, monitors: [screen]))
        }
    }

    func testExternalMoveAndResizeInvalidateAcceptedClamp() throws {
        for changed in [clamped.offsetBy(dx: -10, dy: 0), clamped.offsetBy(dx: 0, dy: -30), CGRect(x: 2047, y: 1120, width: 900, height: 600)] {
            let job = RunLoopJob(.cancellable)
            job.complete()
            var placement = HiddenWindowPlacement(target: target, frame: job)
            XCTAssertTrue(placement.matches(observation: try observation(clamped, job), target: target, latestFrame: job, monitors: [screen]))
            XCTAssertFalse(placement.matches(observation: try observation(changed, job), target: target, latestFrame: job, monitors: [screen]))
        }
    }

    func testCannotAcceptPendingCancelledOrSupersededMove() throws {
        let job = RunLoopJob(.cancellable)
        var placement = HiddenWindowPlacement(target: target, frame: job)
        let observation = try observation(clamped, job)
        XCTAssertFalse(placement.matches(observation: observation, target: target, latestFrame: job, monitors: [screen]))
        job.complete()
        let newer = RunLoopJob(.cancellable)
        newer.complete()
        XCTAssertFalse(placement.matches(observation: observation, target: target, latestFrame: newer, monitors: [screen]))
        XCTAssertFalse(placement.matches(observation: observation, target: target, latestFrame: nil, monitors: [screen]))
        XCTAssertFalse(placement.matches(observation: try self.observation(clamped, newer), target: target, latestFrame: job, monitors: [screen]))
        job.cancel()
        XCTAssertFalse(placement.matches(observation: observation, target: target, latestFrame: job, monitors: [screen]))
    }

    func testIgnoredMoveAndChangedCornerCannotBeAccepted() throws {
        let job = RunLoopJob(.cancellable)
        job.complete()
        var placement = HiddenWindowPlacement(target: target, frame: job)
        XCTAssertFalse(placement.matches(observation: try observation(CGRect(x: 13, y: 13, width: 800, height: 600), job), target: target, latestFrame: job, monitors: [screen]))
        XCTAssertFalse(placement.matches(observation: try observation(clamped, job), target: CGPoint(x: 1023, y: 767), latestFrame: job, monitors: [screen]))
        XCTAssertFalse(placement.matches(observation: nil, target: target, latestFrame: job, monitors: [screen]))
    }

    func testMustRemainHiddenOnEveryMonitorIncludingAfterTopologyChange() throws {
        let job = RunLoopJob(.cancellable)
        job.complete()
        var placement = HiddenWindowPlacement(target: target, frame: job)
        let observation = try observation(clamped, job)
        XCTAssertFalse(placement.matches(observation: observation, target: target, latestFrame: job, monitors: []))
        XCTAssertTrue(placement.matches(observation: observation, target: target, latestFrame: job, monitors: [screen]))
        let newScreen = Rect(topLeftX: 2048, topLeftY: 0, width: 2048, height: 1152)
        XCTAssertFalse(placement.matches(observation: observation, target: target, latestFrame: job, monitors: [screen, newScreen]))
    }

    func testLeftCornerAndNegativeMonitorCoordinates() throws {
        let job = RunLoopJob(.cancellable)
        job.complete()
        let screen = Rect(topLeftX: -1920, topLeftY: -1080, width: 1920, height: 1080)
        let target = CGPoint(x: -2719, y: -1)
        var placement = HiddenWindowPlacement(target: target, frame: job)
        let observation = try observation(CGRect(x: -2719, y: -32, width: 800, height: 600), job)
        XCTAssertTrue(placement.matches(observation: observation, target: target, latestFrame: job, monitors: [screen]))
    }

    private func observation(_ bounds: CGRect, _ job: RunLoopJob) throws -> HiddenWindowFrameObservation {
        let info = try XCTUnwrap(WindowServerWindowInfo([
            kCGWindowNumber as String: UInt32(1),
            kCGWindowOwnerPID as String: Int32(100),
            kCGWindowLayer as String: 0,
            kCGWindowBounds as String: bounds.dictionaryRepresentation,
        ]))
        return HiddenWindowFrameObservation(info: info, precedingFrame: job)
    }
}
