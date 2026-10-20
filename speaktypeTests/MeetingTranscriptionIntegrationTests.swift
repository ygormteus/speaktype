import AVFoundation
import XCTest
@testable import speaktype

@MainActor
final class MeetingTranscriptionIntegrationTests: XCTestCase {
    func testLocalPortugueseMeetingPipeline() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let input = environment["SPEAKTYPE_MEETING_AUDIO"], let output = environment["SPEAKTYPE_MEETING_REPORT"] else {
            throw XCTSkip("Opt-in local audio integration check")
        }
        let manager = TranscriptionManager.shared
        while manager.isLoading || manager.isWarmingUp { try await Task.sleep(for: .milliseconds(100)) }
        let loadStarted = Date()
        let variant = try await manager.prepareMeeting(variant: environment["SPEAKTYPE_MEETING_VARIANT"] ?? "openai_whisper-large-v3_turbo", language: "pt")
        let loadSeconds = Date().timeIntervalSince(loadStarted)
        defer { manager.releaseMeeting() }
        let audio = URL(fileURLWithPath: input)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try AVAudioFile(forReading: audio)
        let writer = MeetingSegmentWriter(directory: directory, source: .microphone, onSegment: { _ in }, onFailure: { _, _ in })
        let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 4096)!
        while source.framePosition < source.length {
            let offset = Double(source.framePosition) / source.processingFormat.sampleRate
            try source.read(into: buffer)
            writer.submit(buffer, offset: offset)
            try await Task.sleep(for: .milliseconds(10))
        }
        let captured = await writer.finish()
        XCTAssertNil(captured.failureStorage)
        XCTAssertFalse(captured.segments.isEmpty)
        let started = Date()
        var parts: [String] = []
        for segment in captured.segments {
            parts.append(try await manager.transcribeMeetingSegment(directory.appendingPathComponent(segment.fileName), language: "pt", variant: variant))
        }
        let text = parts.joined(separator: " ")
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let reference = environment["SPEAKTYPE_MEETING_REFERENCE"] ?? "Esta é uma reunião de teste em português. Vamos revisar o projeto e marcar a próxima reunião para amanhã."
        let wordErrorRate = WordErrorRate.compute(reference: reference, hypothesis: text, foldingDiacritics: true).rate
        XCTAssertLessThan(wordErrorRate, 0.35)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        var warmSeconds: [TimeInterval] = []
        var warmWordErrorRates: [Double] = []
        if environment["SPEAKTYPE_MEETING_BENCHMARK"] == "1" {
            for _ in 0..<3 {
                let warmStarted = Date()
                var warmParts: [String] = []
                for segment in captured.segments {
                    let warmText = try await manager.transcribeMeetingSegment(directory.appendingPathComponent(segment.fileName), language: "pt", variant: variant)
                    warmParts.append(warmText)
                }
                let warmRate = WordErrorRate.compute(reference: reference, hypothesis: warmParts.joined(separator: " "), foldingDiacritics: true).rate
                XCTAssertLessThan(warmRate, 0.35)
                warmWordErrorRates.append(warmRate)
                warmSeconds.append(Date().timeIntervalSince(warmStarted))
            }
        }
        let report: [String: Any] = ["elapsedSeconds": elapsed, "loadSeconds": loadSeconds, "warmSeconds": warmSeconds, "warmWordErrorRates": warmWordErrorRates, "audioSeconds": Double(source.length) / source.processingFormat.sampleRate, "characters": text.count, "model": variant, "wordErrorRate": wordErrorRate, "capturedParts": captured.segments.count]
        try JSONSerialization.data(withJSONObject: report, options: .prettyPrinted).write(to: URL(fileURLWithPath: output), options: .atomic)
    }
}
