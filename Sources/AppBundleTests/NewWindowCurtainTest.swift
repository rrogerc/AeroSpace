@testable import AppBundle
import CoreGraphics
import Foundation
import os
import PrivateApi
import XCTest

private let home: UInt64 = 1
private let terminal: Int32 = 100
private let whereItsAppPutIt = CGRect(x: 13, y: 13, width: 2022, height: 1126)
private let tile = CGRect(x: 1031, y: 13, width: 1004, height: 1126)
private let born = AeroSpaceWindowEvent.levelChanged.rawValue
private let orderedIn = AeroSpaceWindowEvent.orderedIn.rawValue
private let closed = AeroSpaceWindowEvent.closed.rawValue

final class NewWindowCurtainTest: XCTestCase {
    func testNewWindowIsHiddenBeforeItsAppShowsItAndShownInItsTile() {
        let (curtain, driver, _) = makeCurtain()
        driver.mutate { $0.windows[10] = NewWindowInfo(pid: terminal) }
        curtain.windowEvent(born, 10)
        XCTAssertEqual(driver.read { $0.hidden }, [10], "WindowServer knows the window, and its app hasn't shown it yet")
        XCTAssertEqual(curtain.curtained, [10])
        XCTAssertEqual(driver.read { $0.watched.last }, [10])

        // Its app shows it where it likes. Nobody sees it there
        driver.show(10, at: whereItsAppPutIt)
        curtain.windowEvent(orderedIn, 10)
        XCTAssertEqual(curtain.curtained, [10])

        // AeroSpace asks the app for the frame of the tile
        curtain.manages(10)
        let job = RunLoopJob(.cancellable)
        curtain.frame(10, job, tile)
        curtain.check()
        XCTAssertEqual(curtain.curtained, [10], "The app hasn't answered")
        answer(curtain, 10, job)
        curtain.check()
        XCTAssertEqual(curtain.curtained, [10], "The app has answered, and WindowServer doesn't have the frame yet")
        XCTAssertTrue(driver.read { $0.shown.isEmpty })

        driver.mutate { $0.windows[10]?.bounds = tile }
        curtain.check()
        XCTAssertEqual(driver.read { $0.shown }, [10])
        XCTAssertTrue(curtain.curtained.isEmpty)
        XCTAssertEqual(driver.read { $0.windows[10]?.spaces }, [home])
        XCTAssertEqual(driver.read { $0.watched.last }, [])
    }

