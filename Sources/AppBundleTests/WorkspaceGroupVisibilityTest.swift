@testable import AppBundle
import Foundation
import os
import XCTest

final class WorkspaceGroupVisibilityTest: XCTestCase {
    private func windows(_ visible: String, secondWorkspace: String = "2") -> [NativeVisibilityWindow] {
        [
            NativeVisibilityWindow(id: 10, pid: 100, visible: visible == "1", workspace: "1"),
            NativeVisibilityWindow(id: 20, pid: 200, visible: visible == secondWorkspace, workspace: secondWorkspace),
        ]
    }

    private func native(_ plan: NativeVisibilityPlan, file: StaticString = #filePath, line: UInt = #line) -> [UInt32: (Int32, NativeVisibilityGate)] {
        guard case .native(let gates) = plan else {
            XCTFail("Expected native visibility", file: file, line: line)
            return [:]
        }
        return gates
    }

    func testRepeatedSwitchesOnlyChangeVisibilityAndCancelOldFrameWaiters() async throws {
        let driver = GroupTestDriver()
        let worker = WorkspaceGroupVisibilityWorker(driver: driver, didRecover: {})
        let initial = native(await worker.apply(windows("1"), request: 1))
        let firstGate = try XCTUnwrap(initial[10]?.1)
        XCTAssertTrue(firstGate.isReady)
        let memberships = driver.read { $0.memberships }
        let assignmentCount = driver.read { $0.assignments.count }
        for request in 2 ... 21 {
            let destination = request.isMultiple(of: 2) ? "2" : "1"
            let gates = native(await worker.apply(windows(destination), request: UInt64(request)))
            XCTAssertEqual(Set(gates.keys), [destination == "1" ? 10 : 20])
            XCTAssertTrue(gates.values.allSatisfy { $0.1.isReady })
        }
        XCTAssertFalse(firstGate.isReady)
        XCTAssertEqual(driver.read { $0.memberships }, memberships)
        XCTAssertEqual(driver.read { $0.assignments.count }, assignmentCount, "A switch must not move window membership")
        XCTAssertEqual(driver.read { $0.commits.count(where: { $0.show.count == 1 && $0.hide.count == 1 }) }, 20)
        _ = await worker.stop(retry: false)
    }

    func testReassignmentMovesOnlyTheChangedWindowAndEmptyWorkspaceHidesEverything() async {
        let driver = GroupTestDriver()
        let worker = WorkspaceGroupVisibilityWorker(driver: driver, didRecover: {})
        _ = native(await worker.apply(windows("1")))
        let unchanged = driver.read { $0.memberships[10] }
        let old = driver.read { $0.memberships[20] }
        _ = native(await worker.apply(windows("3", secondWorkspace: "3")))
        XCTAssertEqual(driver.read { $0.memberships[10] }, unchanged)
        XCTAssertNotEqual(driver.read { $0.memberships[20] }, old)
        XCTAssertEqual(driver.read { $0.memberships[20]?.count }, 1, "Reassignment cannot retain both workspace groups")
        XCTAssertEqual(driver.read { $0.assignments.last?.ids }, [20])
        let empty = native(await worker.apply(windows("empty", secondWorkspace: "3")))
        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(driver.read { $0.visible.isEmpty })
        _ = await worker.stop(retry: false)
    }

    func testStaleRequestsAndTerminationCannotChangeVisibility() async {
        let driver = GroupTestDriver()
        let worker = WorkspaceGroupVisibilityWorker(driver: driver, didRecover: {})
        _ = native(await worker.apply(windows("1"), request: 20))
        let commits = driver.read { $0.commits.count }
        _ = await worker.apply(windows("2"), request: 19)
        _ = await worker.stop(request: 18)
        XCTAssertEqual(driver.read { $0.commits.count }, commits)
        XCTAssertEqual(driver.read { $0.restores }, 0)
        _ = await worker.stop(retry: false, request: 21)
        _ = await worker.apply(windows("2"), request: 22)
        XCTAssertEqual(driver.read { $0.commits.count }, commits)
        XCTAssertEqual(driver.read { $0.restores }, 1)
    }

    func testCancelledRequestDoesNotReachTheDriver() async {
        let driver = GroupTestDriver()
        let worker = WorkspaceGroupVisibilityWorker(driver: driver, didRecover: {})
        let start = AwaitableOneTimeBroadcastLatch()
        let desired = windows("1")
        let task = Task.detached {
            try? await start.await()
            return await worker.apply(desired, request: 1)
        }
        task.cancel()
        _ = await task.value
        XCTAssertEqual(driver.read { $0.displayQueries }, 0)
        XCTAssertTrue(driver.read { $0.groups.isEmpty })
    }

