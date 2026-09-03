import AVFoundation
import XCTest
@testable import speaktype

final class AudioRecordingServiceTests: XCTestCase {
    
    var service: AudioRecordingService!
    
    override func setUpWithError() throws {
        service = AudioRecordingService()
    }

    override func tearDownWithError() throws {
        service = nil
    }

    func testInitialization() {
        XCTAssertNotNil(service)
        XCTAssertFalse(service.isRecording)
        XCTAssertEqual(service.audioLevel, 0.0)
    }
    
    func testStopRecordingWhenNotRecording() async {
        let url = await service.stopRecording()
        XCTAssertNil(url, "Should return nil url when not recording")
    }

    @MainActor
    func testStartRecordingDoesNotEnterRecordingStateWhenMicrophoneAccessIsDenied() async {
        let service = AudioRecordingService(
            microphoneAuthorizationStatus: { .notDetermined },
            requestMicrophoneAccess: { completion in completion(false) }
        )

        let didStart = await service.startRecording()

        XCTAssertFalse(didStart)
        XCTAssertFalse(service.isRecording)
    }
    
    // Note: Testing startRecording requires AVFoundation mocking or integration tests
    // due to hardware dependencies.
}
