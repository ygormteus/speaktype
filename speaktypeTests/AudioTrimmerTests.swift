import AVFoundation
import XCTest
@testable import speaktype

final class AudioTrimmerTests: XCTestCase {
    private let rate = 16_000.0

    private func tone(seconds: Double, amplitude: Float = 0.2) -> [Float] {
        (0..<Int(seconds * rate)).map { amplitude * sin(Float($0) * 2 * .pi * 220 / Float(rate)) }
    }

    /// Low deterministic noise, ≈ -66 dBFS, like a quiet room.
    private func noise(seconds: Double, amplitude: Float = 0.0007) -> [Float] {
        (0..<Int(seconds * rate)).map { amplitude * (($0 * 7919) % 2 == 0 ? 1 : -1) }
    }

    func testTrimsLeadingAndTrailingSilenceKeepingPadding() throws {
        let samples = noise(seconds: 1) + tone(seconds: 2) + noise(seconds: 1.5)
        let range = try XCTUnwrap(AudioTrimmer.speechSampleRange(samples: samples, sampleRate: rate))
        // Speech spans 1.0…3.0 s; 150 ms padding on each side.
        XCTAssertEqual(Double(range.lowerBound) / rate, 0.85, accuracy: 0.021)
        XCTAssertEqual(Double(range.upperBound) / rate, 3.15, accuracy: 0.021)
    }

    func testPaddingIsClampedToFileBounds() throws {
        let samples = tone(seconds: 1) + noise(seconds: 0.05)
        let range = try XCTUnwrap(AudioTrimmer.speechSampleRange(samples: samples, sampleRate: rate))
        XCTAssertEqual(range, 0..<samples.count)
    }

    func testAllSilenceReturnsNil() {
        XCTAssertNil(AudioTrimmer.speechSampleRange(samples: noise(seconds: 3), sampleRate: rate))
        XCTAssertNil(AudioTrimmer.speechSampleRange(samples: [Float](repeating: 0, count: 16_000), sampleRate: rate))
        XCTAssertNil(AudioTrimmer.speechSampleRange(samples: [Float](), sampleRate: rate))
    }

    func testIsolatedClickIsNotSpeech() {
        let samples = noise(seconds: 1) + tone(seconds: 0.03, amplitude: 0.9) + noise(seconds: 1)
        XCTAssertNil(AudioTrimmer.speechSampleRange(samples: samples, sampleRate: rate))
    }

    func testQuietSpeechAboveFloorIsKept() throws {
        // ≈ -43 dBFS speech over a ≈ -66 dBFS floor.
        let samples = noise(seconds: 1) + tone(seconds: 1, amplitude: 0.01) + noise(seconds: 1)
        XCTAssertNotNil(AudioTrimmer.speechSampleRange(samples: samples, sampleRate: rate))
    }

    func testInt16Samples() throws {
        let floats = noise(seconds: 0.5) + tone(seconds: 1) + noise(seconds: 0.5)
        let ints = floats.map { Int16(max(-1, min(1, $0)) * Float(Int16.max)) }
        let range = try XCTUnwrap(AudioTrimmer.speechSampleRange(samples: ints, sampleRate: rate))
        XCTAssertEqual(Double(range.lowerBound) / rate, 0.35, accuracy: 0.021)
        XCTAssertEqual(AudioTrimmer.frameRMS(samples: ints, frameLength: 320).count, 100)
    }

    // MARK: - File I/O

    private func writeWAV(_ samples: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("trim-test-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer {
            buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testTrimSilenceWritesTrimmedCopyAndKeepsOriginal() throws {
        let url = try writeWAV(noise(seconds: 1) + tone(seconds: 2) + noise(seconds: 1))
        guard case .trimmed(let trimmed) = AudioTrimmer.trimSilence(in: url) else {
            return XCTFail("expected a trimmed copy")
        }
        defer { try? FileManager.default.removeItem(at: trimmed) }
        XCTAssertNotEqual(trimmed, url)
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 64_000)
        let trimmedFile = try AVAudioFile(forReading: trimmed)
        XCTAssertEqual(Double(trimmedFile.length) / rate, 2.3, accuracy: 0.05)
        XCTAssertEqual(trimmedFile.fileFormat.sampleRate, rate)
    }

    func testTrimSilenceReportsSilentFile() throws {
        let url = try writeWAV(noise(seconds: 2))
        XCTAssertEqual(AudioTrimmer.trimSilence(in: url), .silent)
    }

    func testTrimSilenceLeavesTightRecordingUnchanged() throws {
        let url = try writeWAV(noise(seconds: 0.1) + tone(seconds: 2) + noise(seconds: 0.1))
        XCTAssertEqual(AudioTrimmer.trimSilence(in: url), .unchanged)
    }

    func testTrimSilenceOnUnreadableFileIsUnchanged() {
        let missing = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).wav")
        XCTAssertEqual(AudioTrimmer.trimSilence(in: missing), .unchanged)
    }
}
