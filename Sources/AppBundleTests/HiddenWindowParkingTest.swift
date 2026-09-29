@testable import AppBundle
import Foundation
import os
import XCTest

final class HiddenWindowParkingTest: XCTestCase {
    private func windows(_ visible: UInt32 = 10, secondPid: Int32 = 200) -> [NativeVisibilityWindow] {
        [
            NativeVisibilityWindow(id: 10, pid: 100, visible: visible == 10, workspace: "1"),
            NativeVisibilityWindow(id: 20, pid: secondPid, visible: visible == 20, workspace: "2"),
        ]
    }

    private func native(_ plan: NativeVisibilityPlan, file: StaticString = #filePath, line: UInt = #line) -> [UInt32: (Int32, NativeVisibilityGate)] {
        guard case .native(let gates) = plan else {
            XCTFail("Expected native visibility", file: file, line: line)
            return [:]
        }
        return gates
    }

    func testOnlyInactiveWindowsAreParkedAndVisibleWindowsReturnExclusivelyHome() async throws {
        let driver = HiddenParkingTestDriver()
        let worker = HiddenWindowParkingWorker(driver: driver, didRecover: {})
        let first = native(await worker.apply(windows(), request: 1))
        let initialContext = await worker.context()
        let group = try XCTUnwrap(initialContext.group)
        XCTAssertEqual(driver.read { $0.memberships }, [10: [1], 20: [group]])
        XCTAssertTrue(first[10]?.1.isReady == true)
        XCTAssertFalse(try XCTUnwrap(first[20]?.1).wait(for: RunLoopJob(.cancellable)))
        let repeated = native(await worker.apply(windows(), request: 2))
        XCTAssertTrue(repeated[10]?.1 === first[10]?.1)
        XCTAssertEqual(driver.read { $0.hides }, [[20]])
        XCTAssertTrue(driver.read { $0.reveals.isEmpty })

        let next = native(await worker.apply(windows(20), request: 3))
        XCTAssertEqual(driver.read { $0.memberships }, [10: [group], 20: [1]])
        XCTAssertEqual(driver.read { $0.reveals }, [[20]])
        XCTAssertEqual(driver.read { $0.hides }, [[20], [10]])
        XCTAssertFalse(first[10]?.1.isReady == true)
        XCTAssertTrue(next[20]?.1.isReady == true)
        XCTAssertFalse(next[10]?.1.isReady == true)
        XCTAssertEqual(driver.read { $0.created.count }, 1)
        _ = await worker.stop(retry: false)
        XCTAssertEqual(driver.read { $0.memberships }, [10: [1], 20: [1]])
    }

    func testOutgoingWindowsWaitForIncomingOnScreenObservation() async {
        let driver = HiddenParkingTestDriver()
        driver.mutate { $0.owners[30] = 300; $0.memberships[30] = [1] }
        let worker = HiddenWindowParkingWorker(driver: driver, didRecover: {})
        let secondIncoming = NativeVisibilityWindow(id: 30, pid: 300, visible: false, workspace: "2")
        let original = native(await worker.apply(windows() + [secondIncoming], request: 1))
        driver.mutate {
            $0.notOnScreen = [30]
            $0.afterOnScreen = { query in
                XCTAssertEqual(driver.read { $0.hides }, [[20, 30]], "Outgoing windows must remain home until all incoming windows appear")
                XCTAssertEqual(driver.read { $0.memberships }, [10: [1], 20: [1], 30: [1]])
                XCTAssertFalse(original[20]?.1.isReady == true, "The visibility wait must not release native focus early")
                XCTAssertFalse(original[30]?.1.isReady == true)
                if query == 2 { driver.mutate { $0.notOnScreen = [] } }
            }
        }
        let incoming = windows(20) + [NativeVisibilityWindow(id: 30, pid: 300, visible: true, workspace: "2")]
        let result = native(await worker.apply(incoming, request: 2))
        XCTAssertEqual(driver.read { $0.onScreenQueries }, 3)
        XCTAssertEqual(driver.read { $0.hides }, [[20, 30], [10]])
        XCTAssertTrue(result[20]?.1.isReady == true)
        XCTAssertTrue(result[30]?.1.isReady == true)
        XCTAssertFalse(result[10]?.1.isReady == true)
        XCTAssertTrue(driver.read { $0.restores.isEmpty })
        _ = await worker.stop(retry: false)
    }

    func testAlreadyOnScreenIncomingWindowDoesNotKeepPolling() async {
        let driver = HiddenParkingTestDriver()
        let worker = HiddenWindowParkingWorker(driver: driver, didRecover: {})
        _ = native(await worker.apply(windows(), request: 1))
        _ = native(await worker.apply(windows(20), request: 2))
        XCTAssertEqual(driver.read { $0.onScreenQueries }, 1)
        XCTAssertEqual(driver.read { $0.hides }, [[20], [10]])
        _ = await worker.stop(retry: false)
    }

    func testOnScreenWaitRequiresBothIncomingAndOutgoingWindows() async {
        let driver = HiddenParkingTestDriver()
        let worker = HiddenWindowParkingWorker(driver: driver, didRecover: {})
        _ = native(await worker.apply(windows(), request: 1))
        XCTAssertEqual(driver.read { $0.onScreenQueries }, 0, "Parking alone has no incoming windows to wait for")
        let bothVisible = windows().map { NativeVisibilityWindow(id: $0.id, pid: $0.pid, visible: true, workspace: $0.workspace) }
        _ = native(await worker.apply(bothVisible, request: 2))
        XCTAssertEqual(driver.read { $0.reveals }, [[20]])
        XCTAssertEqual(driver.read { $0.onScreenQueries }, 0, "Revealing alone has no outgoing windows to retain")
        _ = native(await worker.apply(bothVisible, request: 3))
        XCTAssertEqual(driver.read { $0.onScreenQueries }, 0, "An unchanged layout needs no visibility query")
        _ = await worker.stop(retry: false)
    }

