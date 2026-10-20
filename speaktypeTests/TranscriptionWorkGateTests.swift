import XCTest
@testable import speaktype

@MainActor
final class TranscriptionWorkGateTests: XCTestCase {
    func testInferenceIsSerializedAcrossSuspensions() async {
        let gate = TranscriptionWorkGate()
        var active = 0
        var peak = 0
        let jobs = (0..<8).map { _ in
            Task { @MainActor in
                await gate.acquire()
                defer { gate.release() }
                active += 1
                peak = max(peak, active)
                await Task.yield()
                active -= 1
            }
        }
        for job in jobs { await job.value }
        XCTAssertEqual(peak, 1)
        XCTAssertEqual(active, 0)
    }
}
