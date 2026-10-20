import AVFoundation
import XCTest
@testable import speaktype

@MainActor
final class AudioPlaybackExclusionTests: XCTestCase {
    func testPlaybackCannotStartDuringDictation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        var writer: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 16_000)
        try writer?.write(from: buffer)
        writer = nil
        let recorder = AudioRecordingService.shared
        let player = AudioPlayerService.shared
        let wasRecording = recorder.isRecording
        defer { recorder.isRecording = wasRecording; player.reset() }
        player.loadAudio(from: url)
        recorder.isRecording = true
        player.play()
        XCTAssertFalse(player.isPlaying)
    }
}