    func testUnavailableOrMissingOnScreenObservationCannotHoldHidingIndefinitely() async {
        for unavailable in [true, false] {
            let driver = HiddenParkingTestDriver()
            let worker = HiddenWindowParkingWorker(driver: driver, didRecover: {})
            _ = native(await worker.apply(windows(), request: 1))
            driver.mutate {
                $0.failOnScreen = unavailable
                $0.notOnScreen = [20]
            }
            let started = ContinuousClock.now
            let result = native(await worker.apply(windows(20), request: 2))
            XCTAssertLessThan(started.duration(to: .now), .seconds(2))
            let queries = driver.read { $0.onScreenQueries }
            if unavailable { XCTAssertEqual(queries, 1) }
            else { XCTAssertGreaterThan(queries, 1, "A missing window must be observed again before the deadline") }
            XCTAssertEqual(driver.read { $0.hides }, [[20], [10]])
            XCTAssertTrue(result[20]?.1.isReady == true, "Membership still permits focus after the bounded visual wait")
            XCTAssertTrue(driver.read { $0.restores.isEmpty })
            _ = await worker.stop(retry: false)
        }
    }

    func testNativeDesktopChangeDuringOnScreenWaitPreventsOutgoingHide() async {
        let driver = HiddenParkingTestDriver()
        let worker = HiddenWindowParkingWorker(driver: driver, didRecover: {})
        let original = native(await worker.apply(windows(), request: 1))
        driver.mutate {
            $0.notOnScreen = [20]
            $0.afterOnScreen = { _ in driver.mutate { $0.layout = HiddenParkingTestDriver.layout(current: 2, normal: [1, 2]) } }
        }
        let plan = await worker.apply(windows(20), request: 2)
        XCTAssertEqual(driver.read { $0.onScreenQueries }, 1)
        guard case .suspended = plan else { return XCTFail("Leaving home during the wait must suspend tiling") }
        XCTAssertEqual(driver.read { $0.hides }, [[20]], "The outgoing window must never be parked from another desktop")
        XCTAssertEqual(driver.read { $0.memberships }, [10: [1], 20: [1]])
        XCTAssertEqual(driver.read { $0.restores }, [1])
        XCTAssertEqual(driver.read { $0.layout?.current }, 2)
        XCTAssertFalse(original[10]?.1.isReady == true)
        _ = await worker.stop(retry: false)
    }

    func testCancellationStopsOnScreenPollingButFinishesTheMembershipTransition() async {
        let driver = HiddenParkingTestDriver()
        let worker = HiddenWindowParkingWorker(driver: driver, didRecover: {})
        _ = native(await worker.apply(windows(), request: 1))
        let entered = expectation(description: "Incoming window is not yet on screen")
        let release = DispatchSemaphore(value: 0)
        driver.mutate {
            $0.notOnScreen = [20]
            $0.afterOnScreen = { _ in entered.fulfill(); release.wait() }
        }
        let desired = windows(20)
        let refresh = Task.detached { await worker.apply(desired, request: 2) }
        await fulfillment(of: [entered], timeout: 1)
        XCTAssertEqual(driver.read { $0.hides }, [[20]])
        refresh.cancel()
        release.signal()
        let cancelled = native(await refresh.value)
        driver.mutate { $0.afterOnScreen = nil }
        XCTAssertEqual(driver.read { $0.onScreenQueries }, 1)
        XCTAssertEqual(driver.read { $0.hides }, [[20], [10]])
        XCTAssertTrue(driver.read { $0.restores.isEmpty })
        for entry in cancelled.values { XCTAssertFalse(entry.1.isReady) }
        _ = native(await worker.apply(windows(), request: 3))
        _ = await worker.stop(retry: false)
    }

    func testTwoWindowsOfTheSameAppCanHaveDifferentVisibility() async throws {
        let driver = HiddenParkingTestDriver()
        driver.mutate { $0.owners[20] = 100 }
        let worker = HiddenWindowParkingWorker(driver: driver, didRecover: {})
        let first = native(await worker.apply(windows(secondPid: 100)))
        let initialContext = await worker.context()
        let group = try XCTUnwrap(initialContext.group)
        XCTAssertEqual(first[10]?.0, 100)
        XCTAssertEqual(first[20]?.0, 100)
        XCTAssertTrue(first[10]?.1.isReady == true)
        XCTAssertFalse(first[20]?.1.isReady == true)
        _ = native(await worker.apply(windows(20, secondPid: 100)))
        XCTAssertEqual(driver.read { $0.memberships }, [10: [group], 20: [1]])
        _ = await worker.stop(retry: false)
    }

    func testRapidAndStaleRequestsKeepTheLatestDestinationAndCancelOldGates() async throws {
        let driver = HiddenParkingTestDriver()
        let worker = HiddenWindowParkingWorker(driver: driver, didRecover: {})
        let original = native(await worker.apply(windows(), request: 1))
        let initialContext = await worker.context()
        let group = try XCTUnwrap(initialContext.group)
        for request in 2 ... 20 {
            let id: UInt32 = request.isMultiple(of: 2) ? 20 : 10
            let gates = native(await worker.apply(windows(id), request: UInt64(request)))
            XCTAssertTrue(gates[id]?.1.isReady == true)
        }
        let assignments = driver.read { $0.hides.count + $0.reveals.count }
        let stale = native(await worker.apply(windows(), request: 19))
        _ = await worker.stop(request: 18)
        XCTAssertEqual(driver.read { $0.hides.count + $0.reveals.count }, assignments)
        XCTAssertTrue(driver.read { $0.restores.isEmpty })
        XCTAssertTrue(stale[20]?.1.isReady == true)
        XCTAssertFalse(original[10]?.1.isReady == true)
        XCTAssertEqual(driver.read { $0.memberships }, [10: [group], 20: [1]])
        _ = await worker.stop(retry: false, request: 21)
        _ = await worker.apply(windows(), request: 22)
        XCTAssertEqual(driver.read { $0.created.count }, 1)
    }

