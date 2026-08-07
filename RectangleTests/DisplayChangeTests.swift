/// DisplayChangeTests.swift

import XCTest
@testable import Rectangle

class ReapplyOnDisplayChangeTests: XCTestCase {

    func testScreenRelativeActionsAreReapplied() {
        XCTAssertTrue(WindowAction.maximize.reapplicableOnDisplayChange)
        XCTAssertTrue(WindowAction.maximizeHeight.reapplicableOnDisplayChange)
        XCTAssertTrue(WindowAction.almostMaximize.reapplicableOnDisplayChange)
        XCTAssertTrue(WindowAction.center.reapplicableOnDisplayChange)
        XCTAssertTrue(WindowAction.leftHalf.reapplicableOnDisplayChange)
        XCTAssertTrue(WindowAction.topRight.reapplicableOnDisplayChange)
        XCTAssertTrue(WindowAction.firstThird.reapplicableOnDisplayChange)
        XCTAssertTrue(WindowAction.bottomRightNinth.reapplicableOnDisplayChange)
    }

    func testRelativeAndMultiWindowActionsAreNotReapplied() {
        XCTAssertFalse(WindowAction.larger.reapplicableOnDisplayChange)
        XCTAssertFalse(WindowAction.smaller.reapplicableOnDisplayChange)
        XCTAssertFalse(WindowAction.moveLeft.reapplicableOnDisplayChange)
        XCTAssertFalse(WindowAction.nextDisplay.reapplicableOnDisplayChange)
        XCTAssertFalse(WindowAction.previousDisplay.reapplicableOnDisplayChange)
        XCTAssertFalse(WindowAction.tileAll.reapplicableOnDisplayChange)
        XCTAssertFalse(WindowAction.cascadeAll.reapplicableOnDisplayChange)
        XCTAssertFalse(WindowAction.restore.reapplicableOnDisplayChange)
        XCTAssertFalse(WindowAction.leftTodo.reapplicableOnDisplayChange)
    }
}

class DisplayConfigurationTests: XCTestCase {

    func testSignatureIsStableAndNonEmpty() {
        let first = DisplayConfiguration.current()
        let second = DisplayConfiguration.current()

        XCTAssertEqual(first.signature, second.signature)
        XCTAssertFalse(first.signature.isEmpty)
        XCTAssertEqual(first.screenCount, NSScreen.screens.count)
    }
}
