import AVFoundation
import XCTest
@testable import speaktype

/// Opt-in end-to-end check of incremental Whisper transcription with real
/// models. Skipped unless `ST_STREAM_DEBUG` is set (pass it to xcodebuild as
/// `TEST_RUNNER_ST_STREAM_DEBUG=1`).
///
/// Builds a dictation from PT-BR clips (1 s of room noise at the start, end
/// and between clips), replays it through `SpeechSegmenter` in real time while
/// an incremental session transcribes the chunks, then compares text and
/// post-"release" latency against the full-file path.
///
/// Env:
/// - `ST_STREAM_DIR`    clip folder with `c1.wav`/`c1.txt`, `c2.wav`/`c2.txt` (default `/tmp/stbench`)
/// - `ST_STREAM_MODEL`  Whisper variant (default `openai_whisper-large-v3_turbo`)
/// - `ST_STREAM_OUT`    report path (default `/tmp/stbench-stream.txt`)
@MainActor
final class IncrementalWhisperStreamingTests: XCTestCase {
    private let sampleRate = 16_000.0
    /// Capture buffer size used for the replay (32 ms, close to AVCapture's).
    private let bufferSamples = 512

    private struct ScenarioResult {
        let lines: [String]
        let fullWER: Double
        let incrementalWER: Double
        let fellBack: Bool
    }

    func testIncrementalWhisperMatchesFullFileWithLowerReleaseLatency() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["ST_STREAM_DEBUG"] != nil else {
            throw XCTSkip("Set ST_STREAM_DEBUG (TEST_RUNNER_ST_STREAM_DEBUG=1) to run")
        }
        let directory = URL(fileURLWithPath: env["ST_STREAM_DIR"] ?? "/tmp/stbench")
        let variant = env["ST_STREAM_MODEL"] ?? "openai_whisper-large-v3_turbo"
        let outURL = URL(fileURLWithPath: env["ST_STREAM_OUT"] ?? "/tmp/stbench-stream.txt")