    func testCancelledInitialRequestNeverTouchesTheDriver() async {
        let driver = HiddenParkingTestDriver()
        let worker = HiddenWindowParkingWorker(driver: driver, didRecover: {})
        let proceed = AwaitableOneTimeBroadcastLatch()
        let desired = windows()
        let task = Task.detached {
            try? await proceed.await()
            return await worker.apply(desired)
        }
        task.cancel()
        _ = await task.value
        XCTAssertEqual(driver.read { $0.displayQueries }, 0)
        XCTAssertTrue(driver.read { $0.created.isEmpty })
    }

    func testCancelledNoOpRefreshDoesNotDiscardPendingActivation() async throws {
        let driver = HiddenParkingTestDriver()
        let worker = HiddenWindowParkingWorker(driver: driver, didRecover: {})
        let original = native(await worker.apply(windows(), request: 1))
        let gate = try XCTUnwrap(original[10]?.1)
        let releaseFocus = AwaitableOneTimeBroadcastLatch()
        let activations = OSAllocatedUnfairLock(initialState: 0)
        let focusJob = RunLoopJob(.cancellable)
        let pendingFocus = Task.detached {
            try? await releaseFocus.await()
            guard gate.wait(for: focusJob) else { return }
            try? performNativeFocus(
                job: focusJob,
                activationOnly: true,
                makeKeyWindow: { false },
                setMain: {},
                raise: { .success },
                activate: { activations.withLock { $0 += 1 } },
            )
        }

        let entered = expectation(description: "No-op refresh is querying owners")
        let release = DispatchSemaphore(value: 0)
        driver.mutate { $0.afterOwners = { _ in entered.fulfill(); release.wait() } }
        let desired = windows()
        let refresh = Task.detached { await worker.apply(desired, request: 2) }
        await fulfillment(of: [entered], timeout: 1)
        refresh.cancel()
        release.signal()
        let cancelled = native(await refresh.value)
        driver.mutate { $0.afterOwners = nil }
        XCTAssertTrue(cancelled[10]?.1 === gate)
        XCTAssertTrue(gate.isReady, "The pending focus job still holds this unchanged acknowledgement")
        XCTAssertTrue(driver.read { $0.restores.isEmpty })

        let next = native(await worker.apply(desired, request: 3))
        XCTAssertTrue(next[10]?.1 === gate, "Republishing another gate cannot rescue an already queued activation")
        await releaseFocus.signalToAll()
        await pendingFocus.value
        XCTAssertEqual(activations.withLock { $0 }, 1)
        _ = await worker.stop(retry: false, request: 4)
        XCTAssertFalse(gate.isReady)
    }

    func testCancelledNoOpCannotKeepFocusEnabledAfterLeavingTheNativeDesktop() async throws {
        let driver = HiddenParkingTestDriver()
        let worker = HiddenWindowParkingWorker(driver: driver, didRecover: {})
        let original = native(await worker.apply(windows(), request: 1))
        let gate = try XCTUnwrap(original[10]?.1)
        let entered = expectation(description: "No-op refresh is querying owners")
        let release = DispatchSemaphore(value: 0)
        driver.mutate { $0.afterOwners = { _ in entered.fulfill(); release.wait() } }
        let desired = windows()
        let refresh = Task.detached { await worker.apply(desired, request: 2) }
        await fulfillment(of: [entered], timeout: 1)
        refresh.cancel()
        driver.mutate { $0.layout = HiddenParkingTestDriver.layout(current: 2, normal: [1, 2]) }
        release.signal()
        let cancelled = native(await refresh.value)
        driver.mutate { $0.afterOwners = nil }
        XCTAssertFalse(gate.wait(for: RunLoopJob(.cancellable)))
        XCTAssertFalse(cancelled[10]?.1.isReady == true)
        XCTAssertEqual(driver.read { $0.layout?.current }, 2)

        guard case .suspended = await worker.apply(desired, request: 3) else {
            return XCTFail("The next refresh must suspend instead of activating the old desktop")
        }
        XCTAssertEqual(driver.read { $0.memberships }, [10: [1], 20: [1]])
        XCTAssertEqual(driver.read { $0.layout?.current }, 2)
        _ = await worker.stop(retry: false, request: 4)
    }

