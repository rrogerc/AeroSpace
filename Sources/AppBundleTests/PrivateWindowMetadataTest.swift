@testable import AppBundle
import CoreGraphics
import PrivateApi
import XCTest

final class PrivateWindowMetadataTest: XCTestCase {
    func testDecodesOnlyReturnedRecordsAndPreservesGeometry() throws {
        let frame = CGRect(x: -1920, y: 13, width: 1900, height: 1000)
        let output = [record(bounds: frame), AeroSpaceWindowInfo()]
        let decoded = try XCTUnwrap(PrivateWindowMetadata.decode(output, count: 1, windowIds: [42]))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].windowId, 42)
        XCTAssertEqual(decoded[0].pid, 123)
        XCTAssertEqual(decoded[0].layer, 0)
        XCTAssertEqual(decoded[0].bounds, frame)
    }

    func testRejectsUnexpectedOwnerWindowAndInvalidGeometry() {
        for invalid in [record(windowId: 43), record(pid: 0), record(pid: -1), record(bounds: .zero), record(bounds: CGRect(x: CGFloat.infinity, y: 0, width: 10, height: 10))] {
            XCTAssertNil(PrivateWindowMetadata.decode([invalid], count: 1, windowIds: [42]))
        }
    }

    func testRejectsInvalidCountsAndAcceptsClosedWindowsAbsentFromReply() {
        XCTAssertNil(PrivateWindowMetadata.decode([record()], count: -1, windowIds: [42]))
        XCTAssertNil(PrivateWindowMetadata.decode([record()], count: 2, windowIds: [42]))
        XCTAssertEqual(PrivateWindowMetadata.decode([record()], count: 0, windowIds: [42])?.count, 0)
    }

    func testBridgeRejectsInvalidBuffersBeforeAccessingWindowServer() {
        var count = 123
        XCTAssertEqual(unsafe AeroSpaceCopyWindowInfo(nil, 1, nil, 0, &count), .illegalArgument)
        XCTAssertEqual(count, 0)
        XCTAssertEqual(unsafe AeroSpaceCopyWindowInfo(nil, 0, nil, 0, &count), .success)
        XCTAssertEqual(count, 0)
        XCTAssertEqual(AeroSpaceCopyWindowInfo(nil, 0, nil, 0, nil), .illegalArgument)
    }

    private func record(windowId: UInt32 = 42, pid: Int32 = 123, bounds: CGRect = CGRect(x: 13, y: 13, width: 800, height: 600)) -> AeroSpaceWindowInfo {
        AeroSpaceWindowInfo(windowId: windowId, pid: pid, layer: 0, bounds: bounds)
    }
}
