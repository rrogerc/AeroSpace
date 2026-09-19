@testable import AppBundle
import XCTest

@MainActor
final class HotkeyBindingQueueTest: XCTestCase {
    func testSlowFirstReadCannotLetLaterHotkeysOvertakeOrDropCommands() async {
        let started = expectation(description: "First command is waiting on its read")
        let finished = expectation(description: "All commands finished")
        let release = AwaitableOneTimeBroadcastLatch()
        var events: [String] = []
        var continued: [Bool] = []
        let queue = HotkeyBindingQueue { id, followsWorkspaceSwitch in
            continued.append(followsWorkspaceSwitch)
            if id == "first" {
                started.fulfill()
                try? await release.await()
            }
            events.append(id)
            if id == "last" { finished.fulfill() }
            return true
        }
        queue.enqueue("first")
        await fulfillment(of: [started], timeout: 1)
        for id in ["next", "back-and-forth", "last"] { queue.enqueue(id) }
        await Task.yield()
        XCTAssertTrue(events.isEmpty, "Commands must not pass the suspended first command")
        await release.signalToAll()
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(events, ["first", "next", "back-and-forth", "last"])
        XCTAssertEqual(continued, [false, true, true, true])
    }

    func testNonWorkspaceCommandAndNewBurstRequireNativeFocusSynchronization() async {
        let finished = expectation(description: "First burst finished")
        let restarted = expectation(description: "New burst finished")
        var continued: [Bool] = []
        let queue = HotkeyBindingQueue { id, followsWorkspaceSwitch in
            continued.append(followsWorkspaceSwitch)
            if id == "last" { finished.fulfill() }
            if id == "new" { restarted.fulfill() }
            return id != "mode"
        }
        for id in ["workspace", "mode", "last"] { queue.enqueue(id) }
        await fulfillment(of: [finished], timeout: 1)
        queue.enqueue("new")
        await fulfillment(of: [restarted], timeout: 1)
        XCTAssertEqual(continued, [false, true, false, false])
    }
}