    func testCancellationKeepsOtherWorkspacesParkedUntilTheNextRequest() async throws {
        for stage in ["query", "create", "reveal", "hide", "verification"] {
            let driver = HiddenParkingTestDriver()
            driver.mutate { $0.owners[30] = 300; $0.memberships[30] = [1] }
            let recoveries = OSAllocatedUnfairLock(initialState: 0)
            let worker = HiddenWindowParkingWorker(driver: driver, didRecover: { recoveries.withLock { $0 += 1 } })
            let unrelated = NativeVisibilityWindow(id: 30, pid: 300, visible: false, workspace: "3")
            let original = stage == "create" ? [:] : native(await worker.apply(windows() + [unrelated], request: 1))
            let entered = expectation(description: "Cancelled during \(stage)")
            let release = DispatchSemaphore(value: 0)
            let pause: @Sendable () -> Void = { entered.fulfill(); release.wait() }
            let query = driver.read { $0.ownerQueries } + (stage == "verification" ? 2 : 1)
            driver.mutate {
                switch stage {
                    case "query", "verification": $0.afterOwners = { if $0 == query { pause() } }
                    case "create": $0.afterCreate = pause
                    case "reveal": $0.afterReveal = pause
                    case "hide": $0.afterHide = pause
                    default: XCTFail("Unknown cancellation stage")
                }
            }
            // Even a no-op background refresh can be cancelled by a workspace command.
            let visible: UInt32 = stage == "query" ? 10 : 20
            let desired = windows(visible) + [unrelated]
            let task = Task.detached { await worker.apply(desired, request: 2) }
            await fulfillment(of: [entered], timeout: 1)
            task.cancel()
            release.signal()
            let cancelled = native(await task.value)
            driver.mutate { $0.afterOwners = nil; $0.afterCreate = nil; $0.afterReveal = nil; $0.afterHide = nil }

            let group = try XCTUnwrap(driver.read { $0.created.first })
            let context = await worker.context()
            XCTAssertEqual(context.group, group, stage)
            XCTAssertEqual(driver.read { $0.memberships[visible] }, [1], stage)
            XCTAssertEqual(driver.read { $0.memberships[visible == 10 ? 20 : 10] }, [group], stage)
            XCTAssertEqual(driver.read { $0.memberships[30] }, [group], stage)
            XCTAssertTrue(driver.read { $0.restores.isEmpty }, stage)
            XCTAssertEqual(recoveries.withLock { $0 }, 0, stage)
            XCTAssertEqual(Set(cancelled.keys), [10, 20, 30], stage)
            for (id, entry) in cancelled {
                XCTAssertEqual(entry.1.wait(for: RunLoopJob(.cancellable)), stage == "query" && id == 10, stage)
            }
            for (id, entry) in original { XCTAssertEqual(entry.1.isReady, stage == "query" && id == 10, stage) }

            let nextVisible: UInt32 = visible == 10 ? 20 : 10
            let next = native(await worker.apply(windows(nextVisible) + [unrelated], request: 3))
            XCTAssertTrue(next[nextVisible]?.1.isReady == true, stage)
            XCTAssertFalse(next[nextVisible]?.1 === cancelled[nextVisible]?.1, stage)
            XCTAssertFalse(cancelled[visible]?.1.isReady == true, "The next destination must invalidate the previous gate: \(stage)")
            XCTAssertEqual(driver.read { $0.memberships[nextVisible] }, [1], stage)
            XCTAssertEqual(driver.read { $0.memberships[visible] }, [group], stage)
            XCTAssertEqual(driver.read { $0.memberships[30] }, [group], stage)
            XCTAssertEqual(driver.read { $0.created.count }, 1, stage)
            XCTAssertTrue(driver.read { $0.restores.isEmpty }, stage)

            let stopped = await worker.stop(retry: false, request: 4)
            XCTAssertTrue(stopped, stage)
            XCTAssertTrue(driver.read { $0.groups.isEmpty }, stage)
            XCTAssertEqual(driver.read { $0.memberships }, [10: [1], 20: [1], 30: [1]], stage)
        }
    }

    func testCancelledRegistrationStillTracksAWindowRetiredByTheNextRequest() async throws {
        let driver = HiddenParkingTestDriver()
        let worker = HiddenWindowParkingWorker(driver: driver, didRecover: {})
        _ = native(await worker.apply(windows(), request: 1))
        let entered = expectation(description: "New window parked")
        let release = DispatchSemaphore(value: 0)
        driver.mutate {
            $0.owners[30] = 300
            $0.memberships[30] = [1]
            $0.afterHide = { entered.fulfill(); release.wait() }
        }
        let desired = windows() + [NativeVisibilityWindow(id: 30, pid: 300, visible: false, workspace: "3")]
        let task = Task.detached { await worker.apply(desired, request: 2) }
        await fulfillment(of: [entered], timeout: 1)
        task.cancel()
        release.signal()
        let cancelled = native(await task.value)
        driver.mutate { $0.afterHide = nil }
        let context = await worker.context()
        let group = try XCTUnwrap(context.group)
        XCTAssertEqual(driver.read { $0.memberships[30] }, [group])
        XCTAssertNotNil(cancelled[30])
        XCTAssertTrue(driver.read { $0.restores.isEmpty })

        // The AX model can retire this live parked window before the next layout.
        // Retaining its entry is what makes that layout restore it safely.
        guard case .offscreen = await worker.apply(windows(), request: 3) else {
            return XCTFail("A newly parked live window must still be tracked after cancellation")
        }
        XCTAssertEqual(driver.read { $0.restores }, [1])
        XCTAssertEqual(driver.read { $0.memberships }, [10: [1], 20: [1], 30: [1]])
        _ = await worker.stop(retry: false)
    }

    func testFailedAssignmentStillRecoversWhenCancelled() async {
        for failRecovery in [false, true] {
            let driver = HiddenParkingTestDriver()
            let worker = HiddenWindowParkingWorker(driver: driver, retryDelay: .seconds(60), didRecover: {})
            let entered = expectation(description: "Hide submitted")
            let release = DispatchSemaphore(value: 0)
            driver.mutate {
                $0.failRestore = failRecovery
                $0.failHideAfterMove = true
                $0.afterHide = { entered.fulfill(); release.wait() }
            }
            let desired = windows()
            let task = Task.detached { await worker.apply(desired) }
            await fulfillment(of: [entered], timeout: 1)
            task.cancel()
            release.signal()
            let result = await task.value
            if failRecovery {
                guard case .recovering = result else { return XCTFail("Parked windows must block fallback until recovery succeeds") }
                XCTAssertFalse(driver.read { $0.groups.isEmpty })
                driver.mutate { $0.failRestore = false }
                let recovered = await worker.retryRecovery()
                XCTAssertTrue(recovered)
            } else {
                guard case .offscreen = result else { return XCTFail("Confirmed cleanup permits fallback") }
            }
            XCTAssertTrue(driver.read { $0.groups.isEmpty })
            XCTAssertEqual(driver.read { $0.memberships }, [10: [1], 20: [1]])
            _ = await worker.stop(retry: false)
        }
    }

