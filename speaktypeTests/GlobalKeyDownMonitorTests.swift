import AppKit
import XCTest
@testable import speaktype

@MainActor
final class GlobalKeyDownMonitorTests: XCTestCase {
    func testConsumersShareOneNativeObserver() throws {
        var installations = 0
        var receive: ((NSEvent) -> Void)?
        let monitor = GlobalKeyDownMonitor(install: { handler in
            installations += 1
            receive = handler
            return NSObject()
        }, remove: { _ in })
        var hotkeyEvents = 0
        var escapeEvents = 0
        let hotkey = monitor.addHandler { _ in hotkeyEvents += 1 }
        let escape = monitor.addHandler { _ in escapeEvents += 1 }

        try XCTUnwrap(receive)(keyEvent())

        XCTAssertEqual(installations, 1)
        XCTAssertEqual(hotkeyEvents, 1)
        XCTAssertEqual(escapeEvents, 1)
        monitor.removeHandler(hotkey)
        monitor.removeHandler(escape)
    }

    func testRemovingOneConsumerKeepsOthersAndLastRemovalStopsObserver() throws {
        var receive: ((NSEvent) -> Void)?
        var removals = 0
        let monitor = GlobalKeyDownMonitor(install: { handler in receive = handler; return NSObject() }, remove: { _ in removals += 1 })
        var removedEvents = 0
        var remainingEvents = 0
        let removed = monitor.addHandler { _ in removedEvents += 1 }
        let remaining = monitor.addHandler { _ in remainingEvents += 1 }
        monitor.removeHandler(removed)
        try XCTUnwrap(receive)(keyEvent())
        XCTAssertEqual(removedEvents, 0)
        XCTAssertEqual(remainingEvents, 1)
        XCTAssertEqual(removals, 0)
        monitor.removeHandler(remaining)
        monitor.removeHandler(remaining)
        XCTAssertEqual(removals, 1)
    }

    func testRecorderReappearanceDoesNotInstallAnotherNativeObserver() {
        var installations = 0
        var removals = 0
        let monitor = GlobalKeyDownMonitor(install: { _ in installations += 1; return NSObject() }, remove: { _ in removals += 1 })
        let hotkey = monitor.addHandler { _ in }
        for _ in 0..<5 {
            let recorder = monitor.addHandler { _ in }
            monitor.removeHandler(recorder)
        }
        XCTAssertEqual(installations, 1)
        XCTAssertEqual(removals, 0)
        monitor.removeHandler(hotkey)
        XCTAssertEqual(removals, 1)
        let restarted = monitor.addHandler { _ in }
        XCTAssertEqual(installations, 2)
        monitor.removeHandler(restarted)
    }

    func testLegitimateRepeatedEventsAreNotFiltered() throws {
        var receive: ((NSEvent) -> Void)?
        let monitor = GlobalKeyDownMonitor(install: { handler in receive = handler; return NSObject() }, remove: { _ in })
        var received: [NSEvent] = []
        let token = monitor.addHandler { received.append($0) }
        let event = try keyEvent()
        try XCTUnwrap(receive)(event)
        try XCTUnwrap(receive)(event)
        try XCTUnwrap(receive)(keyEvent(repeating: true))
        XCTAssertEqual(received.count, 3)
        XCTAssertTrue(received[0] === event)
        XCTAssertTrue(received[1] === event)
        XCTAssertTrue(received[2].isARepeat)
        monitor.removeHandler(token)
    }

    func testDeinitializationRemovesNativeObserver() {
        var removals = 0
        var monitor: GlobalKeyDownMonitor? = GlobalKeyDownMonitor(install: { _ in NSObject() }, remove: { _ in removals += 1 })
        _ = monitor?.addHandler { _ in }
        monitor = nil
        XCTAssertEqual(removals, 1)
    }

    private func keyEvent(repeating: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: 0, context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: repeating, keyCode: 7))
    }
}
