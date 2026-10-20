import AVFoundation
import XCTest
@testable import speaktype

final class MeetingAudioCaptureTests: XCTestCase {
    func testConversionPreservesFramesLargerThanConverterRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = MeetingSegmentWriter(directory: root, source: .microphone, onSegment: { _ in }, onFailure: { _, _ in })
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0.05, count: 48_000) }
        writer.submit(buffer, offset: 0)
        let result = await writer.finish()
        let segment = try XCTUnwrap(result.segments.first)
        let file = try AVAudioFile(forReading: root.appendingPathComponent(segment.fileName))
        XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, 1, accuracy: 0.02)
    }

    func testPausePublishesSpeechBeforeFifteenSeconds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = MeetingSegmentWriter(directory: root, source: .microphone, onSegment: { _ in }, onFailure: { _, _ in })
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        func audio(frames: AVAudioFrameCount, value: Float) -> AVAudioPCMBuffer {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            buffer.floatChannelData![0].initialize(repeating: value, count: Int(frames))
            return buffer
        }
        writer.submit(audio(frames: 48_000, value: 0.08), offset: 0)
        writer.submit(audio(frames: 8_000, value: 0), offset: 3)
        writer.submit(audio(frames: 16_000, value: 0.08), offset: 3.5)
        let result = await writer.finish()
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments.first?.end ?? 0, 3.5, accuracy: 0.05)
    }

    func testGapAfterRotationIsReported() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = MeetingSegmentWriter(directory: root, source: .microphone, onSegment: { _ in }, onFailure: { _, _ in })
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256_000)!
        buffer.frameLength = 256_000
        writer.submit(buffer, offset: 0)
        writer.submit(buffer, offset: 21)
        let result = await writer.finish()
        XCTAssertEqual(result.failureStorage, false)
        XCTAssertEqual(result.segments.count, 1)
    }

    func testClosedSegmentIsNormalizedAndRecoverable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = MeetingSegmentWriter(directory: root, source: .microphone, onSegment: { _ in }, onFailure: { _, _ in })
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = 4800
        writer.submit(buffer, offset: 0)
        let result = await writer.finish()
        let segment = try XCTUnwrap(result.segments.first)
        XCTAssertNil(result.failureStorage)
        let file = try AVAudioFile(forReading: root.appendingPathComponent(segment.fileName))
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        XCTAssertGreaterThan(file.length, 0)
        XCTAssertEqual(segment.end, 0.1, accuracy: 0.001)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(segment.id.uuidString + ".segment.json").path))
    }
}
