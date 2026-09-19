@testable import AppBundle
import ApplicationServices
import XCTest

final class NativeFocusTest: XCTestCase {
    func testPrivateFocusRaisesTheTargetWithoutPublicActivation() throws {
        for activationOnly in [true, false] {
            let run = Scenario(activationOnly: activationOnly)
            try run.focus()
            XCTAssertEqual(run.events, ["private", "raise"])
        }
    }

    func testUnavailableOrFailedPrivateFocusPreservesBothPublicPaths() throws {
        for activationOnly in [true, false] {
            let run = Scenario(activationOnly: activationOnly, privateSucceeds: false)
            try run.focus()
            XCTAssertEqual(run.events, activationOnly ? ["private", "activate"] : ["private", "main", "raise", "activate"])
        }
    }

    func testPreparedSoleWindowDoesNotRaiseAgain() throws {
        let run = Scenario(privateRaiseRequired: false)
        try run.focus()
        XCTAssertEqual(run.events, ["private"])
    }

    func testFailedPreparationKeepsPublicFallbackWhenPrivateRaiseIsSkipped() throws {
        for activationOnly in [true, false] {
            let run = Scenario(activationOnly: activationOnly, privateSucceeds: false, privateRaiseRequired: false)
            try run.focus()
            XCTAssertEqual(run.events, activationOnly ? ["private", "activate"] : ["private", "main", "raise", "activate"])
        }
    }

    func testSkippedRaiseStillChecksCancellationAfterPreparation() {
        let run = Scenario(cancelAfter: "private", privateRaiseRequired: false)
        XCTAssertThrowsError(try run.focus())
        XCTAssertEqual(run.events, ["private"])
    }

    func testPrivateRaiseFailureFallsBackToPublicActivation() throws {
        let run = Scenario(activationOnly: true, raiseResult: .cannotComplete)
        try run.focus()
        XCTAssertEqual(run.events, ["private", "raise", "activate"])
    }

    func testSupersededQueuedFocusDoesNotActivateOrRaiseAnything() {
        let run = Scenario()
        run.job.cancel()
        XCTAssertThrowsError(try run.focus())
        XCTAssertEqual(run.events, [])
    }

    func testCancellationDuringPrivateActivationStopsRaiseAndFallback() {
        for privateSucceeds in [true, false] {
            let run = Scenario(privateSucceeds: privateSucceeds, cancelAfter: "private")
            XCTAssertThrowsError(try run.focus())
            XCTAssertEqual(run.events, ["private"])
        }
    }

    func testCancellationDuringFailedPrivateRaiseDoesNotReactivateAnOldApp() {
        let run = Scenario(raiseResult: .cannotComplete, cancelAfter: "raise")
        XCTAssertThrowsError(try run.focus())
        XCTAssertEqual(run.events, ["private", "raise"])
    }

    func testCancellationBetweenPublicAXCallsStopsStaleActivation() {
        for cancelAfter in ["main", "raise"] {
            let run = Scenario(activationOnly: false, privateSucceeds: false, cancelAfter: cancelAfter)
            XCTAssertThrowsError(try run.focus())
            XCTAssertEqual(run.events, cancelAfter == "main" ? ["private", "main"] : ["private", "main", "raise"])
        }
    }

    private final class Scenario {
        let job = RunLoopJob(.cancellable)
        var events: [String] = []
        let activationOnly: Bool
        let privateSucceeds: Bool
        let raiseResult: AXError
        let cancelAfter: String?
        let privateRaiseRequired: Bool

        init(activationOnly: Bool = true, privateSucceeds: Bool = true, raiseResult: AXError = .success, cancelAfter: String? = nil, privateRaiseRequired: Bool = true) {
            self.activationOnly = activationOnly
            self.privateSucceeds = privateSucceeds
            self.raiseResult = raiseResult
            self.cancelAfter = cancelAfter
            self.privateRaiseRequired = privateRaiseRequired
        }

        func record(_ event: String) {
            events.append(event)
            if cancelAfter == event { job.cancel() }
        }

        func focus() throws {
            try performNativeFocus(
                job: job,
                activationOnly: activationOnly,
                privateRaiseRequired: privateRaiseRequired,
                makeKeyWindow: { self.record("private"); return self.privateSucceeds },
                setMain: { self.record("main") },
                raise: { self.record("raise"); return self.raiseResult },
                activate: { self.record("activate") },
            )
        }
    }
}
