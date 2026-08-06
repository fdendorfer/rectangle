/// DisplayChangeTests.swift

import XCTest
@testable import Rectangle

class WindowLayoutMatchingTests: XCTestCase {

    private func snapshot(_ bundleId: String,
                          windowId: CGWindowID,
                          title: String? = nil,
                          index: Int = 0,
                          frame: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100)) -> WindowSnapshot {
        WindowSnapshot(bundleId: bundleId, windowId: windowId, title: title, index: index, frame: frame)
    }

    private func identity(_ bundleId: String,
                          windowId: CGWindowID?,
                          title: String? = nil,
                          index: Int = 0) -> WindowIdentity {
        WindowIdentity(bundleId: bundleId, windowId: windowId, title: title, index: index)
    }

    func testMatchesByWindowId() {
        let frame = CGRect(x: 10, y: 20, width: 300, height: 400)
        let result = WindowLayoutStore.match(
            snapshots: [snapshot("com.apple.Safari", windowId: 7, title: "Old title", frame: frame)],
            identities: [identity("com.apple.Safari", windowId: 7, title: "New title")])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.identityIndex, 0)
        XCTAssertEqual(result.first?.frame, frame)
    }

    func testNeverMatchesAcrossApps() {
        let result = WindowLayoutStore.match(
            snapshots: [snapshot("com.apple.Safari", windowId: 7, title: "Same")],
            identities: [identity("com.apple.Terminal", windowId: 7, title: "Same")])

        XCTAssertTrue(result.isEmpty)
    }

    func testFallsBackToTitleWhenWindowIdIsStale() {
        let frame = CGRect(x: 1, y: 2, width: 3, height: 4)
        let result = WindowLayoutStore.match(
            snapshots: [snapshot("com.apple.Terminal", windowId: 7, title: "flo — zsh", frame: frame)],
            identities: [identity("com.apple.Terminal", windowId: 99, title: "flo — zsh")])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.frame, frame)
    }

    func testEmptyTitleDoesNotMatch() {
        let result = WindowLayoutStore.match(
            snapshots: [snapshot("com.apple.Terminal", windowId: 7, title: "", index: 0)],
            identities: [identity("com.apple.Terminal", windowId: 99, title: "", index: 3)])

        XCTAssertTrue(result.isEmpty)
    }

    func testFallsBackToIndexWhenWindowCountIsUnchanged() {
        let first = CGRect(x: 0, y: 0, width: 10, height: 10)
        let second = CGRect(x: 50, y: 50, width: 10, height: 10)
        let result = WindowLayoutStore.match(
            snapshots: [snapshot("com.apple.Terminal", windowId: 1, title: "gone", index: 0, frame: first),
                        snapshot("com.apple.Terminal", windowId: 2, title: "gone too", index: 1, frame: second)],
            identities: [identity("com.apple.Terminal", windowId: 10, title: "new", index: 0),
                         identity("com.apple.Terminal", windowId: 11, title: "newer", index: 1)])

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first { $0.identityIndex == 0 }?.frame, first)
        XCTAssertEqual(result.first { $0.identityIndex == 1 }?.frame, second)
    }

    func testIndexFallbackIsSkippedWhenWindowCountChanged() {
        let result = WindowLayoutStore.match(
            snapshots: [snapshot("com.apple.Terminal", windowId: 1, title: "gone", index: 0)],
            identities: [identity("com.apple.Terminal", windowId: 10, title: "new", index: 0),
                         identity("com.apple.Terminal", windowId: 11, title: "newer", index: 1)])

        XCTAssertTrue(result.isEmpty, "A newly opened window must not inherit an unrelated saved frame")
    }

    func testEachLiveWindowIsClaimedOnce() {
        let byId = CGRect(x: 0, y: 0, width: 10, height: 10)
        let byTitle = CGRect(x: 20, y: 20, width: 10, height: 10)
        let result = WindowLayoutStore.match(
            snapshots: [snapshot("com.apple.Terminal", windowId: 5, title: "shared", frame: byId),
                        snapshot("com.apple.Terminal", windowId: 6, title: "shared", index: 1, frame: byTitle)],
            identities: [identity("com.apple.Terminal", windowId: 5, title: "shared")])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.frame, byId)
    }
}

class WindowFillingDisplayTests: XCTestCase {

    private let laptop = CGRect(x: 0, y: 38, width: 1512, height: 944)
    private let external = CGRect(x: 1512, y: 0, width: 3440, height: 1415)

    private func snapshot(_ windowId: CGWindowID, frame: CGRect) -> WindowSnapshot {
        WindowSnapshot(bundleId: "com.apple.Safari", windowId: windowId, title: nil, index: 0, frame: frame)
    }

    func testExactFillIsDetectedOnEveryDisplay() {
        let result = WindowLayoutStore.windowIdsFillingDisplay(
            snapshots: [snapshot(1, frame: laptop), snapshot(2, frame: external)],
            screens: [laptop, external],
            tolerance: 8)

        XCTAssertEqual(result, Set([1, 2]))
    }

    func testNearFillWithinToleranceIsDetected() {
        let inset = external.insetBy(dx: 4, dy: 4)
        let result = WindowLayoutStore.windowIdsFillingDisplay(
            snapshots: [snapshot(1, frame: inset)], screens: [laptop, external], tolerance: 8)

        XCTAssertEqual(result, Set([1]))
    }

    func testGapSizedInsetNeedsTheWiderTolerance() {
        let gapped = external.insetBy(dx: 10, dy: 10)

        XCTAssertTrue(WindowLayoutStore.windowIdsFillingDisplay(
            snapshots: [snapshot(1, frame: gapped)], screens: [external], tolerance: 18).contains(1))
        XCTAssertFalse(WindowLayoutStore.windowIdsFillingDisplay(
            snapshots: [snapshot(1, frame: gapped)], screens: [external], tolerance: 8).contains(1))
    }

    func testHalfAndAlmostMaximizedWindowsAreNotFilling() {
        var half = external
        half.size.width /= 2
        let almost = external.insetBy(dx: external.width * 0.05, dy: external.height * 0.05)

        let result = WindowLayoutStore.windowIdsFillingDisplay(
            snapshots: [snapshot(1, frame: half), snapshot(2, frame: almost)],
            screens: [laptop, external],
            tolerance: 8)

        XCTAssertTrue(result.isEmpty)
    }

    func testWindowFillingNoDisplayAtAllIsNotDetected() {
        let result = WindowLayoutStore.windowIdsFillingDisplay(
            snapshots: [snapshot(1, frame: CGRect(x: 200, y: 200, width: 800, height: 600))],
            screens: [laptop, external],
            tolerance: 8)

        XCTAssertTrue(result.isEmpty)
    }
}

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