    func testLiveRetirementRestoresParkedWindowsBeforeReleasingTheirGates() async {
        let driver = HiddenParkingTestDriver()
        let worker = HiddenWindowParkingWorker(driver: driver, didRecover: {})
        let first = native(await worker.apply(windows()))
        guard case .offscreen = await worker.apply(Array(windows().prefix(1))) else {
            return XCTFail("A minimized or otherwise retired live window requires restoration")
        }
        XCTAssertEqual(driver.read { $0.memberships }, [10: [1], 20: [1]])
        XCTAssertFalse(first[10]?.1.isReady == true)
        XCTAssertTrue(driver.read { $0.groups.isEmpty })
        XCTAssertEqual(driver.read { $0.restores }, [1])
        _ = native(await worker.apply(windows()))
        _ = await worker.stop(retry: false)
    }

    func testClosedWindowsDoNotRequireRebuildingTheParkingGroup() async throws {
        let driver = HiddenParkingTestDriver()
        let worker = HiddenWindowParkingWorker(driver: driver, didRecover: {})
        _ = native(await worker.apply(windows()))
        let initialContext = await worker.context()
        let group = try XCTUnwrap(initialContext.group)
        driver.mutate { $0.owners[20] = nil; $0.memberships[20] = nil }
        _ = native(await worker.apply(Array(windows().prefix(1))))
        let current = await worker.context()
        XCTAssertEqual(current.group, group)
        XCTAssertTrue(driver.read { $0.restores.isEmpty })
        _ = await worker.stop(retry: false)
    }

    func testRetiringUnparkedSplitWindowKeepsOtherWorkspacesHidden() async throws {
        // AX can remove a closing tile while WindowServer still knows its owner.
        // It may still be home, have lost its memberships, or have moved to a
        // foreign desktop. None of these requires restoring the hidden group.
        for membership: [UInt64] in [[1], [], [99]] {
            let driver = HiddenParkingTestDriver()
            driver.mutate { $0.owners[30] = 300; $0.memberships[30] = [1] }
            let worker = HiddenWindowParkingWorker(driver: driver, didRecover: {})
            let split = windows() + [NativeVisibilityWindow(id: 30, pid: 300, visible: true, workspace: "1")]
            let first = native(await worker.apply(split))
            let initialContext = await worker.context()
            let group = try XCTUnwrap(initialContext.group)

            driver.mutate { $0.memberships[10] = membership }
            let next = native(await worker.apply(split.filter { $0.id != 10 }))
            let context = await worker.context()
            XCTAssertEqual(context.group, group)
            XCTAssertEqual(driver.read { $0.memberships }, [10: membership, 20: [group], 30: [1]])
            XCTAssertTrue(driver.read { $0.restores.isEmpty && $0.reveals.isEmpty })
            XCTAssertEqual(driver.read { $0.created.count }, 1)
            XCTAssertFalse(first[10]?.1.isReady == true)
            XCTAssertNil(next[10])
            XCTAssertTrue(next[30]?.1 === first[30]?.1)
            XCTAssertTrue(next[30]?.1.isReady == true)
            XCTAssertFalse(next[20]?.1.isReady == true)
            _ = await worker.stop(retry: false)
        }
    }

    func testRetiredWindowWithUnknownMembershipStillRequiresRecovery() async {
        for failRecovery in [false, true] {
            let driver = HiddenParkingTestDriver()
            let worker = HiddenWindowParkingWorker(driver: driver, retryDelay: .seconds(60), didRecover: {})
            let first = native(await worker.apply(windows()))
            driver.mutate { $0.unreadableMemberships = [10]; $0.failRestore = failRecovery }
            let plan = await worker.apply(windows().filter { $0.id != 10 })
            if failRecovery {
                guard case .recovering = plan else { return XCTFail("Unknown membership must block fallback until recovery succeeds") }
                XCTAssertFalse(driver.read { $0.groups.isEmpty })
            } else {
                guard case .offscreen = plan else { return XCTFail("Unknown membership requires confirmed restoration") }
                XCTAssertTrue(driver.read { $0.groups.isEmpty })
            }
            XCTAssertEqual(driver.read { $0.restores }, [1])
            XCTAssertFalse(first[10]?.1.isReady == true)
            driver.mutate { $0.failRestore = false }
            _ = await worker.stop(retry: false)
        }
    }

    func testQuittingAppKeepsOtherWorkspacesHiddenWhileWindowServerRecordsLinger() async throws {
        let driver = HiddenParkingTestDriver()
        driver.mutate {
            $0.owners = [10: 100, 20: 100, 30: 300, 40: 400]
            $0.memberships[30] = [1]
            $0.memberships[40] = [1]
        }
        let worker = HiddenWindowParkingWorker(driver: driver, didRecover: {})
        let remaining = [
            NativeVisibilityWindow(id: 30, pid: 300, visible: true, workspace: "1"),
            NativeVisibilityWindow(id: 40, pid: 400, visible: false, workspace: "3"),
        ]
        let first = native(await worker.apply(windows(secondPid: 100) + remaining))
        let initialContext = await worker.context()
        let group = try XCTUnwrap(initialContext.group)

        // The quitting app had both a visible tile and another parked window.
        // Its process is gone, but WindowServer has not removed either record.
        driver.mutate { $0.terminatedPids = [100] }
        let next = native(await worker.apply(remaining))
        let context = await worker.context()
        XCTAssertEqual(context.group, group)
        XCTAssertEqual(driver.read { $0.memberships }, [10: [1], 20: [group], 30: [1], 40: [group]])
        XCTAssertTrue(driver.read { $0.restores.isEmpty && $0.reveals.isEmpty })
        XCTAssertEqual(driver.read { $0.created.count }, 1)
        XCTAssertFalse(first[10]?.1.isReady == true)
        XCTAssertNil(next[10])
        XCTAssertNil(next[20])
        XCTAssertTrue(next[30]?.1 === first[30]?.1)
        XCTAssertTrue(next[30]?.1.isReady == true)
        XCTAssertFalse(next[40]?.1.isReady == true)
        _ = await worker.stop(retry: false)
    }

