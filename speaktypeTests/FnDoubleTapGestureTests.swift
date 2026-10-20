import XCTest
@testable import speaktype

final class FnDoubleTapGestureTests: XCTestCase {
    func testTwoQuickTapsLatchUntilNextPress() {
        var gesture = FnDoubleTapGesture()
        XCTAssertEqual(gesture.handle(isPressed: true, at: 1), .start)
        XCTAssertEqual(gesture.handle(isPressed: false, at: 1.08), .deferStop)
        XCTAssertEqual(gesture.handle(isPressed: true, at: 1.2), .latch)
        XCTAssertEqual(gesture.handle(isPressed: false, at: 1.28), .none)
        XCTAssertTrue(gesture.isLatched)
        XCTAssertEqual(gesture.handle(isPressed: true, at: 3), .stop)
        XCTAssertEqual(gesture.handle(isPressed: false, at: 3.1), .none)
        XCTAssertFalse(gesture.isLatched)
    }

    func testLongHoldStopsImmediatelyOnRelease() {
        var gesture = FnDoubleTapGesture()
        XCTAssertEqual(gesture.handle(isPressed: true, at: 1), .start)
        XCTAssertEqual(gesture.handle(isPressed: false, at: 2), .stop)
    }

    func testSingleTapExpiresAndNextPressStartsFresh() {
        var gesture = FnDoubleTapGesture()
        XCTAssertEqual(gesture.handle(isPressed: true, at: 1), .start)
        XCTAssertEqual(gesture.handle(isPressed: false, at: 1.1), .deferStop)
        XCTAssertEqual(gesture.finishPendingTap(), .stop)
        XCTAssertEqual(gesture.handle(isPressed: true, at: 2), .start)
        XCTAssertFalse(gesture.isLatched)
    }

    func testLateSecondPressDoesNotLatchEvenBeforeTimerRuns() {
        var gesture = FnDoubleTapGesture()
        _ = gesture.handle(isPressed: true, at: 1)
        _ = gesture.handle(isPressed: false, at: 1.1)
        XCTAssertEqual(gesture.handle(isPressed: true, at: 1.8), .start)
        XCTAssertFalse(gesture.isLatched)
        XCTAssertEqual(gesture.finishPendingTap(), .none)
    }

    func testDuplicateEdgesDoNotStopOrLatch() {
        var gesture = FnDoubleTapGesture()
        XCTAssertEqual(gesture.handle(isPressed: true, at: 1), .start)
        XCTAssertEqual(gesture.handle(isPressed: true, at: 1.06), .none)
        XCTAssertEqual(gesture.handle(isPressed: false, at: 1.1), .deferStop)
        XCTAssertEqual(gesture.handle(isPressed: false, at: 1.17), .none)
        XCTAssertEqual(gesture.handle(isPressed: true, at: 1.2), .latch)
        XCTAssertEqual(gesture.finishPendingTap(), .none)
    }

    func testResetDiscardsPendingStopAndLatch() {
        var gesture = FnDoubleTapGesture()
        _ = gesture.handle(isPressed: true, at: 1)
        _ = gesture.handle(isPressed: false, at: 1.1)
        gesture.reset()
        XCTAssertEqual(gesture.finishPendingTap(), .none)
        XCTAssertEqual(gesture.handle(isPressed: true, at: 1.2), .start)
        _ = gesture.handle(isPressed: false, at: 1.25)
        _ = gesture.handle(isPressed: true, at: 1.3)
        gesture.reset()
        XCTAssertFalse(gesture.isLatched)
        XCTAssertEqual(gesture.handle(isPressed: true, at: 2), .start)
    }
}