    func testPartialAssignmentFailureRestoresWindowsBeforeFallback() async {
        let driver = GroupTestDriver()
        driver.mutate { $0.failAssignmentAt = 2 }
        let worker = WorkspaceGroupVisibilityWorker(driver: driver, didRecover: {})
        let plan = await worker.apply(windows("1"))
        guard case .offscreen = plan else { return XCTFail("Completed recovery permits fallback") }
        XCTAssertEqual(driver.read { $0.assignments.count }, 2)
        XCTAssertEqual(driver.read { $0.restores }, 1)
        XCTAssertEqual(driver.read { $0.memberships }, [10: [1], 20: [1]])
        XCTAssertTrue(driver.read { $0.groups.isEmpty })
        XCTAssertTrue(driver.read { $0.commits.isEmpty })
    }

    func testRecoveryFailureKeepsOwnershipAndBlocksNewGroupsUntilConfirmed() async throws {
        let driver = GroupTestDriver()
        let worker = WorkspaceGroupVisibilityWorker(driver: driver, retryDelay: .seconds(60), didRecover: {})
        let initial = native(await worker.apply(windows("1")))
        let gate = try XCTUnwrap(initial[10]?.1)
        let created = driver.read { $0.groups }
        driver.mutate { $0.failRestore = true }
        let stopped = await worker.stop(restartDelay: .zero)
        XCTAssertFalse(stopped)
        XCTAssertFalse(gate.isReady)
        guard case .recovering = await worker.apply(windows("2")) else { return XCTFail("Recovery must block fallback") }
        XCTAssertEqual(driver.read { $0.groups }, created)
        XCTAssertEqual(driver.read { $0.restores }, 1)
        driver.mutate { $0.failRestore = false }
        let recovered = await worker.retryRecovery()
        XCTAssertTrue(recovered)
        XCTAssertTrue(driver.read { $0.groups.isEmpty })
        _ = native(await worker.apply(windows("2")))
        _ = await worker.stop(retry: false)
    }

    func testFullscreenTopologyRestoresGroupsWithoutStealingTheFullscreenWindow() async {
        let driver = GroupTestDriver()
        let worker = WorkspaceGroupVisibilityWorker(driver: driver, didRecover: {})
        _ = native(await worker.apply(windows("1")))
        driver.mutate {
            $0.memberships[20, default: []].append(2)
            $0.layout = NativeDisplaySpaces(display: "display", current: 2, spaces: [
                .init(id: 1, type: 0, name: nil), .init(id: 2, type: 4, name: nil),
            ])
        }
        guard case .offscreen = await worker.apply(windows("1")) else { return XCTFail("Fullscreen must use fallback") }
        XCTAssertEqual(driver.read { $0.memberships }, [10: [1], 20: [2]])
        XCTAssertTrue(driver.read { $0.groups.isEmpty })
        driver.mutate {
            $0.layout = GroupTestDriver.initialLayout
            $0.memberships[20] = [1]
        }
        _ = native(await worker.apply(windows("1")))
        _ = await worker.stop(retry: false)
    }

    func testForeignWindowMembershipIsNeverAssignedToOurGroups() async {
        let driver = GroupTestDriver()
        driver.mutate { $0.memberships[10] = [555] }
        let worker = WorkspaceGroupVisibilityWorker(driver: driver, didRecover: {})
        guard case .offscreen = await worker.apply(windows("1")) else { return XCTFail("Foreign membership must use fallback") }
        XCTAssertEqual(driver.read { $0.memberships[10] }, [555])
        XCTAssertTrue(driver.read { $0.assignments.isEmpty })
        XCTAssertTrue(driver.read { $0.groups.isEmpty })
    }

    func testReusedWindowIdCancelsTheFormerOwnersGate() async throws {
        let driver = GroupTestDriver()
        let worker = WorkspaceGroupVisibilityWorker(driver: driver, didRecover: {})
        let initial = native(await worker.apply(windows("1")))
        let old = try XCTUnwrap(initial[10]?.1)
        driver.mutate { $0.owners[10] = 300; $0.memberships[10] = [1] }
        var next = windows("1")
        next[0] = NativeVisibilityWindow(id: 10, pid: 300, visible: true, workspace: "1")
        let gates = native(await worker.apply(next))
        XCTAssertEqual(gates[10]?.0, 300)
        XCTAssertFalse(old.isReady)
        XCTAssertTrue(gates[10]?.1.isReady == true)
        XCTAssertEqual(driver.read { $0.restores }, 0)
        _ = await worker.stop(retry: false)
    }