    func testFrameThatWasInPlaceBeforeTheWindowWasShown() {
        let (curtain, driver, _) = makeCurtain()
        driver.mutate { $0.windows[10] = NewWindowInfo(pid: terminal) }
        curtain.windowEvent(born, 10)
        // The app answers AX before it shows its window
        let job = RunLoopJob(.cancellable)
        curtain.frame(10, job, tile)
        answer(curtain, 10, job)
        driver.mutate { $0.windows[10]?.bounds = tile }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) {
            driver.show(10, at: tile)
            driver.mutate { $0.onScreen.insert(10) }
        }
        curtain.check()
        XCTAssertEqual(driver.read { $0.shown }, [10], "It left the curtain before its app showed it")
        XCTAssertTrue(driver.read { $0.onScreen.contains(10) }, "Its app showed it in its tile, and the others wait for that")
        XCTAssertTrue(curtain.curtained.isEmpty)
    }

    func testOpeningAnimationAndWholeCellsCountAsInPlace() {
        let (curtain, driver, _) = makeCurtain()
        driver.mutate { $0.windows[10] = NewWindowInfo(pid: terminal) }
        curtain.windowEvent(born, 10)
        driver.show(10, at: whereItsAppPutIt)
        let job = RunLoopJob(.cancellable)
        curtain.frame(10, job, tile)
        answer(curtain, 10, job)
        // macOS scales a new window around its middle while it opens
        driver.mutate { $0.windows[10]?.bounds = tile.insetBy(dx: 7, dy: 8) }
        curtain.check()
        XCTAssertEqual(driver.read { $0.shown }, [10])
    }

    func testWindowThatIsNotAWindowOfItsOwnLeavesWhenItsAppShowsIt() {
        let changes: [@Sendable (inout NewWindowInfo) -> ()] = [{ $0.parent = 5 }, { $0.level = 101 }]
        for change in changes {
            let (curtain, driver, _) = makeCurtain()
            driver.mutate { $0.windows[10] = NewWindowInfo(pid: terminal) }
            curtain.windowEvent(born, 10)
            XCTAssertEqual(curtain.curtained, [10], "At birth a menu looks like any window")
            driver.show(10, at: CGRect(x: 300, y: 300, width: 200, height: 300))
            driver.mutate { change(&$0.windows[10]!) }
            curtain.windowEvent(orderedIn, 10)
            XCTAssertEqual(driver.read { $0.shown }, [10], "A sheet, a popover or a menu never waits for a tile")
            XCTAssertTrue(curtain.curtained.isEmpty)
        }
    }

    func testAeroSpaceLooksAtTheAppWhenItShowsAWindowThatIsNotManagedYet() {
        let driver = CurtainTestDriver()
        let looked = OSAllocatedUnfairLock(initialState: [Int32]())
        let curtain = NewWindowCurtain(driver: driver, queue: nil, lookAt: { pid in looked.withLock { $0.append(pid) } })
        curtain.activate(home: home)
        // An app that has just started: AeroSpace doesn't observe it yet
        driver.mutate { $0.windows[10] = NewWindowInfo(pid: terminal); $0.windows[11] = NewWindowInfo(pid: terminal) }
        curtain.windowEvent(born, 10)
        curtain.windowEvent(born, 11)
        curtain.check()
        XCTAssertTrue(looked.withLock { $0.isEmpty }, "Its app hasn't shown anything yet")
        driver.show(10, at: whereItsAppPutIt)
        curtain.windowEvent(orderedIn, 10)
        curtain.check()
        XCTAssertEqual(looked.withLock { $0 }, [terminal], "Once")

        // Nobody has to look at the app for a menu, or for a window that is managed already
        driver.show(11, at: CGRect(x: 300, y: 300, width: 200, height: 300))
        driver.mutate { $0.windows[11]?.level = 101 }
        curtain.windowEvent(orderedIn, 11)
        driver.mutate { $0.windows[12] = NewWindowInfo(pid: terminal) }
        curtain.windowEvent(born, 12)
        curtain.manages(12)
        driver.show(12, at: whereItsAppPutIt)
        curtain.windowEvent(orderedIn, 12)
        XCTAssertEqual(looked.withLock { $0 }, [terminal])
    }

    func testAeroSpaceIsInAHurryOnlyForWindowsThatAreAboutToShowUp() {
        let (curtain, driver, clock) = makeCurtain()
        driver.mutate { $0.windows[10] = NewWindowInfo(pid: terminal) }
        curtain.windowEvent(born, 10)
        XCTAssertEqual(curtain.appsWithoutFrame, [terminal])
        XCTAssertFalse(curtain.hasManagedWindowWithoutFrame)
        // Its app doesn't show it: a window that it keeps for later
        clock.advance(NewWindowCurtainTiming().expected)
        XCTAssertTrue(curtain.appsWithoutFrame.isEmpty)
        // Now it does
        driver.show(10, at: whereItsAppPutIt)
        curtain.windowEvent(orderedIn, 10)
        XCTAssertEqual(curtain.appsWithoutFrame, [terminal])
        curtain.manages(10)
        XCTAssertTrue(curtain.hasManagedWindowWithoutFrame)
        curtain.frame(10, RunLoopJob(.cancellable), tile)
        XCTAssertTrue(curtain.appsWithoutFrame.isEmpty, "The app has been asked: nothing is left to hurry for")
        XCTAssertFalse(curtain.hasManagedWindowWithoutFrame)
    }

    func testOnlyNewWindowsThatAeroSpaceMayManageAreHidden() {
        let cases: [(String, @Sendable (inout CurtainTestDriver.State) -> ())] = [
            ("its app has shown it already", { $0.windows[10]?.isOrderedIn = true }),
            ("it's on a desktop already", { $0.windows[10]?.spaces = [home] }),
            ("it has a level", { $0.windows[10]?.level = 3 }),
            ("it has a parent", { $0.windows[10]?.parent = 5 }),
            ("its app isn't regular", { $0.windows[10] = NewWindowInfo(pid: 200) }),
            ("it's a window of AeroSpace", { $0.windows[10] = NewWindowInfo(pid: getpid()); $0.regularApps.insert(getpid()) }),
            ("a mouse button is down", { $0.mouseDown = true }),
            ("another desktop of macOS is active", { $0.activeSpace = 2 }),
            ("WindowServer doesn't know it", { $0.windows[10] = nil }),
        ]
        for (why, change) in cases {
            let (curtain, driver, _) = makeCurtain()
            driver.mutate { $0.windows[10] = NewWindowInfo(pid: terminal) }
            driver.mutate(change)
            curtain.windowEvent(born, 10)
            XCTAssertTrue(driver.read { $0.hidden.isEmpty }, why)
            XCTAssertTrue(curtain.curtained.isEmpty, why)
        }
    }

    func testNoCurtainWithoutAHome() {
        let driver = CurtainTestDriver()
        let curtain = NewWindowCurtain(driver: driver, queue: nil, lookAt: { _ in })
        driver.mutate { $0.windows[10] = NewWindowInfo(pid: terminal) }
        curtain.windowEvent(born, 10)
        XCTAssertTrue(driver.read { $0.hidden.isEmpty })

        // And none if the group can't be created
        driver.mutate { $0.canCreateGroup = false }
        curtain.activate(home: home)
        curtain.windowEvent(born, 10)
        XCTAssertTrue(driver.read { $0.hidden.isEmpty })
        XCTAssertNil(curtain.group)
    }

    func testWindowGetsTheCurtainOnceInItsLife() {
        let (curtain, driver, _) = makeCurtain()
        driver.mutate { $0.windows[10] = NewWindowInfo(pid: terminal) }
        curtain.windowEvent(born, 10)
        curtain.show(10)
        XCTAssertEqual(driver.read { $0.shown }, [10])
        // Its app changes its level again, before it has shown it
        curtain.windowEvent(born, 10)
        XCTAssertEqual(driver.read { $0.hidden }, [10])
        XCTAssertTrue(curtain.curtained.isEmpty)
    }

    func testEveryStepHasADeadline() {
        let timing = NewWindowCurtainTiming()
        let steps: [(String, Duration, @Sendable (NewWindowCurtain, CurtainTestDriver) -> ())] = [
            ("its app never shows it", timing.shown, { _, _ in }),
            ("AeroSpace doesn't manage it", timing.managed, { _, driver in driver.show(10, at: whereItsAppPutIt) }),
            ("no layout gives it a frame", timing.placed, { curtain, driver in
                driver.show(10, at: whereItsAppPutIt)
                curtain.manages(10)
            }),
            ("its app doesn't answer the frame request", timing.inPlace, { curtain, driver in
                driver.show(10, at: whereItsAppPutIt)
                curtain.frame(10, RunLoopJob(.cancellable), tile)
            }),
            ("its app answers the frame request, and never shows the window", timing.inPlace, { curtain, _ in
                let job = RunLoopJob(.cancellable)
                curtain.frame(10, job, tile)
                answer(curtain, 10, job)
            }),
        ]
        for (why, deadline, prepare) in steps {
            let (curtain, driver, clock) = makeCurtain()
            driver.mutate { $0.windows[10] = NewWindowInfo(pid: terminal) }
            curtain.windowEvent(born, 10)
            prepare(curtain, driver)
            curtain.check()
            clock.advance(deadline - .milliseconds(5))
            curtain.check()
            XCTAssertTrue(driver.read { $0.shown.isEmpty }, why)
            clock.advance(.milliseconds(5))
            curtain.check()
            XCTAssertEqual(driver.read { $0.shown }, [10], why)
            XCTAssertTrue(curtain.curtained.isEmpty, why)
        }
    }

    func testWindowThatItsAppHasShownIsNeverUnseenForLong() {
        // Every step takes almost as long as it may
        let timing = NewWindowCurtainTiming()
        let (curtain, driver, clock) = makeCurtain()
        driver.mutate { $0.windows[10] = NewWindowInfo(pid: terminal) }
        curtain.windowEvent(born, 10)
        driver.show(10, at: whereItsAppPutIt)
        curtain.check()
        clock.advance(timing.managed - .milliseconds(10))
        curtain.manages(10)
        curtain.check()
        clock.advance(timing.placed - .milliseconds(10))
        curtain.frame(10, RunLoopJob(.cancellable), tile)
        curtain.check()
        XCTAssertTrue(driver.read { $0.shown.isEmpty })
        clock.advance(timing.unseen - (timing.managed + timing.placed - .milliseconds(20)))
        curtain.check()
        XCTAssertEqual(driver.read { $0.shown }, [10])
    }

    func testAnotherLayoutAsksForAnotherFrame() {
        let (curtain, driver, _) = makeCurtain()
        driver.mutate { $0.windows[10] = NewWindowInfo(pid: terminal) }
        curtain.windowEvent(born, 10)
        driver.show(10, at: whereItsAppPutIt)
        let first = RunLoopJob(.cancellable)
        curtain.frame(10, first, tile)
        // A third window showed up meanwhile: the tile is smaller now
        let smaller = CGRect(x: 1031, y: 583, width: 1004, height: 556)
        let second = RunLoopJob(.cancellable)
        curtain.frame(10, second, smaller)
        first.cancel()
        first.complete()
        driver.mutate { $0.windows[10]?.bounds = tile }
        curtain.check()
        XCTAssertTrue(driver.read { $0.shown.isEmpty }, "The frame of the first layout isn't the tile anymore")
        answer(curtain, 10, second)
        driver.mutate { $0.windows[10]?.bounds = smaller }
        curtain.check()
        XCTAssertEqual(driver.read { $0.shown }, [10])
    }

    func testClosedAndVanishedWindowsAreForgotten() {
        let (curtain, driver, _) = makeCurtain()
        driver.mutate { $0.windows[10] = NewWindowInfo(pid: terminal); $0.windows[11] = NewWindowInfo(pid: terminal) }
        curtain.windowEvent(born, 10)
        curtain.windowEvent(born, 11)
        XCTAssertEqual(curtain.curtained, [10, 11])
        curtain.windowEvent(closed, 10)
        XCTAssertEqual(curtain.curtained, [11])
        XCTAssertTrue(driver.read { $0.shown.isEmpty }, "WindowServer said that the window is closed")
        // WindowServer doesn't know the window anymore, or it didn't answer. A window that is still there mustn't
        // stay unseen, so it's taken out of the group anyway
        driver.mutate { $0.windows[11] = nil }
        curtain.check()
        XCTAssertTrue(curtain.curtained.isEmpty)
        XCTAssertEqual(driver.read { $0.shown }, [11])
    }

    func testWindowOfAHiddenWorkspaceIsForgottenWhenItIsParked() {
        let (curtain, driver, _) = makeCurtain()
        driver.mutate { $0.windows[10] = NewWindowInfo(pid: terminal) }
        curtain.windowEvent(born, 10)
        curtain.forget([10])
        XCTAssertTrue(curtain.curtained.isEmpty)
        XCTAssertTrue(driver.read { $0.shown.isEmpty })
        XCTAssertEqual(driver.read { $0.watched.last }, [])
    }

    func testWindowThatCouldNotLeaveTriesAgain() {
        let (curtain, driver, _) = makeCurtain()
        driver.mutate { $0.windows[10] = NewWindowInfo(pid: terminal); $0.failShow = true }
        curtain.windowEvent(born, 10)
        curtain.show(10)
        XCTAssertEqual(curtain.curtained, [10])
        driver.mutate { $0.failShow = false }
        curtain.check()
        XCTAssertEqual(curtain.curtained, [10], "Its app hasn't shown it, and no deadline has passed")
        driver.show(10, at: whereItsAppPutIt)
        driver.mutate { $0.windows[10]?.level = 3 }
        curtain.check()
        XCTAssertEqual(driver.read { $0.shown }, [10])
    }

    func testWindowThatCanNeverLeaveTakesTheCurtainDown() {
        let (curtain, driver, _) = makeCurtain()
        let group = curtain.group!
        driver.mutate { $0.windows[10] = NewWindowInfo(pid: terminal); $0.failShow = true }
        curtain.windowEvent(born, 10)
        curtain.show(10)
        curtain.show(10)
        XCTAssertEqual(curtain.curtained, [10])
        XCTAssertTrue(driver.read { $0.destroyed.isEmpty })
        // WindowManager doesn't take the window out of the group. WindowServer does, when the group goes
        curtain.show(10)
        XCTAssertEqual(driver.read { $0.destroyed }, [group])
        XCTAssertTrue(curtain.curtained.isEmpty)
        XCTAssertNil(curtain.group)
    }

    func testGroupThatCanNotBeCreatedIsNotTriedWithEveryLayout() {
        let driver = CurtainTestDriver()
        let clock = TestClock()
        let curtain = NewWindowCurtain(driver: driver, clock: { clock.now }, queue: nil, lookAt: { _ in })
        driver.mutate { $0.canCreateGroup = false }
        curtain.activate(home: home)
        driver.mutate { $0.canCreateGroup = true }
        curtain.activate(home: home)
        XCTAssertNil(curtain.group)
        clock.advance(NewWindowCurtainTiming().noGroup)
        curtain.activate(home: home)
        XCTAssertNotNil(curtain.group)
    }

    func testWindowThatIsBackBehindTheCurtainLeavesAgain() {
        let (curtain, driver, clock) = makeCurtain()
        driver.mutate { $0.windows[10] = NewWindowInfo(pid: terminal) }
        curtain.windowEvent(born, 10)
        curtain.show(10)
        XCTAssertEqual(driver.read { $0.shown }, [10])
        // WindowManager got to the request that hides the window after the one that shows it
        let group = curtain.group!
        driver.mutate { $0.windows[10]?.spaces = [group] }
        curtain.check()
        XCTAssertEqual(driver.read { $0.shown }, [10, 10])
        // Not forever
        clock.advance(NewWindowCurtainTiming().lookedAfter)
        driver.mutate { $0.windows[10]?.spaces = [group] }
        curtain.check()
        XCTAssertEqual(driver.read { $0.shown }, [10, 10])
    }

    func testWindowsThatMakeRoomWaitUntilTheNewWindowIsOnScreen() {
        let (curtain, driver, _) = makeCurtain()
        driver.mutate { $0.windows[10] = NewWindowInfo(pid: terminal); $0.staysOffScreen = true }
        curtain.windowEvent(born, 10)
        driver.show(10, at: whereItsAppPutIt)
        let frame = RunLoopJob(.cancellable)
        curtain.frame(10, frame, tile)
        answer(curtain, 10, frame)
        driver.mutate { $0.windows[10]?.bounds = tile }

        let waited = OSAllocatedUnfairLock(initialState: false)
        let other = Thread {
            XCTAssertTrue(curtain.wait(for: [10], RunLoopJob(.cancellable)), "The new window is in its tile: the others make room")
            waited.withLock { $0 = true }
        }
        other.start()
        // The window leaves the curtain on this thread, and is on screen a little later
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(30)) {
            XCTAssertFalse(waited.withLock { $0 }, "The window is out of the curtain, and not on screen yet")
            driver.mutate { $0.staysOffScreen = false; $0.onScreen.insert(10) }
        }
        curtain.check()
        XCTAssertEqual(driver.read { $0.shown }, [10])
        let deadline = ContinuousClock.now + .seconds(2)
        while !waited.withLock({ $0 }) && ContinuousClock.now < deadline { usleep(1000) }
        XCTAssertTrue(waited.withLock { $0 })
    }

    func testNobodyWaitsForAWindowThatIsNotBehindTheCurtain() {
        let (curtain, driver, _) = makeCurtain()
        let started = ContinuousClock.now
        XCTAssertTrue(curtain.wait(for: [10], RunLoopJob(.cancellable)))
        // A frame that is cancelled doesn't wait either
        driver.mutate { $0.windows[10] = NewWindowInfo(pid: terminal) }
        curtain.windowEvent(born, 10)
        curtain.frame(10, RunLoopJob(.cancellable), tile)
        _ = curtain.wait(for: [10], RunLoopJob.cancelled)
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(200))
    }

    func testWindowsThatMakeRoomDoNotWaitForever() {
        let driver = CurtainTestDriver()
        let curtain = NewWindowCurtain(driver: driver, timing: NewWindowCurtainTiming(others: .milliseconds(30)), queue: nil, lookAt: { _ in })
        curtain.activate(home: home)
        driver.mutate { $0.windows[10] = NewWindowInfo(pid: terminal) }
        curtain.windowEvent(born, 10)
        // Its app doesn't answer
        curtain.frame(10, RunLoopJob(.cancellable), tile)
        let started = ContinuousClock.now
        XCTAssertTrue(curtain.wait(for: [10], RunLoopJob(.cancellable)), "Then they make room for a window that isn't there")
        XCTAssertGreaterThanOrEqual(started.duration(to: .now), .milliseconds(30))
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
    }

    func testDeactivationShowsEveryWindowAndRemovesTheGroup() {
        let (curtain, driver, _) = makeCurtain()
        let group = curtain.group!
        // Window 12 joined the group a moment ago, and nobody knows of it yet
        driver.mutate { $0.windows[10] = NewWindowInfo(pid: terminal); $0.windows[12] = NewWindowInfo(pid: terminal, spaces: [group]) }
        curtain.windowEvent(born, 10)
        curtain.deactivate()
        XCTAssertEqual(driver.read { $0.shown.sorted() }, [10, 12])
        XCTAssertEqual(driver.read { $0.destroyed }, [group])
        XCTAssertNil(curtain.group)
        XCTAssertTrue(curtain.curtained.isEmpty)

        // No curtain until AeroSpace hides windows again. Then it's a new group
        driver.mutate { $0.windows[11] = NewWindowInfo(pid: terminal) }
        curtain.windowEvent(born, 11)
        XCTAssertEqual(driver.read { $0.hidden }, [10])
        curtain.activate(home: home)
        XCTAssertNotEqual(curtain.group, group)
        curtain.windowEvent(born, 11)
        XCTAssertEqual(driver.read { $0.hidden }, [10, 11])
    }

    func testFrameOfANewerLayoutIsNotAnsweredByTheOlderOne() {
        let (curtain, driver, clock) = makeCurtain()
        driver.mutate { $0.windows[10] = NewWindowInfo(pid: terminal) }
        curtain.windowEvent(born, 10)
        driver.show(10, at: whereItsAppPutIt)
        let first = RunLoopJob(.cancellable)
        curtain.frame(10, first, tile)
        answer(curtain, 10, first)
        curtain.check()
        // The app has answered the first request, and keeps its frame for now. Then another layout asks again
        let second = RunLoopJob(.cancellable)
        curtain.frame(10, second, tile)
        clock.advance(NewWindowCurtainTiming().refused)
        curtain.check()
        XCTAssertTrue(driver.read { $0.shown.isEmpty }, "The app hasn't answered the second request yet")
        XCTAssertFalse(curtain.hasManagedWindowWithoutFrame, "And nobody has to ask a third time")
        answer(curtain, 10, second)
        driver.mutate { $0.windows[10]?.bounds = tile }
        curtain.check()
        XCTAssertEqual(driver.read { $0.shown }, [10])
    }

    func testFrameThatNobodyAskedForIsNoFrame() {
        let (curtain, driver, clock, looked) = makeCurtainThatLooks()
        driver.mutate { $0.windows[10] = NewWindowInfo(pid: terminal) }
        curtain.windowEvent(born, 10)
        // AeroSpace finds the window through its app, before the app has shown it. The job of its frame ends
        // without asking the app (the window wasn't ready for a frame)
        curtain.manages(10)
        let dropped = RunLoopJob(.cancellable)
        curtain.frame(10, dropped, tile)
        XCTAssertFalse(curtain.hasManagedWindowWithoutFrame)
        dropped.complete()
        curtain.check()
        XCTAssertTrue(curtain.hasManagedWindowWithoutFrame, "The next layout asks for the frame right away")
        XCTAssertTrue(looked.withLock { $0.isEmpty }, "Its app hasn't shown it: looking now wouldn't change anything")
        XCTAssertFalse(curtain.wait(for: [10], RunLoopJob(.cancellable)), "Nobody makes room for a window without a frame")

        // Its app shows it. The window doesn't wait until a deadline shows it where its app put it
        driver.show(10, at: whereItsAppPutIt)
        curtain.windowEvent(orderedIn, 10)
        XCTAssertEqual(looked.withLock { $0 }, [terminal])
        clock.advance(NewWindowCurtainTiming().refused * 2)
        curtain.check()
        XCTAssertEqual(curtain.curtained, [10], "Nobody asked its app: that's not an app that keeps another frame")
        XCTAssertEqual(looked.withLock { $0 }, [terminal])

        let job = RunLoopJob(.cancellable)
        curtain.frame(10, job, tile)
        XCTAssertFalse(curtain.hasManagedWindowWithoutFrame)
        answer(curtain, 10, job)
        driver.mutate { $0.windows[10]?.bounds = tile }
        curtain.check()
        XCTAssertEqual(driver.read { $0.shown }, [10])
        XCTAssertEqual(looked.withLock { $0 }, [terminal], "It's in its tile: nothing is left to look at")
    }

    func testFrameOfAShownWindowThatNobodyAskedForIsAskedForAtOnce() {
        let (curtain, driver, _, looked) = makeCurtainThatLooks()
        driver.mutate { $0.windows[10] = NewWindowInfo(pid: terminal) }
        curtain.windowEvent(born, 10)
        curtain.manages(10)
        driver.show(10, at: whereItsAppPutIt)
        curtain.windowEvent(orderedIn, 10)
        XCTAssertTrue(looked.withLock { $0.isEmpty }, "AeroSpace manages it, and its layout is on the way")
        // A command came in between: the job of the frame was cancelled before it asked
        let job = RunLoopJob(.cancellable)
        curtain.frame(10, job, tile)
        job.cancel()
        job.complete()
        curtain.check()
        XCTAssertEqual(looked.withLock { $0 }, [terminal])
        XCTAssertEqual(curtain.appsWithoutFrame, [terminal], "And the refresh doesn't wait for more events")
    }

    func testAeroSpaceIsNotToldToLookAgainAndAgain() {
        let (curtain, driver, _, looked) = makeCurtainThatLooks()
        driver.mutate { $0.windows[10] = NewWindowInfo(pid: terminal) }
        curtain.windowEvent(born, 10)
        driver.show(10, at: whereItsAppPutIt)
        curtain.windowEvent(orderedIn, 10)
        XCTAssertEqual(looked.withLock { $0 }, [terminal], "It isn't managed yet")
        // Whatever keeps the jobs from asking, it lasts
        for _ in 0 ..< 5 {
            let job = RunLoopJob(.cancellable)
            curtain.frame(10, job, tile)
            job.complete()
            curtain.check()
        }
        XCTAssertEqual(looked.withLock { $0 }, [terminal, terminal, terminal])
        XCTAssertEqual(curtain.curtained, [10])
    }

    func testWindowIsNotJudgedBeforeItsAppHasShownIt() {
        let timing = NewWindowCurtainTiming()
        let (curtain, driver, clock, looked) = makeCurtainThatLooks()
        driver.mutate { $0.windows[10] = NewWindowInfo(pid: terminal) }
        curtain.windowEvent(born, 10)
        curtain.manages(10)
        // The app answers before it shows the window. WindowServer has no frame at all for the window until then
        let job = RunLoopJob(.cancellable)
        curtain.frame(10, job, tile)
        answer(curtain, 10, job)
        curtain.check()
        clock.advance(timing.refused * 3)
        curtain.check()
        XCTAssertEqual(curtain.curtained, [10])
        XCTAssertTrue(looked.withLock { $0.isEmpty }, "That's not an app that keeps another frame")
        XCTAssertFalse(curtain.hasManagedWindowWithoutFrame)

        // It shows the window, and WindowServer gets the frame a moment later
        driver.show(10, at: whereItsAppPutIt)
        curtain.windowEvent(orderedIn, 10)
        clock.advance(timing.refused - .milliseconds(5))
        curtain.check()
        XCTAssertEqual(curtain.curtained, [10])
        XCTAssertTrue(looked.withLock { $0.isEmpty })
        driver.mutate { $0.windows[10]?.bounds = tile }
        curtain.check()
        XCTAssertEqual(driver.read { $0.shown }, [10])
    }

    func testAppThatHasAnotherFrameIsAskedOnceMore() {
        let timing = NewWindowCurtainTiming()
        let (curtain, driver, clock, looked) = makeCurtainThatLooks()
        driver.mutate { $0.windows[10] = NewWindowInfo(pid: terminal) }
        curtain.windowEvent(born, 10)
        curtain.manages(10)
        // The app answers, and then shows the window with a frame of its own (its default size)
        let first = RunLoopJob(.cancellable)
        curtain.frame(10, first, tile)
        answer(curtain, 10, first)
        curtain.check()
        driver.show(10, at: whereItsAppPutIt)
        curtain.windowEvent(orderedIn, 10)
        clock.advance(timing.refused - .milliseconds(5))
        curtain.check()
        XCTAssertTrue(looked.withLock { $0.isEmpty }, "WindowServer may get the frame any moment")
        clock.advance(.milliseconds(5))
        curtain.check()
        XCTAssertEqual(curtain.curtained, [10], "Nobody has seen it where its app put it")
        XCTAssertEqual(looked.withLock { $0 }, [terminal])
        XCTAssertTrue(curtain.hasManagedWindowWithoutFrame)
        XCTAssertFalse(curtain.wait(for: [10], RunLoopJob(.cancellable)), "The windows of the first layout don't make room yet")

        // The second request finds the window as its app left it, and the app takes the frame
        let second = RunLoopJob(.cancellable)
        curtain.frame(10, second, tile)
        answer(curtain, 10, second)
        driver.mutate { $0.windows[10]?.bounds = tile }
        curtain.check()
        XCTAssertEqual(driver.read { $0.shown }, [10])
        XCTAssertEqual(looked.withLock { $0 }, [terminal])
    }

    func testAppThatKeepsAnotherFrameShowsItsWindowAsItIs() {
        let timing = NewWindowCurtainTiming()
        let (curtain, driver, clock, looked) = makeCurtainThatLooks()
        driver.mutate { $0.windows[10] = NewWindowInfo(pid: terminal) }
        curtain.windowEvent(born, 10)
        driver.show(10, at: whereItsAppPutIt)
        curtain.manages(10)
        // A window that can't be as small as its tile
        for attempt in 1 ... 2 {
            let job = RunLoopJob(.cancellable)
            curtain.frame(10, job, tile)
            answer(curtain, 10, job)
            curtain.check()
            clock.advance(timing.refused - .milliseconds(5))
            curtain.check()
            XCTAssertTrue(driver.read { $0.shown.isEmpty }, "Request \(attempt)")
            clock.advance(.milliseconds(5))
            curtain.check()
        }
        XCTAssertEqual(driver.read { $0.shown }, [10], "It was asked twice, and not a third time")
        XCTAssertEqual(looked.withLock { $0 }, [terminal])
    }

    func testWindowThatLeavesWithoutItsFrameIsLaidOutAfterThat() {
        let (curtain, driver, clock, looked) = makeCurtainThatLooks()
        driver.mutate { $0.windows[10] = NewWindowInfo(pid: terminal); $0.windows[11] = NewWindowInfo(pid: terminal) }
        curtain.windowEvent(born, 10)
        driver.show(10, at: whereItsAppPutIt)
        curtain.manages(10)
        curtain.check()
        // A layout didn't ask for its frame, so the other windows of that layout didn't make room
        XCTAssertFalse(curtain.wait(for: [10], RunLoopJob(.cancellable)))
        XCTAssertTrue(looked.withLock { $0.isEmpty })
        // And no other layout came. It shows up where its app put it, on top of the others
        clock.advance(NewWindowCurtainTiming().placed)
        curtain.check()
        XCTAssertEqual(driver.read { $0.shown }, [10])
        XCTAssertEqual(looked.withLock { $0 }, [terminal], "Now a layout puts it into its tile, and the others make room")

        // The same for a window that is gone, or parked with a hidden workspace
        curtain.windowEvent(born, 11)
        curtain.manages(11)
        XCTAssertFalse(curtain.wait(for: [11], RunLoopJob(.cancellable)))
        curtain.forget([11])
        XCTAssertEqual(looked.withLock { $0 }, [terminal, terminal])
    }

    func testCurtainKnowsWhoseAWindowIsBeforeItHasASize() {
        let (curtain, driver, _) = makeCurtain()
        driver.mutate { $0.windows[10] = NewWindowInfo(pid: terminal) }
        curtain.windowEvent(born, 10)
        XCTAssertEqual(curtain.owners, [10: terminal])
        curtain.forget([10])
        XCTAssertTrue(curtain.owners.isEmpty)
    }

    func testGroupThatCouldNotBeRemovedIsRemovedLater() {
        let (curtain, driver, _) = makeCurtain()
        let group = curtain.group!
        driver.mutate { $0.failDestroy = true }
        curtain.deactivate()
        XCTAssertTrue(driver.read { $0.destroyed.isEmpty })
        driver.mutate { $0.failDestroy = false }
        curtain.activate(home: home)
        XCTAssertEqual(driver.read { $0.destroyed }, [group])
    }
}

