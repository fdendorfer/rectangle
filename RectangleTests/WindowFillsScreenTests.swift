/// WindowFillsScreenTests.swift

import XCTest
@testable import Rectangle

class FrameFillsScreenTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 3440, height: 1415)

    func testExactFrameFills() {
        XCTAssertTrue(frameFillsScreen(screen, visibleFrameOfScreen: screen, tolerance: 8))
    }

    func testNullFramesNeverFill() {
        XCTAssertFalse(frameFillsScreen(.null, visibleFrameOfScreen: screen, tolerance: 8))
        XCTAssertFalse(frameFillsScreen(screen, visibleFrameOfScreen: .null, tolerance: 8))
    }

    func testOneEdgeBeyondToleranceDoesNotFill() {
        var short = screen
        short.size.width -= 40
        XCTAssertFalse(frameFillsScreen(short, visibleFrameOfScreen: screen, tolerance: 8))
    }

    func testOversizedFrameStillFillsWithinTolerance() {
        // Some apps overshoot the usable area by a point or two.
        let overshoot = screen.insetBy(dx: -3, dy: -3)
        XCTAssertTrue(frameFillsScreen(overshoot, visibleFrameOfScreen: screen, tolerance: 8))
    }
}