    func testClosedWindowDoesNotRequireRecoveryButLiveRetirementDoes() async {
        let driver = GroupTestDriver()
        let worker = WorkspaceGroupVisibilityWorker(driver: driver, didRecover: {})
        _ = native(await worker.apply(windows("1")))
        driver.mutate { $0.owners[20] = nil; $0.memberships[20] = nil }
        _ = native(await worker.apply(Array(windows("1").prefix(1))))
        XCTAssertEqual(driver.read { $0.restores }, 1, "Only the now-empty workspace group is released")
        XCTAssertEqual(driver.read { $0.groups.count }, 1)
        XCTAssertNotEqual(driver.read { $0.memberships[10] }, [1], "The other workspace must retain its membership")
        guard case .offscreen = await worker.apply([]) else { return XCTFail("Retiring a live window requires membership restoration") }
        XCTAssertEqual(driver.read { $0.memberships[10] }, [1])
        XCTAssertEqual(driver.read { $0.restores }, 2)
    }

    func testSteadySingleWindowVisibilityDoesNotWaitForActivationAndResultIsReusable() async throws {
        let driver = GroupTestDriver()
        let worker = WorkspaceGroupVisibilityWorker(driver: driver, didRecover: {})
        _ = native(await worker.apply(windows("1")))
        let originallyVisible = driver.read { $0.visible }
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let preparation = WorkspaceFocusPreparation(pid: 200, windowId: 20, job: RunLoopJob(.cancellable), activate: {
            XCTAssertEqual(driver.read { $0.visible }, Set(driver.read { $0.memberships[20] ?? [] }))
            calls.withLock { $0 += 1 }
            entered.signal()
            release.wait()
            return true
        })
        let applied = expectation(description: "Visibility progresses while activation is still in flight")
        let target = windows("2")
        let apply = Task.detached {
            let plan = await worker.apply(target, earlyFocus: preparation)
            applied.fulfill()
            return plan
        }
        await fulfillment(of: [applied], timeout: 1)
        XCTAssertNotEqual(driver.read { $0.visible }, originallyVisible)
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        release.signal()
        _ = native(await apply.value)
        XCTAssertTrue(try XCTUnwrap(preparation.waitForResult()))
        preparation.start()
        XCTAssertTrue(try XCTUnwrap(preparation.waitForResult()))
        XCTAssertEqual(calls.withLock { $0 }, 1, "The final focus job must reuse activation instead of posting a second sequence")
        _ = await worker.stop(retry: false)
    }

    func testFailedVisibilityCommitNeverStartsDestinationActivation() async {
        let driver = GroupTestDriver()
        let worker = WorkspaceGroupVisibilityWorker(driver: driver, didRecover: {})
        _ = native(await worker.apply(windows("1")))
        driver.mutate { $0.failCommit = true }
        let preparation = WorkspaceFocusPreparation(pid: 200, windowId: 20, job: RunLoopJob(.cancellable), activate: {
            XCTFail("A rejected visibility transaction must not activate its destination")
            return true
        })
        guard case .offscreen = await worker.apply(windows("2"), earlyFocus: preparation) else {
            return XCTFail("Failed visibility requires recovery and fallback")
        }
        XCTAssertFalse(preparation.hasStarted)
        XCTAssertEqual(driver.read { $0.memberships }, [10: [1], 20: [1]])
        XCTAssertTrue(driver.read { $0.groups.isEmpty })
    }

    func testInitialMembershipAndMultiWindowWorkspaceDoNotActivateBeforeVisibility() async {
        let driver = GroupTestDriver()
        let worker = WorkspaceGroupVisibilityWorker(driver: driver, didRecover: {})
        let initial = WorkspaceFocusPreparation(pid: 100, windowId: 10, job: RunLoopJob(.cancellable), activate: {
            XCTFail("Initial assignment must retain the normal visibility gate")
            return true
        })
        _ = native(await worker.apply(windows("1"), earlyFocus: initial))
        XCTAssertNil(initial.result)
        driver.mutate { $0.owners[30] = 300; $0.memberships[30] = [1] }
        var multiple = windows("1")
        multiple.append(NativeVisibilityWindow(id: 30, pid: 300, visible: false, workspace: "2"))
        _ = native(await worker.apply(multiple))
        multiple = multiple.map { NativeVisibilityWindow(id: $0.id, pid: $0.pid, visible: $0.workspace == "2", workspace: $0.workspace) }
        let pending = WorkspaceFocusPreparation(pid: 200, windowId: 20, job: RunLoopJob(.cancellable), activate: {
            XCTFail("Multiple windows must retain visibility-before-raise ordering")
            return true
        })
        _ = native(await worker.apply(multiple, earlyFocus: pending))
        XCTAssertNil(pending.result)
        _ = await worker.stop(retry: false)
    }