        var clips: [String: (samples: [Float], text: String)] = [:]
        for name in ["c1", "c2"] {
            clips[name] = (
                try readSamples(directory.appendingPathComponent("\(name).wav")),
                try String(contentsOf: directory.appendingPathComponent("\(name).txt"), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let downloads = ModelDownloadService.shared
        await downloads.refreshDownloadedModels()
        guard downloads.isDownloaded(variant) else { throw XCTSkip("\(variant) not downloaded") }

        let manager = TranscriptionManager.shared
        try await waitForBackgroundWarmUp(manager)
        try await manager.loadModel(variant: variant)
        // Untimed warm-up decode: first inference pays one-off ANE specialization.
        _ = try await manager.transcribe(
            audioFile: directory.appendingPathComponent("c1.wav"), language: "pt")
        XCTAssertNotNil(
            manager.makeIncrementalSession(variant: variant, language: "pt"),
            "a loaded Whisper model must allow an incremental session")

        var lines: [String] = []
        lines.append("Incremental Whisper benchmark — \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("Model: \(variant). Each dictation has 1 s of room noise (≈ -66 dBFS) at the")
        lines.append("start, the end and between clips; replayed in real time in 32 ms buffers.")
        lines.append("\"Release wait\" = time from the end of audio to the final text.")
        lines.append("")

        var results: [ScenarioResult] = []
        for scenario in [["c1", "c2"], ["c1", "c2", "c1", "c2"]] {
            let parts = scenario.compactMap { clips[$0] }
            let result = try await runScenario(
                name: scenario.joined(separator: "+"), parts: parts, variant: variant)
            results.append(result)
            lines += result.lines + [""]
        }

        // Silence trimming on its own (raw engine output, no finalize).
        let trimProbe = try writeWAV(compose(Array(clips.values)), name: "trimprobe")
        lines.append("Silence trimming, raw engine output (no finalize):")
        lines += try await trimmingLines(label: "Whisper", url: trimProbe) {
            try await WhisperService.shared.transcribe(audioFile: $0, language: "pt")
        }
        if let parakeet = ParakeetCatalog.variants.first(where: { downloads.isDownloaded($0) }) {
            try await manager.loadModel(variant: parakeet)
            _ = try await ParakeetEngine.shared.transcribe(audioFile: trimProbe, language: "pt")
            lines += try await trimmingLines(label: "Parakeet (\(parakeet))", url: trimProbe) {
                try await ParakeetEngine.shared.transcribe(audioFile: $0, language: "pt")
            }
        }

        let report = lines.joined(separator: "\n") + "\n"
        print(report)
        try report.write(to: outURL, atomically: true, encoding: .utf8)

        // Latency is reported, not asserted: it depends on machine load and on
        // whether Whisper decodes faster than real time on this hardware.
        for result in results {
            XCTAssertFalse(result.fellBack, "incremental session fell back to the full file")
            XCTAssertLessThanOrEqual(
                result.incrementalWER, result.fullWER + 0.15, "incremental text drifted from full-file text")
        }
    }

    private func runScenario(
        name: String, parts: [(samples: [Float], text: String)], variant: String
    ) async throws -> ScenarioResult {
        let manager = TranscriptionManager.shared
        let reference = parts.map(\.text).joined(separator: " ")
        let audio = compose(parts)
        let fullURL = try writeWAV(audio, name: "full")

        // --- Full-file path (what releasing the hotkey costs without chunks) ---
        let fullStart = Date()
        let fullText = try await manager.transcribe(audioFile: fullURL, language: "pt")
        let fullSeconds = Date().timeIntervalSince(fullStart)

        // --- Incremental path, replayed in real time ---
        // Same transcriber as `makeIncrementalSession`, plus per-decode logging.
        var decodeLog: [String] = []
        let session = IncrementalTranscriptionSession(transcriber: { url in
            let start = Date()
            let text = try await WhisperService.shared.transcribeChunk(audioFile: url, language: "pt")
            decodeLog.append(String(format: "    decode %.2f s → %@", Date().timeIntervalSince(start), text))
            return text
        })

        var segmenter = SpeechSegmenter()
        var pending: [Float] = []
        var chunkIndex = 0
        var boundaries: [String] = []
        var elapsedAudio: TimeInterval = 0
        let replayStart = Date()

        func emitChunk(stats: SpeechSegmenter.ChunkStats, isFinal: Bool = false) throws {
            let hasSpeech = segmenter.hasSpeech(stats, isFinalChunk: isFinal)
            let url = try writeWAV(pending, name: "chunk\(chunkIndex)")
            boundaries.append(String(
                format: "    chunk %d: ends at %.2f s, %.2f s long, speech %.2f s%@",
                chunkIndex, elapsedAudio, stats.duration, stats.speechDuration,
                hasSpeech ? "" : " (no speech: not decoded)"))
            session.append(RecordedAudioChunk(
                url: url, index: chunkIndex, duration: stats.duration,
                hasSpeech: hasSpeech, endedByForcedCut: stats.endedByForcedCut))
            chunkIndex += 1
            pending.removeAll(keepingCapacity: true)
        }

        for bufferStart in stride(from: 0, to: audio.count, by: bufferSamples) {
            let buffer = audio[bufferStart..<min(bufferStart + bufferSamples, audio.count)]
            let bufferDuration = Double(buffer.count) / sampleRate
            elapsedAudio += bufferDuration
            // Pace like a live microphone so chunk decodes overlap "speaking".
            let wait = replayStart.addingTimeInterval(elapsedAudio).timeIntervalSinceNow
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }

            pending.append(contentsOf: buffer)
            if let stats = segmenter.process(rms: SpeechEnergy.rms(buffer), duration: bufferDuration) {
                try emitChunk(stats: stats)
            }
        }

        // "Release": close the final chunk and finish.
        let releaseStart = Date()
        try emitChunk(stats: segmenter.finishChunk(), isFinal: true)
        let incrementalText = await manager.finishIncrementalTranscription(
            session, summary: RecordedChunkSummary(chunkCount: chunkIndex, hasGaps: false),
            language: "pt")
        let incrementalSeconds = Date().timeIntervalSince(releaseStart)

        let fullWER = WordErrorRate.compute(reference: reference, hypothesis: fullText).rate
        let incWER = WordErrorRate.compute(reference: reference, hypothesis: incrementalText ?? "").rate
        var lines: [String] = []
        lines.append(String(format: "== %@ (%.2f s of audio) ==", name, Double(audio.count) / sampleRate))
        lines.append(String(format: "  Full file (trim + finalize): release wait %.2f s, WER %.1f%%",
                            fullSeconds, fullWER * 100))
        lines.append("    \(fullText)")
        lines.append(String(format: "  Incremental:                 release wait %.2f s, WER %.1f%%, %d decodes",
                            incrementalSeconds, incWER * 100, session.decodeCount))
        lines.append("    \(incrementalText ?? "<fell back to full file>")")
        lines.append("  Chunks:")
        lines += boundaries
        lines.append("  Decodes (raw, in order; merged backlog counts as one):")
        lines += decodeLog
        return ScenarioResult(
            lines: lines, fullWER: fullWER, incrementalWER: incWER, fellBack: incrementalText == nil)
    }

    private func trimmingLines(
        label: String, url: URL, transcribe: (URL) async throws -> String
    ) async throws -> [String] {
        var start = Date()
        let untrimmed = try await transcribe(url)
        let untrimmedSeconds = Date().timeIntervalSince(start)

        start = Date()
        var input = url
        if case .trimmed(let trimmed) = AudioTrimmer.trimSilence(in: url) { input = trimmed }
        defer { if input != url { try? FileManager.default.removeItem(at: input) } }
        let trimmed = try await transcribe(input)
        let trimmedSeconds = Date().timeIntervalSince(start)
        return [
            String(format: "  %@: untrimmed %.2f s, trimmed %.2f s (incl. trim), same text: %@",
                   label, untrimmedSeconds, trimmedSeconds, untrimmed == trimmed ? "yes" : "no"),
            "    untrimmed: \(untrimmed)",
            "    trimmed:   \(trimmed)",
        ]
    }

    /// 1 s of room noise before, between and after the clips.
    private func compose(_ parts: [(samples: [Float], text: String)]) -> [Float] {
        var audio = roomNoise(seconds: 1, seed: 1)
        for (offset, part) in parts.enumerated() {
            audio += part.samples
            audio += roomNoise(seconds: 1, seed: UInt32(offset + 2))
        }
        return audio
    }

    // MARK: - Helpers

    private func waitForBackgroundWarmUp(_ manager: TranscriptionManager) async throws {
        let deadline = Date().addingTimeInterval(15 * 60)
        while manager.isWarmingUp || manager.isLoading, Date() < deadline {
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func readSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.processingFormat.sampleRate, sampleRate, "\(url.lastPathComponent) must be 16 kHz")
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    /// Deterministic low-level noise (≈ -66 dBFS) standing in for a quiet room.
    private func roomNoise(seconds: Double, seed: UInt32) -> [Float] {
        var state = seed &* 2_654_435_761
        return (0..<Int(seconds * sampleRate)).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return (Float(state >> 8) / Float(1 << 24) - 0.5) * 0.0017
        }
    }

    private func writeWAV(_ samples: [Float], name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stream-\(name)-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(max(1, samples.count))))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer {
            if let base = $0.baseAddress { buffer.floatChannelData![0].update(from: base, count: samples.count) }
        }
        try file.write(from: buffer)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
