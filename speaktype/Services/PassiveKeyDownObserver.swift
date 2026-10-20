import AppKit

@MainActor
final class PassiveKeyDownObserver {
    typealias TapCreator = (CGEventTapLocation, CGEventTapPlacement, CGEventTapOptions, CGEventMask,
        CGEventTapCallBack, UnsafeMutableRawPointer?) -> CFMachPort?

    private let handler: (NSEvent) -> Void
    private let enableTap: (CFMachPort, Bool) -> Void
    private let processID: Int32
    private let isApplicationActive: () -> Bool
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    init?(handler: @escaping (NSEvent) -> Void,
          createTap: TapCreator = { location, placement, options, mask, callback, context in
              CGEvent.tapCreate(tap: location, place: placement, options: options,
                  eventsOfInterest: mask, callback: callback, userInfo: context)
          }, enableTap: @escaping (CFMachPort, Bool) -> Void = { CGEvent.tapEnable(tap: $0, enable: $1) },
          processID: Int32 = ProcessInfo.processInfo.processIdentifier,
          isApplicationActive: @escaping () -> Bool = { NSApp?.isActive == true }) {
        self.handler = handler
        self.enableTap = enableTap
        self.processID = processID
        self.isApplicationActive = isApplicationActive
        let callback: CGEventTapCallBack = { _, type, event, context in
            if let context {
                MainActor.assumeIsolated {
                    Unmanaged<PassiveKeyDownObserver>.fromOpaque(context).takeUnretainedValue().receive(type, event: event)
                }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = createTap(.cgAnnotatedSessionEventTap, .tailAppendEventTap, .listenOnly,
            CGEventMask(1) << CGEventType.keyDown.rawValue, callback, Unmanaged.passUnretained(self).toOpaque()) else { return nil }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return nil
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        enableTap(tap, true)
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
    }

    func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            self.source = nil
        }
        if let tap {
            self.tap = nil
            CFMachPortInvalidate(tap)
        }
    }

    private func receive(_ type: CGEventType, event: CGEvent) {
        guard let tap else { return }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            enableTap(tap, true)
            return
        }
        guard type == .keyDown else { return }
        let target = event.getIntegerValueField(.eventTargetUnixProcessID)
        guard target != Int64(processID), !(target == 0 && isApplicationActive()),
              let keyEvent = NSEvent(cgEvent: event) else { return }
        handler(keyEvent)
    }
}
