@testable import AppBundle
import XCTest

@MainActor
final class ActiveLookTest: XCTestCase {
    func testWindowOfAnotherAppGetsTheEvents() {
        XCTAssertEqual(kind(pid: 200, frontmostPid: 100), .events)
        XCTAssertEqual(kind(pid: 200, frontmostPid: nil), .events)
        // How many windows the app has doesn't matter: it isn't active, so none of them looks active
        XCTAssertEqual(kind(pid: 200, frontmostPid: 100, appWindowsCount: 1, appMainWindowId: 20), .events)
    }

    func testAnotherWindowOfTheFrontmostAppBecomesItsMainWindow() {
        XCTAssertEqual(kind(pid: 100, frontmostPid: 100, appWindowsCount: 2, appMainWindowId: 10), .mainWindow)
        XCTAssertEqual(kind(pid: 100, frontmostPid: 100, appWindowsCount: 2, appMainWindowId: nil), .mainWindow)
    }

    func testMainWindowOfTheFrontmostAppLooksActiveAsItIs() {
        // E.g. on the way back from an empty workspace, or a game with its only window
        XCTAssertNil(kind(pid: 100, frontmostPid: 100, appWindowsCount: 2, appMainWindowId: 20))
        XCTAssertNil(kind(pid: 100, frontmostPid: 100, appWindowsCount: 1, appMainWindowId: nil))
    }

    func testAppThatBecomesFrontmostIsNotToldAnything() {
        let run = Scenario()
        _ = run.app.willLookActive(pid: 200, windowId: 20)
        run.frontmostPid = 200
        run.app.frontmostAppIs(200)
        run.app.focusGoes(to: 300)
        run.runLaterChecks()
        XCTAssertEqual(run.toldInactive, [], "macOS tells the app itself when it's inactive")
    }

    func testAppThatIsNotActivatedAfterAllIsToldThatItIsInactive() {
        let run = Scenario()
        _ = run.app.willLookActive(pid: 200, windowId: 20)
        run.app.frontmostAppIs(100) // Some refresh in between: the old app is still frontmost
        XCTAssertEqual(run.toldInactive, [])
        run.runLaterChecks()
        XCTAssertEqual(run.toldInactive, ["window 20 of pid 200"])
        run.runLaterChecks()
        run.app.focusGoes(to: 300)
        XCTAssertEqual(run.toldInactive.count, 1, "It's told once")
    }

    func testFocusThatGoesToAnotherAppEndsTheLookRightAway() {
        let run = Scenario()
        _ = run.app.willLookActive(pid: 200, windowId: 20)
        run.app.focusGoes(to: 200)
        XCTAssertEqual(run.toldInactive, [], "The focus of its own window is what the app is waiting for")
        run.app.focusGoes(to: 300)
        XCTAssertEqual(run.toldInactive, ["window 20 of pid 200"])
        run.runLaterChecks()
        XCTAssertEqual(run.toldInactive.count, 1)
    }

    func testAppThatIsFrontmostByTheTimeTheFocusMovesOnIsLeftToMacos() {
        let run = Scenario()
        _ = run.app.willLookActive(pid: 200, windowId: 20)
        run.frontmostPid = 200 // Activated, but no focus sync has seen it yet
        run.app.focusGoes(to: 300)
        run.runLaterChecks()
        XCTAssertEqual(run.toldInactive, [])
    }

    func testNextAppReplacesThePreviousOne() {
        let run = Scenario()
        _ = run.app.willLookActive(pid: 200, windowId: 20)
        _ = run.app.willLookActive(pid: 300, windowId: 30)
        XCTAssertEqual(run.toldInactive, ["window 20 of pid 200"])
        run.frontmostPid = 300
        run.runLaterChecks() // The check of the first app must not end the look of the second one
        XCTAssertEqual(run.toldInactive.count, 1)
    }

    func testSameAppCanLookActiveAgainBeforeItsFirstCheck() {
        let run = Scenario()
        _ = run.app.willLookActive(pid: 200, windowId: 20)
        _ = run.app.willLookActive(pid: 200, windowId: 21)
        XCTAssertEqual(run.toldInactive, [], "It's the same app: it just gets another key window")
        run.runLaterChecks()
        XCTAssertEqual(run.toldInactive, ["window 21 of pid 200"])
    }

    func testAppThatWasNotToldIsNotToldTheOppositeEither() {
        let run = Scenario()
        let token = run.app.willLookActive(pid: 200, windowId: 20)
        run.app.wasNotTold(token)
        run.app.focusGoes(to: 300)
        run.runLaterChecks()
        XCTAssertEqual(run.toldInactive, [])
    }

    func testOutdatedTokenDoesNotForgetTheCurrentApp() {
        let run = Scenario()
        let outdated = run.app.willLookActive(pid: 200, windowId: 20)
        _ = run.app.willLookActive(pid: 200, windowId: 21)
        run.app.wasNotTold(outdated)
        run.app.focusGoes(to: 300)
        XCTAssertEqual(run.toldInactive, ["window 21 of pid 200"])
    }

    private func kind(pid: pid_t, frontmostPid: pid_t?, appWindowsCount: Int = 2, appMainWindowId: UInt32? = 10) -> ActiveLook.Kind? {
        ActiveLook.kind(pid: pid, windowId: 20, frontmostPid: frontmostPid, appWindowsCount: appWindowsCount, appMainWindowId: appMainWindowId)
    }

    @MainActor
    private final class Scenario {
        var frontmostPid: pid_t? = 100
        var toldInactive: [String] = []
        private var laterChecks: [@MainActor () -> ()] = []
        private(set) lazy var app = ActiveLookingApp(
            frontmostPid: { [unowned self] in frontmostPid },
            lookInactive: { [unowned self] pid, windowId in toldInactive.append("window \(windowId) of pid \(pid)") },
            later: { [unowned self] check in laterChecks.append(check) },
        )

        func runLaterChecks() {
            let checks = laterChecks
            laterChecks = []
            for check in checks { check() }
        }
    }
}