    func testAppTerminationRequiresTheProcessToHaveExited() throws {
        let driver = WindowServerHiddenParkingDriver()
        XCTAssertFalse(driver.isAppTerminated(getpid()))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        XCTAssertTrue(driver.isAppTerminated(process.processIdentifier))
    }

    func testPartialFailureKeepsOwnershipAndBlocksNewWorkUntilRecoverySucceeds() async throws {
        let driver = HiddenParkingTestDriver()
        driver.mutate { $0.failHideAfterMove = true; $0.failRestore = true }
        let recovered = OSAllocatedUnfairLock(initialState: 0)
        let worker = HiddenWindowParkingWorker(driver: driver, retryDelay: .seconds(60), didRecover: { recovered.withLock { $0 += 1 } })
        guard case .recovering = await worker.apply(windows()) else { return XCTFail("Partial hide must recover") }
        let initialContext = await worker.context()
        let group = try XCTUnwrap(initialContext.group)
        guard case .recovering = await worker.apply(windows(20)) else { return XCTFail("Recovery must block new hiding") }
        XCTAssertEqual(driver.read { $0.created.count }, 1)
        XCTAssertEqual(driver.read { $0.groups[group] != nil }, true)
        driver.mutate { $0.failRestore = false }
        let finished = await worker.retryRecovery()
        XCTAssertTrue(finished)
        XCTAssertTrue(driver.read { $0.groups.isEmpty })
        XCTAssertEqual(driver.read { $0.memberships }, [10: [1], 20: [1]])
        XCTAssertEqual(recovered.withLock { $0 }, 1)
        _ = await worker.stop(retry: false)
    }

    func testExtraNativeDesktopDoesNotReassignWindowsOrRecreateTheGroup() async throws {
        let driver = HiddenParkingTestDriver()
        let worker = HiddenWindowParkingWorker(driver: driver, didRecover: {})
        _ = native(await worker.apply(windows()))
        let initialContext = await worker.context()
        let group = try XCTUnwrap(initialContext.group)
        driver.mutate { $0.layout = HiddenParkingTestDriver.layout(current: 1, normal: [1, 2]) }
        _ = native(await worker.apply(windows()))
        driver.mutate { $0.layout = HiddenParkingTestDriver.layout(current: 1, normal: [1]) }
        _ = native(await worker.apply(windows()))
        let context = await worker.context()
        XCTAssertEqual(context.home, 1)
        XCTAssertEqual(context.group, group)
        XCTAssertEqual(driver.read { $0.created.count }, 1)
        XCTAssertEqual(driver.read { $0.hides }, [[20]])
        XCTAssertTrue(driver.read { $0.reveals.isEmpty && $0.restores.isEmpty })
        _ = await worker.stop(retry: false)
    }

    func testLeavingHomeSuspendsWithoutAdoptingOrPullingBackTheOtherDesktop() async {
        let driver = HiddenParkingTestDriver()
        let worker = HiddenWindowParkingWorker(driver: driver, didRecover: {})
        let original = native(await worker.apply(windows()))
        driver.mutate { $0.layout = HiddenParkingTestDriver.layout(current: 2, normal: [1, 2]) }
        guard case .suspended = await worker.apply(windows()) else { return XCTFail("A foreign desktop must suspend tiling") }
        let suspended = await worker.context()
        XCTAssertEqual(suspended.home, 1)
        XCTAssertNil(suspended.group)
        XCTAssertEqual(driver.read { $0.layout?.current }, 2)
        XCTAssertEqual(driver.read { $0.memberships }, [10: [1], 20: [1]])
        XCTAssertFalse(original[10]?.1.isReady == true)
        guard case .suspended = await worker.apply(windows(20)) else { return XCTFail("Commands must not adopt the other desktop") }
        XCTAssertEqual(driver.read { $0.created.count }, 1)
        driver.mutate { $0.layout = HiddenParkingTestDriver.layout(current: 1, normal: [1, 2]) }
        let returned = native(await worker.apply(windows(20)))
        XCTAssertTrue(returned[20]?.1.isReady == true)
        XCTAssertEqual(driver.read { $0.memberships[20] }, [1])
        _ = await worker.stop(retry: false)
    }

    func testNativeFullscreenSuspendsAndPreservesItsIndependentMembership() async {
        let driver = HiddenParkingTestDriver()
        let worker = HiddenWindowParkingWorker(driver: driver, didRecover: {})
        _ = native(await worker.apply(windows()))
        driver.mutate {
            $0.layout = HiddenParkingTestDriver.layout(current: 3, normal: [1], fullscreen: [3])
            $0.memberships[10] = [3]
        }
        guard case .suspended = await worker.apply(windows()) else { return XCTFail("Native fullscreen must suspend tiling") }
        XCTAssertEqual(driver.read { $0.memberships }, [10: [3], 20: [1]])
        XCTAssertEqual(driver.read { $0.layout?.current }, 3)
        let context = await worker.context()
        XCTAssertEqual(context.home, 1)
        _ = await worker.stop(retry: false)
    }

