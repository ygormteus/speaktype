import Foundation

nonisolated struct FnDoubleTapGesture {
    enum Action: Equatable {
        case none
        case start
        case deferStop
        case latch
        case stop
    }

    static let doubleTapInterval: TimeInterval = 0.35
    static let maximumTapDuration: TimeInterval = 0.25

    private var isPressed = false
    private var pressedAt: TimeInterval?
    private var releasedAt: TimeInterval?
    private(set) var isLatched = false

    var isActive: Bool {
        isLatched || pressedAt != nil || releasedAt != nil
    }

    mutating func handle(isPressed: Bool, at timestamp: TimeInterval) -> Action {
        guard isPressed != self.isPressed else { return .none }
        self.isPressed = isPressed

        if isPressed {
            if isLatched {
                isLatched = false
                pressedAt = nil
                return .stop
            }
            if let releasedAt,
                timestamp - releasedAt >= 0,
                timestamp - releasedAt <= Self.doubleTapInterval
            {
                self.releasedAt = nil
                pressedAt = nil
                isLatched = true
                return .latch
            }
            releasedAt = nil
            pressedAt = timestamp
            return .start
        }

        guard !isLatched, let pressedAt else { return .none }
        self.pressedAt = nil
        if timestamp - pressedAt <= Self.maximumTapDuration {
            releasedAt = timestamp
            return .deferStop
        }
        return .stop
    }

    mutating func finishPendingTap() -> Action {
        guard releasedAt != nil else { return .none }
        releasedAt = nil
        return .stop
    }

    mutating func reset() {
        self = Self()
    }
}
