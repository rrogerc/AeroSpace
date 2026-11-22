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

    /// The right tile can't get the fullscreen size where it is: AppKit clamps it at the right edge of the screen
    func testWindowThatGrowsToTheLeftOrUpMovesFirst() {
        XCTAssertTrue(update(fullscreen).movesFirst(from: rightTile, screens: [screen]))
        let bottomTile = CGRect(x: 13, y: 583, width: 2022, height: 556)
        XCTAssertTrue(update(fullscreen).movesFirst(from: bottomTile, screens: [screen]))
        let bottomRightTile = CGRect(x: 1031, y: 583, width: 1004, height: 556)
        XCTAssertTrue(update(fullscreen).movesFirst(from: bottomRightTile, screens: [screen]))
        // The right tile takes space from the left one
        XCTAssertTrue(update(CGRect(x: 831, y: 13, width: 1204, height: 1126)).movesFirst(from: rightTile, screens: [screen]))
    }

    func testWindowThatFitsWhereItIsGetsItsSizeFirst() {
        XCTAssertFalse(update(fullscreen).movesFirst(from: leftTile, screens: [screen]))
        XCTAssertFalse(update(rightTile).movesFirst(from: fullscreen, screens: [screen]))
        XCTAssertFalse(update(leftTile).movesFirst(from: rightTile, screens: [screen]))
        XCTAssertFalse(update(fullscreen).movesFirst(from: fullscreen, screens: [screen]))
    }

    func testOnlyAFrameWithBothPositionAndSizeCanMoveFirst() {
        XCTAssertFalse(WindowFrameUpdate(topLeft: fullscreen.origin, size: nil).movesFirst(from: rightTile, screens: [screen]))
        XCTAssertFalse(WindowFrameUpdate(topLeft: nil, size: fullscreen.size).movesFirst(from: rightTile, screens: [screen]))
    }

    /// A window that reaches into another monitor while it waits for its size is the case of
    /// https://github.com/nikitabobko/AeroSpace/issues/143. The size goes first there, like before
    func testWindowDoesNotMoveFirstIfItWouldSpanMonitorsOnTheWay() {
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        // A wide window that hangs over the right edge of the main monitor gets a tile at the right edge of the left one
        let overhanging = CGRect(x: 1900, y: 13, width: 600, height: 600)
        let target = CGRect(x: -450, y: 13, width: 400, height: 600)
        XCTAssertFalse(update(target).movesFirst(from: overhanging, screens: [left, screen]))
        // A window taller than the monitor where it goes
        let leftFullscreen = CGRect(x: -1907, y: 13, width: 1894, height: 1054)
        XCTAssertFalse(update(leftFullscreen).movesFirst(from: rightTile, screens: [left, screen]))
        // A frame that fits no monitor
        XCTAssertFalse(update(CGRect(x: 13, y: 13, width: 3000, height: 1126)).movesFirst(from: rightTile, screens: [screen]))
        XCTAssertFalse(update(fullscreen).movesFirst(from: rightTile, screens: []))
    }

    func testWindowMovesFirstOnTheMonitorWhereItEndsUp() {
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        // From the right tile of the left monitor to its fullscreen
        let from = CGRect(x: -953, y: 13, width: 940, height: 1054)
        let target = CGRect(x: -1907, y: 13, width: 1894, height: 1054)
        XCTAssertTrue(update(target).movesFirst(from: from, screens: [left, screen]))
    }

    private func update(_ frame: CGRect) -> WindowFrameUpdate { WindowFrameUpdate(topLeft: frame.origin, size: frame.size) }
}