    func testRemovingHomeRestoresToAnExistingDesktopBeforeReanchoring() async {
        let driver = HiddenParkingTestDriver()
        let worker = HiddenWindowParkingWorker(driver: driver, didRecover: {})
        _ = native(await worker.apply(windows()))
        driver.mutate {
            $0.layout = HiddenParkingTestDriver.layout(current: 2, normal: [2, 4])
            $0.memberships[10] = [2]
        }
        guard case .offscreen = await worker.apply(windows()) else { return XCTFail("Recovery must complete before reanchoring") }
        let recovered = await worker.context()
        XCTAssertEqual(recovered.home, 2)
        XCTAssertNil(recovered.group)
        XCTAssertEqual(driver.read { $0.restores }, [2])
        XCTAssertEqual(driver.read { $0.memberships }, [10: [2], 20: [2]])
        _ = native(await worker.apply(windows()))
        XCTAssertEqual(driver.read { $0.memberships[10] }, [2])
        XCTAssertEqual(driver.read { $0.created.count }, 2)
        _ = await worker.stop(retry: false)
    }

    func testOwnerReuseCannotHideTheReplacementUsingTheOldOwnersRequest() async {
        let driver = HiddenParkingTestDriver()
        let worker = HiddenWindowParkingWorker(driver: driver, didRecover: {})
        let previous = native(await worker.apply(windows(20)))
        driver.mutate { $0.owners[20] = 300; $0.memberships[20] = [1] }
        let stale = native(await worker.apply(windows()))
        XCTAssertFalse(stale[20]?.1.isReady == true)
        XCTAssertFalse(previous[20]?.1.isReady == true)
        XCTAssertEqual(driver.read { $0.memberships[20] }, [1])
        XCTAssertFalse(driver.read { $0.hides.contains([20]) })
        let replacement = native(await worker.apply(windows(20, secondPid: 300)))
        XCTAssertEqual(replacement[20]?.0, 300)
        XCTAssertTrue(replacement[20]?.1.isReady == true)
        _ = await worker.stop(retry: false)
    }

    func testForeignMembershipIsNeitherMovedNorReleasedForFocusOrFrameWrites() async {
        let driver = HiddenParkingTestDriver()
        driver.mutate { $0.memberships[10] = [99] }
        let worker = HiddenWindowParkingWorker(driver: driver, didRecover: {})
        let gates = native(await worker.apply(windows()))
        XCTAssertFalse(gates[10]?.1.isReady == true)
        XCTAssertEqual(driver.read { $0.memberships[10] }, [99])
        XCTAssertEqual(driver.read { $0.hides }, [[20]])
        XCTAssertTrue(driver.read { $0.reveals.isEmpty })
        _ = await worker.stop(retry: false)
        XCTAssertEqual(driver.read { $0.memberships[10] }, [99])
    }

    func testMissingOwnershipOrMembershipQueriesNeverAuthorizeAHide() async {
        for failOwners in [true, false] {
            let driver = HiddenParkingTestDriver()
            driver.mutate {
                $0.failOwners = failOwners
                if !failOwners { $0.unreadableMemberships = [20] }
            }
            let worker = HiddenWindowParkingWorker(driver: driver, didRecover: {})
            guard case .offscreen = await worker.apply(windows()) else { return XCTFail("Initial query failure must retain fallback") }
            XCTAssertTrue(driver.read { $0.created.isEmpty && $0.hides.isEmpty })
            _ = await worker.stop(retry: false)
        }
    }

    func testUnacknowledgedReturnCannotReleaseAVisibleGate() async {
        let driver = HiddenParkingTestDriver()
        let worker = HiddenWindowParkingWorker(driver: driver, didRecover: {})
        _ = native(await worker.apply(windows()))
        driver.mutate { $0.leaveGroupMembershipOnReveal = true }
        guard case .offscreen = await worker.apply(windows(20)) else { return XCTFail("A mixed home/group membership requires recovery") }
        XCTAssertEqual(driver.read { $0.memberships }, [10: [1], 20: [1]])
        XCTAssertTrue(driver.read { $0.groups.isEmpty })
        _ = await worker.stop(retry: false)
    }

    func testDesktopChangeDuringAssignmentRecoversAndSuspends() async {
        for stage in ["create", "hide", "reveal"] {
            let driver = HiddenParkingTestDriver()
            let worker = HiddenWindowParkingWorker(driver: driver, didRecover: {})
            if stage == "reveal" { _ = native(await worker.apply(windows())) }
            let leaveHome: @Sendable () -> Void = {
                driver.mutate { $0.layout = HiddenParkingTestDriver.layout(current: 2, normal: [1, 2]) }
            }
            driver.mutate {
                switch stage {
                    case "create": $0.afterCreate = leaveHome
                    case "hide": $0.afterHide = leaveHome
                    default: $0.afterReveal = leaveHome
                }
            }
            let desired = stage == "reveal" ? windows(20) : windows()
            guard case .suspended = await worker.apply(desired) else {
                return XCTFail("A desktop switch during \(stage) must not activate home")
            }
            XCTAssertEqual(driver.read { $0.memberships }, [10: [1], 20: [1]])
            XCTAssertEqual(driver.read { $0.layout?.current }, 2)
            if stage == "create" { XCTAssertTrue(driver.read { $0.hides.isEmpty }) }
            if stage == "reveal" { XCTAssertEqual(driver.read { $0.hides }, [[20]]) }
            _ = await worker.stop(retry: false)
        }
    }