private func makeCurtain() -> (NewWindowCurtain, CurtainTestDriver, TestClock) {
    let (curtain, driver, clock, _) = makeCurtainThatLooks()
    return (curtain, driver, clock)
}

/// The last value has the apps that AeroSpace was told to look at
private func makeCurtainThatLooks() -> (NewWindowCurtain, CurtainTestDriver, TestClock, OSAllocatedUnfairLock<[Int32]>) {
    let driver = CurtainTestDriver()
    let clock = TestClock()
    let looked = OSAllocatedUnfairLock(initialState: [Int32]())
    let curtain = NewWindowCurtain(driver: driver, clock: { clock.now }, queue: nil, lookAt: { pid in looked.withLock { $0.append(pid) } })
    curtain.activate(home: home)
    return (curtain, driver, clock, looked)
}

/// The job of a frame asks the app, and the app answers
private func answer(_ curtain: NewWindowCurtain, _ id: UInt32, _ job: RunLoopJob) {
    curtain.asking(id, job)
    job.complete()
}

private final class TestClock: Sendable {
    private let time = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
    var now: ContinuousClock.Instant { time.withLock { $0 } }
    func advance(_ duration: Duration) { time.withLock { $0 += duration } }
}

private final class CurtainTestDriver: NewWindowCurtainDriver, Sendable {
    struct State {
        var windows: [UInt32: NewWindowInfo] = [:]
        var onScreen: Set<UInt32> = []
        /// A window that leaves the curtain isn't on screen at once
        var staysOffScreen = false
        var activeSpace: UInt64 = home
        var regularApps: Set<Int32> = [terminal]
        var mouseDown = false
        var canCreateGroup = true
        var created: [UInt64] = []
        var destroyed: [UInt64] = []
        var failDestroy = false
        var hidden: [UInt32] = []
        var shown: [UInt32] = []
        var failShow = false
        var watched: [[UInt32]] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func read<T: Sendable>(_ body: @Sendable (State) -> T) -> T { state.withLock { body($0) } }
    func mutate(_ body: @Sendable (inout State) -> ()) { state.withLock(body) }

