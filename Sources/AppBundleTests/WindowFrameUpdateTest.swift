@testable import AppBundle
import Common
import CoreGraphics
import XCTest

/// The frames are the ones of two tiles on a monitor 2048 points wide, with gaps of 13 points
final class WindowFrameUpdateTest: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 2048, height: 1152)
    private let fullscreen = CGRect(x: 13, y: 13, width: 2022, height: 1126)
    private let leftTile = CGRect(x: 13, y: 13, width: 1005, height: 1126)
    private let rightTile = CGRect(x: 1031, y: 13, width: 1004, height: 1126)

    func testTilesWithHalfPointsLandOnWholePointsAndKeepTheirGaps() {
        let left = update(CGRect(x: 13, y: 13, width: 1004.5, height: 1126)).onWholePoints
        let right = update(CGRect(x: 1030.5, y: 13, width: 1004.5, height: 1126)).onWholePoints
        XCTAssertEqual(left, update(leftTile))
        XCTAssertEqual(right, update(rightTile))
        XCTAssertEqual(rightTile.minX - leftTile.maxX, 13) // Inner gap
        XCTAssertEqual(screen.maxX - rightTile.maxX, 13) // Outer gap

        let top = update(CGRect(x: 13, y: 13, width: 2022, height: 556.5)).onWholePoints
        let bottom = update(CGRect(x: 13, y: 582.5, width: 2022, height: 556.5)).onWholePoints
        XCTAssertEqual(top, update(CGRect(x: 13, y: 13, width: 2022, height: 557)))
        XCTAssertEqual(bottom, update(CGRect(x: 13, y: 583, width: 2022, height: 556)))
    }

    func testWholePointsAreNotChanged() {
        for frame in [fullscreen, leftTile, rightTile, CGRect(x: -1920, y: -1080, width: 800, height: 600)] {
            XCTAssertEqual(update(frame).onWholePoints, update(frame))
        }
        XCTAssertEqual(WindowFrameUpdate(topLeft: nil, size: nil).onWholePoints, WindowFrameUpdate(topLeft: nil, size: nil))
    }

    func testHalvesRoundTheSameWayOnBothSidesOfZero() {
        // Two tiles on a monitor above the main one, with x from -1024 to 1024: the gap between them is around zero.
        // Rounding halves away from zero would move its edges apart
        let left = update(CGRect(x: -1011, y: -1139, width: 1004.5, height: 1126)).onWholePoints
        let right = update(CGRect(x: 6.5, y: -1139, width: 1004.5, height: 1126)).onWholePoints
        XCTAssertEqual(left, update(CGRect(x: -1011, y: -1139, width: 1005, height: 1126)))
        XCTAssertEqual(right, update(CGRect(x: 7, y: -1139, width: 1004, height: 1126)))
        XCTAssertEqual(right.topLeft.orDie().x - (left.topLeft.orDie().x + left.size.orDie().width), 13)
    }

    func testMoveOrResizeAloneIsRoundedToo() {
        XCTAssertEqual(
            WindowFrameUpdate(topLeft: CGPoint(x: 356.74, y: 12.5), size: nil).onWholePoints,
            WindowFrameUpdate(topLeft: CGPoint(x: 357, y: 13), size: nil),
        )
        XCTAssertEqual(
            WindowFrameUpdate(topLeft: nil, size: CGSize(width: 1334.52, height: 600.5)).onWholePoints,
            WindowFrameUpdate(topLeft: nil, size: CGSize(width: 1335, height: 601)),
        )
    }

    func testWholePointFrameOfATileIsNotWrittenAgain() {
        let requested = update(CGRect(x: 1030.5, y: 13, width: 1004.5, height: 1126))
        // What AppKit made of the half points. It never matched the request
        let roundedByApp = CGRect(x: 1030, y: 13, width: 1005, height: 1126)
        XCTAssertFalse(requested.skippingUnchangedValues(comparedTo: roundedByApp).isEmpty)
        XCTAssertTrue(requested.onWholePoints.skippingUnchangedValues(comparedTo: rightTile).isEmpty)
    }

    private func update(_ frame: CGRect) -> WindowFrameUpdate { WindowFrameUpdate(topLeft: frame.origin, size: frame.size) }
}
