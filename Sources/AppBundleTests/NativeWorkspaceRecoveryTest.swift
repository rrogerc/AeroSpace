import Foundation
import PrivateApi
import XCTest

/// These tests inspect supplied data only; they never create, move or remove a Space.
final class NativeWorkspaceRecoveryTest: XCTestCase {
    private let parkingName = "AeroSpace private windows 501 100 5DE478EC-A409-4618-9571-001D916A506C"

    func testRecoveryUsesTheUniqueNameInTheManagedRecord() {
        let snapshot = [display(spaces: [home, parking])]
        XCTAssertEqual(inspect(snapshot), .owned)
        XCTAssertEqual(inspect(snapshot, name: "another installation"), .foreign)
        XCTAssertEqual(inspect(snapshot, name: parking["uuid"] as? String), .foreign)
    }

    func testOnlyACompleteSnapshotCanProveTheSpaceWasRemoved() {
        XCTAssertEqual(inspect([display(spaces: [home])]), .absent)
        XCTAssertEqual(AeroSpaceParkingSpaceStateInSnapshot(nil, 42, parkingName as CFString), .unknown)
        XCTAssertEqual(inspect([]), .unknown)
        XCTAssertEqual(inspect([[:]]), .unknown)
        XCTAssertEqual(inspect([display(spaces: [])]), .unknown)
        XCTAssertEqual(inspect([display(spaces: [home], current: 99)]), .unknown)
    }

    func testAReusedIdOrNativeFullscreenDoesNotAuthorizeDestruction() {
        for change: [String: Any] in [["name": "user desktop"], ["name": NSNull()], ["type": 4]] {
            let replacement = parking.merging(change) { _, new in new }
            XCTAssertEqual(inspect([display(spaces: [home, replacement])]), .foreign)
        }
    }

    func testMalformedOrAmbiguousIdentityCannotAuthorizeDestruction() {
        for bad: Any in [0, -1, true, "42", 42.5, NSNull()] {
            let invalid = parking.merging(["id64": bad]) { _, new in new }
            XCTAssertEqual(inspect([display(spaces: [home, invalid])]), .unknown)
        }
        for bad: Any in [-1, true, "0", 0.5, NSNull()] {
            let invalid = parking.merging(["type": bad]) { _, new in new }
            XCTAssertEqual(inspect([display(spaces: [home, invalid])]), .unknown)
        }
        let reused = parking.merging(["name": "someone else's desktop"]) { _, new in new }
        XCTAssertEqual(inspect([display(spaces: [home, parking, reused])]), .unknown)
    }

    func testTheWholeSnapshotMustBeValidEvenAfterFindingTheOwnedSpace() {
        let owned = display(spaces: [home, parking])
        XCTAssertEqual(inspect([owned, [:]]), .unknown)
        XCTAssertEqual(inspect([owned, owned]), .unknown)
        XCTAssertEqual(inspect([display(spaces: [home, parking, ["id64": "bad"]])]), .unknown)
    }

    func testRecoveryStillFindsTheSpaceAfterAMonitorIsAttached() {
        let otherHome: [String: Any] = ["id64": 10, "type": 0]
        let snapshot = [
            display(spaces: [home]),
            display(spaces: [otherHome, parking], current: 10, identifier: "second-display"),
        ]
        XCTAssertEqual(inspect(snapshot), .owned)
        XCTAssertEqual(inspect(snapshot, id: 43), .absent)
    }

    func testInvalidRecoveryRequestsCannotMatchAnyDesktop() {
        let snapshot = [display(spaces: [home, parking])]
        XCTAssertEqual(inspect(snapshot, id: 0), .unknown)
        XCTAssertEqual(inspect(snapshot, id: .max), .unknown)
        XCTAssertEqual(inspect(snapshot, name: ""), .unknown)
        XCTAssertEqual(AeroSpaceParkingSpaceStateInSnapshot(snapshot as CFArray, 42, nil), .unknown)
    }

    private var home: [String: Any] { ["id64": 1, "type": 0] }

    private var parking: [String: Any] {
        ["id64": 42, "type": 0, "name": parkingName, "uuid": "9291757B-EFD7-4A2F-A814-B92784E92278"]
    }

    private func display(spaces: [[String: Any]], current: Int = 1, identifier: String = "display") -> [String: Any] {
        ["Display Identifier": identifier, "Current Space": ["id64": current], "Spaces": spaces]
    }

    private func inspect(_ snapshot: [[String: Any]], id: UInt64 = 42, name: String? = nil) -> AeroSpaceParkingSpaceState {
        AeroSpaceParkingSpaceStateInSnapshot(snapshot as CFArray, id, (name ?? parkingName) as CFString)
    }
}