    func testReturningToAnUnchangedWorkspaceRenewsItsCancelledGate() async throws {
        let driver = GroupTestDriver()
        let worker = WorkspaceGroupVisibilityWorker(driver: driver, didRecover: {})
        let gates = native(await worker.apply(windows("1")))
        let old = try XCTUnwrap(gates[10]?.1)
        let visible = driver.read { $0.visible }
        old.cancel()
        XCTAssertEqual(driver.read { $0.visible }, visible)
        XCTAssertFalse(old.isReady)
        let returned = native(await worker.apply(windows("1")))
        XCTAssertTrue(returned[10]?.1.isReady == true)
        XCTAssertFalse(returned[10]?.1 === old)
        _ = await worker.stop(retry: false)
    }

    func testQueuedCancelledWorkspaceActivationCompletesWithoutHangingItsWaiter() {
        let queue = DispatchQueue(label: "blocked workspace activation")
        let release = DispatchSemaphore(value: 0)
        queue.async { release.wait() }
        let job = RunLoopJob(.cancellable)
        let preparation = WorkspaceFocusPreparation(pid: 100, windowId: 10, job: job, preparation: NativeFocusPreparation(queue: queue), activate: {
            XCTFail("A cancelled workspace must not activate")
            return true
        })
        preparation.start()
        job.cancel()
        release.signal()
        XCTAssertEqual(preparation.waitForResult(), false)
        XCTAssertEqual(preparation.waitForResult(), false)
    }
}

private final class GroupTestDriver: WorkspaceGroupDriver, Sendable {
    static let initialLayout = NativeDisplaySpaces(display: "display", current: 1, spaces: [.init(id: 1, type: 0, name: nil)])
    struct Commit { let show: [UInt64]; let hide: [UInt64] }
    struct Assignment { let ids: [UInt32]; let group: UInt64 }
    struct State {
        var layout: NativeDisplaySpaces? = initialLayout
        var owners: [UInt32: Int32] = [10: 100, 20: 200]
        var memberships: [UInt32: [UInt64]] = [10: [1], 20: [1]]
        var groups: [UInt64: String] = [:]
        var visible: Set<UInt64> = []
        var nextGroup: UInt64 = 1000
        var assignments: [Assignment] = []
        var commits: [Commit] = []
        var restores = 0
        var displayQueries = 0
        var failAssignmentAt: Int?
        var failCommit = false
        var failRestore = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    func read<T: Sendable>(_ body: @Sendable (State) -> T) -> T { state.withLock { body($0) } }
    func mutate(_ body: @Sendable (inout State) -> Void) { state.withLock(body) }
    func display() -> NativeDisplaySpaces? {
        state.withLock { $0.displayQueries += 1; return $0.layout }
    }
    func owners(_ ids: [UInt32]) -> [UInt32: Int32]? { read { state in state.owners.filter { ids.contains($0.key) } } }
    func membership(_ id: UInt32) -> [UInt64]? { read { $0.memberships[id] } }
    func create(_ name: String) -> UInt64 {
        state.withLock { $0.nextGroup += 1; $0.groups[$0.nextGroup] = name; return $0.nextGroup }
    }
    func assign(_ ids: [UInt32], to group: WorkspaceVisibilityGroup) -> Bool {
        state.withLock { state in
            state.assignments.append(Assignment(ids: ids, group: group.id))
            guard state.failAssignmentAt != state.assignments.count, state.groups[group.id] == group.name else { return false }
            for id in ids { state.memberships[id] = [group.id] }
            return true
        }
    }
    func commit(show: [WorkspaceVisibilityGroup], hide: [WorkspaceVisibilityGroup]) -> Bool {
        state.withLock { state in
            guard !state.failCommit, (show + hide).allSatisfy({ state.groups[$0.id] == $0.name }) else { return false }
            state.commits.append(Commit(show: show.map(\.id), hide: hide.map(\.id)))
            state.visible.formUnion(show.map(\.id))
            state.visible.subtract(hide.map(\.id))
            return true
        }
    }
    func restore(_ groups: [WorkspaceVisibilityGroup], home: UInt64) -> Bool {
        state.withLock { state in
            state.restores += 1
            guard !state.failRestore else { return false }
            let owned = Set(groups.map(\.id))
            for (id, memberships) in state.memberships where !owned.isDisjoint(with: memberships) {
                let remaining = memberships.filter { !owned.contains($0) }
                state.memberships[id] = remaining.isEmpty ? [home] : remaining
            }
            for group in groups { state.groups[group.id] = nil; state.visible.remove(group.id) }
            return true
        }
    }
}
