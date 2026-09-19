@testable import AppBundle
import Foundation
import XCTest

final class NativeWorkspaceVisibilityTest: XCTestCase {
    func testFocusWaiterCanAcknowledgeVisibilityWithoutTheAsyncPollingTask() {
        let gate = NativeVisibilityGate(observe: { true })
        XCTAssertFalse(gate.isReady)
        XCTAssertTrue(gate.wait(for: RunLoopJob(.cancellable)))
        XCTAssertTrue(gate.isReady)
        // A frame waiter is released by the same acknowledgement.
        XCTAssertTrue(gate.wait(for: RunLoopJob(.cancellable)))
    }

    func testCancelledVisibilityCannotBeResurrectedByAnInFlightObservation() {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "Cancelled observation releases its waiter")
        let gate = NativeVisibilityGate(observe: {
            started.signal()
            release.wait()
            return true
        })
        DispatchQueue.global().async {
            XCTAssertFalse(gate.wait(for: RunLoopJob(.cancellable)))
            finished.fulfill()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        gate.cancel()
        release.signal()
        wait(for: [finished], timeout: 1)
        XCTAssertFalse(gate.isReady)
    }

    func testVisibilityAcknowledgementCanReleaseBothFrameAndFocusWorkers() {
        let gate = NativeVisibilityGate()
        gate.complete(true)
        gate.complete(false)
        XCTAssertTrue(gate.wait(for: RunLoopJob(.cancellable)))
        XCTAssertTrue(gate.wait(for: RunLoopJob(.cancellable)))
    }

    func testLateCompletionCannotResurrectCancelledVisibility() {
        for completeFirst in [false, true] {
            let gate = NativeVisibilityGate()
            if completeFirst { gate.complete(true) }
            gate.cancel()
            gate.complete(true)
            XCTAssertFalse(gate.wait(for: RunLoopJob(.cancellable)))
        }
    }

    func testSupersededFrameDoesNotWaitForItsOldNativeMove() {
        let gate = NativeVisibilityGate()
        let job = RunLoopJob(.cancellable)
        job.cancel()
        XCTAssertFalse(gate.wait(for: job))
    }

    func testCancellingMoveReleasesBlockedWorker() {
        let gate = NativeVisibilityGate()
        let started = DispatchSemaphore(value: 0)
        let finished = expectation(description: "Cancelled window must not remain blocked")
        DispatchQueue.global().async {
            started.signal()
            XCTAssertFalse(gate.wait(for: RunLoopJob(.cancellable)))
            finished.fulfill()
        }
        XCTAssertEqual(started.wait(timeout: .now() + .seconds(1)), .success)
        gate.cancel()
        wait(for: [finished], timeout: 1)
    }

    func testWindowIdReuseInvalidatesThePreviousOwnersGate() {
        let registry = NativeVisibilityGates()
        let old = NativeVisibilityGate()
        old.complete(true)
        registry.replace([42: (100, old)])
        let replacement = NativeVisibilityGate()
        registry.replace([42: (200, replacement)])
        XCTAssertNil(registry.get(42, pid: 100))
        XCTAssertTrue(registry.get(42, pid: 200) === replacement)
        XCTAssertFalse(old.wait(for: RunLoopJob(.cancellable)))
        registry.replace([:])
        XCTAssertFalse(replacement.wait(for: RunLoopJob(.cancellable)))
    }

    func testNativeSpaceSnapshotRequiresOneConsistentDisplay() throws {
        let display: [String: Any] = [
            "Display Identifier": "display", "Current Space": ["id64": 1],
            "Spaces": [["id64": 1, "type": 0], ["id64": 2, "type": 0, "name": "parking"]],
        ]
        let decoded = try XCTUnwrap(NativeDisplaySpaces.decode([display]))
        XCTAssertEqual(decoded.current, 1)
        XCTAssertEqual(decoded.spaces.map(\.id), [1, 2])
        XCTAssertEqual(decoded.spaces.last?.name, "parking")
        XCTAssertNil(NativeDisplaySpaces.decode([display, display]))
        var missingCurrent = display
        missingCurrent["Current Space"] = ["id64": 3]
        XCTAssertNil(NativeDisplaySpaces.decode([missingCurrent]))
    }

    func testMalformedOrAmbiguousSpaceIdsCannotBeUsedForMovement() {
        for bad: Any in [0, -1, 1.5, true, "1"] {
            let display: [String: Any] = [
                "Display Identifier": "display", "Current Space": ["id64": 1],
                "Spaces": [["id64": bad, "type": 0]],
            ]
            XCTAssertNil(NativeDisplaySpaces.decode([display]))
        }
        XCTAssertNil(NativeDisplaySpaces.decode([[
            "Display Identifier": "display", "Current Space": ["id64": 1],
            "Spaces": [["id64": 1, "type": 0], ["id64": 1, "type": 0]],
        ]]))
    }
}