    func testExternalStopForgetsHomeOnlyAfterCleanupAndAllowsDeliberateReenableElsewhere() async {
        let driver = HiddenParkingTestDriver()
        let worker = HiddenWindowParkingWorker(driver: driver, retryDelay: .seconds(60), didRecover: {})
        _ = native(await worker.apply(windows()))
        driver.mutate { $0.failRestore = true }
        let stopped = await worker.stop(restartDelay: .zero)
        XCTAssertFalse(stopped)
        let unfinished = await worker.context()
        XCTAssertEqual(unfinished.home, 1)
        XCTAssertNotNil(unfinished.group)
        driver.mutate { $0.failRestore = false }
        let recovered = await worker.retryRecovery()
        XCTAssertTrue(recovered)
        let cleared = await worker.context()
        XCTAssertNil(cleared.home)
        XCTAssertNil(cleared.group)
        driver.mutate {
            $0.layout = HiddenParkingTestDriver.layout(current: 2, normal: [1, 2])
            $0.memberships = [10: [2], 20: [2]]
        }
        _ = native(await worker.apply(windows()))
        let reenabled = await worker.context()
        XCTAssertEqual(reenabled.home, 2)
        _ = await worker.stop(retry: false)
    }
}

private final class HiddenParkingTestDriver: HiddenWindowParkingDriver, Sendable {
    struct State {
        var layout: NativeDisplaySpaces? = HiddenParkingTestDriver.layout()
        var owners: [UInt32: Int32] = [10: 100, 20: 200]
        var terminatedPids: Set<Int32> = []
        var memberships: [UInt32: [UInt64]] = [10: [1], 20: [1]]
        var groups: [UInt64: String] = [:]
        var created: [UInt64] = []
        var hides: [[UInt32]] = []
        var reveals: [[UInt32]] = []
        var restores: [UInt64] = []
        var displayQueries = 0
        var ownerQueries = 0
        var onScreenQueries = 0
        var notOnScreen: Set<UInt32> = []
        var failOnScreen = false
        var failOwners = false
        var unreadableMemberships: Set<UInt32> = []
        var failHideAfterMove = false
        var failRestore = false
        var leaveGroupMembershipOnReveal = false
        var afterCreate: (@Sendable () -> Void)?
        var afterOwners: (@Sendable (Int) -> Void)?
        var afterOnScreen: (@Sendable (Int) -> Void)?
        var afterHide: (@Sendable () -> Void)?
        var afterReveal: (@Sendable () -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    static func layout(current: UInt64 = 1, normal: [UInt64] = [1], fullscreen: [UInt64] = []) -> NativeDisplaySpaces {
        NativeDisplaySpaces(display: "display", current: current, spaces:
            normal.map { .init(id: $0, type: 0, name: nil) } + fullscreen.map { .init(id: $0, type: 4, name: nil) })
    }

    func read<T: Sendable>(_ body: @Sendable (State) -> T) -> T { state.withLock { body($0) } }
    func mutate(_ body: @Sendable (inout State) -> Void) { state.withLock(body) }
    func display() -> NativeDisplaySpaces? { state.withLock { $0.displayQueries += 1; return $0.layout } }

    func owners(_ ids: [UInt32]) -> [UInt32: Int32]? {
        let (owners, query, callback) = state.withLock { state in
            state.ownerQueries += 1
            let owners = state.failOwners ? nil : state.owners.filter { ids.contains($0.key) }
            return (owners, state.ownerQueries, state.afterOwners)
        }
        callback?(query)
        return owners
    }

    func membership(_ id: UInt32) -> [UInt64]? {
        state.withLock { $0.unreadableMemberships.contains(id) ? nil : $0.memberships[id] }
    }

    func onScreenWindows(_ ids: [UInt32]) -> Set<UInt32>? {
        let (visible, query, callback) = state.withLock { state in
            state.onScreenQueries += 1
            let visible = state.failOnScreen ? nil : Set(ids.filter {
                !state.notOnScreen.contains($0) && state.memberships[$0] == [state.layout?.current ?? 0]
            })
            return (visible, state.onScreenQueries, state.afterOnScreen)
        }
        callback?(query)
        return visible
    }

    func isAppTerminated(_ pid: Int32) -> Bool { state.withLock { $0.terminatedPids.contains(pid) } }

    func create(_ name: String) -> UInt64 {
        let (id, callback) = state.withLock {
            let id = UInt64(100 + $0.created.count)
            $0.created.append(id)
            $0.groups[id] = name
            return (id, $0.afterCreate)
        }
        callback?()
        return id
    }

    func hide(_ ids: [UInt32], in group: WorkspaceVisibilityGroup) -> Bool {
        let (succeeded, callback) = state.withLock { state in
            state.hides.append(ids)
            guard state.groups[group.id] == group.name else { return (false, nil as (@Sendable () -> Void)?) }
            for id in ids { state.memberships[id] = [group.id] }
            return (!state.failHideAfterMove, state.afterHide)
        }
        callback?()
        return succeeded
    }

    func reveal(_ ids: [UInt32], from group: WorkspaceVisibilityGroup, home: UInt64) -> Bool {
        let (succeeded, callback) = state.withLock { state in
            state.reveals.append(ids)
            guard state.groups[group.id] == group.name else { return (false, nil as (@Sendable () -> Void)?) }
            for id in ids {
                guard state.memberships[id] == [group.id] else { return (false, nil as (@Sendable () -> Void)?) }
                state.memberships[id] = state.leaveGroupMembershipOnReveal ? [group.id, home] : [home]
            }
            return (true, state.afterReveal)
        }
        callback?()
        return succeeded
    }

    func restore(_ group: WorkspaceVisibilityGroup, home: UInt64) -> Bool {
        state.withLock { state in
            state.restores.append(home)
            guard !state.failRestore, state.groups[group.id] == group.name,
                  state.layout?.spaces.contains(where: { $0.id == home && $0.type == 0 }) == true
            else { return false }
            for (id, membership) in state.memberships where membership.contains(group.id) {
                let others = membership.filter { $0 != group.id }
                state.memberships[id] = others.isEmpty ? [home] : others
            }
            state.groups[group.id] = nil
            return true
        }
    }
}
