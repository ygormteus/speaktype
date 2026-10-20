import AppKit
import XCTest
@testable import speaktype

@MainActor
final class PassiveKeyDownObserverTests: XCTestCase {
    func testUsesPassiveAnnotatedSessionTapForKeyDownOnly() throws {
        let harness = TapHarness()
        let observer = try XCTUnwrap(harness.makeObserver { _ in })
        XCTAssertEqual(harness.location, .cgAnnotatedSessionEventTap)
        XCTAssertEqual(harness.placement, .tailAppendEventTap)
        XCTAssertEqual(harness.options, .listenOnly)
        XCTAssertEqual(harness.mask, CGEventMask(1) << CGEventType.keyDown.rawValue)
        XCTAssertEqual(harness.enableCalls, 1)
        observer.stop()
        XCTAssertFalse(CFMachPortIsValid(try XCTUnwrap(harness.port)))
    }

    func testForwardsRepeatsAndModifiersWithoutReplacingOrSwallowingEvents() throws {
        let harness = TapHarness()
        var received: [NSEvent] = []
        let observer = try XCTUnwrap(harness.makeObserver { received.append($0) })
        defer { observer.stop() }
        let event = try keyEvent(target: harness.processID + 1)
        event.flags = .maskShift
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        for _ in 0..<2 {
            let returned = try harness.deliver(.keyDown, event)
            XCTAssertEqual(returned?.toOpaque(), Unmanaged.passUnretained(event).toOpaque())
        }
        XCTAssertEqual(received.count, 2)
        XCTAssertTrue(received.allSatisfy { $0.keyCode == 7 && $0.isARepeat && $0.modifierFlags.contains(.shift) })
    }

    func testOwnAppEventsStayWithLocalMonitorsAndOtherEventsPassUnchanged() throws {
        let harness = TapHarness()
        var received = 0
        let observer = try XCTUnwrap(harness.makeObserver { _ in received += 1 })
        defer { observer.stop() }
        for (type, target) in [(CGEventType.keyDown, harness.processID), (.flagsChanged, harness.processID + 1)] {
            let event = try keyEvent(target: target)
            XCTAssertEqual(try harness.deliver(type, event)?.toOpaque(), Unmanaged.passUnretained(event).toOpaque())
        }
        XCTAssertEqual(received, 0)
    }

    func testTimeoutRecoveryAndStopAreBoundedByObserverLifetime() throws {
        let harness = TapHarness()
        var received = 0
        let observer = try XCTUnwrap(harness.makeObserver { _ in received += 1 })
        let event = try keyEvent(target: harness.processID + 1)
        _ = try harness.deliver(.tapDisabledByTimeout, event)
        XCTAssertEqual(harness.enableCalls, 2)
        observer.stop()
        observer.stop()
        _ = try harness.deliver(.tapDisabledByTimeout, event)
        _ = try harness.deliver(.keyDown, event)
        XCTAssertEqual(harness.enableCalls, 2)
        XCTAssertEqual(received, 0)
    }

    func testUnknownTargetUsesForegroundStateWithoutFilteringPhysicalRepeats() throws {
        let harness = TapHarness()
        var received = 0
        let observer = try XCTUnwrap(harness.makeObserver { _ in received += 1 })
        defer { observer.stop() }
        let event = try keyEvent(target: 0)
        harness.isActive = true
        _ = try harness.deliver(.keyDown, event)
        harness.isActive = false
        _ = try harness.deliver(.keyDown, event)
        _ = try harness.deliver(.keyDown, event)
        XCTAssertEqual(received, 2)
    }

    func testFailedInstallationDoesNotCreateAnObserverAndDeinitInvalidatesPort() throws {
        XCTAssertNil(PassiveKeyDownObserver(handler: { _ in }, createTap: { _, _, _, _, _, _ in nil }))
        let harness = TapHarness()
        var observer = harness.makeObserver { _ in }
        XCTAssertNotNil(observer)
        let port = try XCTUnwrap(harness.port)
        observer = nil
        XCTAssertFalse(CFMachPortIsValid(port))
    }

    private func keyEvent(target: Int32) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 7, keyDown: true))
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(target))
        return event
    }
}

@MainActor
private final class TapHarness {
    let processID: Int32 = 12345
    var location: CGEventTapLocation?
    var placement: CGEventTapPlacement?
    var options: CGEventTapOptions?
    var mask: CGEventMask?
    var callback: CGEventTapCallBack?
    var context: UnsafeMutableRawPointer?
    var port: CFMachPort?
    var enableCalls = 0
    var isActive = false

    func makeObserver(handler: @escaping (NSEvent) -> Void) -> PassiveKeyDownObserver? {
        PassiveKeyDownObserver(handler: handler, createTap: { location, placement, options, mask, callback, context in
            self.location = location
            self.placement = placement
            self.options = options
            self.mask = mask
            self.callback = callback
            self.context = context
            let port = CFMachPortCreate(nil, { _, _, _, _ in }, nil, nil)
            self.port = port
            return port
        }, enableTap: { _, _ in self.enableCalls += 1 }, processID: processID, isApplicationActive: { self.isActive })
    }

    func deliver(_ type: CGEventType, _ event: CGEvent) throws -> Unmanaged<CGEvent>? {
        try XCTUnwrap(callback)(OpaquePointer(bitPattern: 1)!, type, event, context)
    }
}