    /// What its app does when it shows the window. A window that is in a group already doesn't join the desktop
    func show(_ id: UInt32, at bounds: CGRect) {
        state.withLock { state in
            state.windows[id]?.isOrderedIn = true
            state.windows[id]?.bounds = bounds
        }
    }

    func window(_ id: UInt32) -> NewWindowInfo? { state.withLock { $0.windows[id] } }
    func isOnScreen(_ id: UInt32) -> Bool { state.withLock { $0.onScreen.contains(id) } }
    func activeSpace() -> UInt64 { state.withLock { $0.activeSpace } }
    func isRegularApp(_ pid: Int32) -> Bool { state.withLock { $0.regularApps.contains(pid) } }
    func isMouseButtonDown() -> Bool { state.withLock { $0.mouseDown } }

    func createGroup() -> WorkspaceVisibilityGroup? {
        state.withLock { state in
            guard state.canCreateGroup else { return nil }
            let id = UInt64(300 + state.created.count)
            state.created.append(id)
            return WorkspaceVisibilityGroup(id: id, name: "new windows \(id)")
        }
    }

    func destroy(_ group: WorkspaceVisibilityGroup, home: UInt64) -> Bool {
        state.withLock { state in
            if state.failDestroy { return false }
            state.destroyed.append(group.id)
            return true
        }
    }

    func hide(_ id: UInt32, in group: WorkspaceVisibilityGroup) -> Bool {
        state.withLock { state in
            state.hidden.append(id)
            state.windows[id]?.spaces = [group.id]
            return true
        }
    }

    func show(_ id: UInt32, from group: WorkspaceVisibilityGroup, home: UInt64) -> Bool {
        state.withLock { state in
            if state.failShow { return false }
            state.shown.append(id)
            let isOrderedIn = state.windows[id]?.isOrderedIn == true
            state.windows[id]?.spaces = isOrderedIn ? [home] : []
            if isOrderedIn && !state.staysOffScreen { state.onScreen.insert(id) }
            return true
        }
    }

    func windows(in group: WorkspaceVisibilityGroup) -> [UInt32]? {
        state.withLock { state in state.windows.filter { $0.value.spaces.contains(group.id) }.map(\.key) }
    }

    func watch(_ ids: [UInt32]) { state.withLock { $0.watched.append(ids.sorted()) } }
}
