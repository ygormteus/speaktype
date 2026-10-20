import AVFoundation
import XCTest
@testable import speaktype

/// Opt-in PT-BR accuracy/latency benchmark. Skipped unless
/// `SPEAKTYPE_BENCH_DIR` points at a folder of `name.wav|m4a` + `name.txt`
/// pairs. Run via `scripts/benchmark-ptbr.sh`; see docs/BENCHMARK.md.
///
/// Env:
/// - `SPEAKTYPE_BENCH_DIR`     (required) clip folder
/// - `SPEAKTYPE_BENCH_MODELS`  (optional) comma-separated variants to run
/// - `SPEAKTYPE_BENCH_OUT`     (optional) output .md path
@MainActor
final class PTBRBenchmarkTests: XCTestCase {

    private struct Clip {
        let name: String
        let audio: URL
        let reference: String
        let duration: TimeInterval
    }

    private struct ClipResult {
        let clip: Clip
        let hypothesis: String
        let seconds: TimeInterval
        let strict: WordErrorRate.Result
        let folded: WordErrorRate.Result
        var rtf: Double { clip.duration > 0 ? seconds / clip.duration : 0 }
    }

    private struct ModelResult {
        let variant: String
        let name: String
        let loadSeconds: TimeInterval?
        let clips: [ClipResult]
        let error: String?

        private func pooled(_ pick: (ClipResult) -> WordErrorRate.Result) -> Double {
            let errors = clips.map { pick($0).errors }.reduce(0, +)
            let words = clips.map { pick($0).referenceWords }.reduce(0, +)
            return words > 0 ? Double(errors) / Double(words) : 0
        }
        var wer: Double { pooled(\.strict) }
        var foldedWER: Double { pooled(\.folded) }
        var totalAudio: TimeInterval { clips.map(\.clip.duration).reduce(0, +) }
        var totalProcessing: TimeInterval { clips.map(\.seconds).reduce(0, +) }
        var rtf: Double { totalAudio > 0 ? totalProcessing / totalAudio : 0 }
        func rtf(where predicate: (Clip) -> Bool) -> Double? {
            let subset = clips.filter { predicate($0.clip) }
            let audio = subset.map(\.clip.duration).reduce(0, +)
            guard audio > 0 else { return nil }
            return subset.map(\.seconds).reduce(0, +) / audio
        }
    }

    private static let audioExtensions = ["wav", "m4a", "mp3", "caf", "aiff", "flac"]
    private static let shortClipLimit: TimeInterval = 15

    func testPortugueseBenchmark() async throws {
        let env = ProcessInfo.processInfo.environment
        let repetitions = min(5, max(1, Int(env["SPEAKTYPE_BENCH_REPETITIONS"] ?? "") ?? 1))
        guard let dirPath = env["SPEAKTYPE_BENCH_DIR"], !dirPath.isEmpty else {
            throw XCTSkip("Set SPEAKTYPE_BENCH_DIR to run the PT-BR benchmark")
        }
        let directory = URL(fileURLWithPath: (dirPath as NSString).expandingTildeInPath)
        let clips = try loadClips(in: directory)
        guard !clips.isEmpty else {
            throw XCTSkip("SPEAKTYPE_BENCH_DIR has no audio+txt pairs: \(directory.path)")
        }

        let downloads = ModelDownloadService.shared
        await downloads.refreshDownloadedModels()

        let requested = env["SPEAKTYPE_BENCH_MODELS"]
            .map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            .map { Set($0.filter { !$0.isEmpty }) }
            .flatMap { $0.isEmpty ? nil : $0 }

        var candidates = AIModel.availableModels.filter { $0.supports(spokenLanguage: "pt") }
        if let requested {
            let unknown = requested.subtracting(candidates.map(\.variant))
            if !unknown.isEmpty {
                print("⚠️ Ignoring unknown / non-PT variants: \(unknown.sorted().joined(separator: ", "))")
            }
            candidates = candidates.filter { requested.contains($0.variant) }
        }
        let models = candidates.filter { downloads.isDownloaded($0.variant) }
        let notDownloaded = candidates.filter { !downloads.isDownloaded($0.variant) }.map(\.variant)
        if !notDownloaded.isEmpty {
            print("ℹ️ Skipping models not downloaded: \(notDownloaded.joined(separator: ", "))")
        }
        guard !models.isEmpty else {
            throw XCTSkip("No downloaded PT-capable models match the selection")
        }

        let manager = TranscriptionManager.shared
        // The test host is the full app: its dashboard warms up the user's
        // selected model on launch. Let that finish so it neither competes
        // for the ANE nor swaps the loaded model mid-benchmark.
        try await waitForBackgroundWarmUp(manager)

        var results: [ModelResult] = []
        for model in models {
            print("▶︎ Benchmarking \(model.variant) on \(clips.count) clips…")
            try await waitForBackgroundWarmUp(manager)
            let preloaded = manager.isInitialized && manager.currentModelVariant == model.variant
            let loadStart = Date()
            do {
                try await manager.loadModel(variant: model.variant)
            } catch {
                results.append(ModelResult(
                    variant: model.variant, name: model.name, loadSeconds: nil, clips: [],
                    error: "load failed: \(error.localizedDescription)"))
                continue
            }
            // nil = the app had already loaded it, so no cold-load time exists.
            let loadSeconds: TimeInterval? = preloaded ? nil : Date().timeIntervalSince(loadStart)

            // Untimed warm-up on the shortest clip: the first inference pays
            // one-off Core ML / ANE specialization that real dictation doesn't
            // repeat once the model is resident.
            if let warm = clips.min(by: { $0.duration < $1.duration }) {
                _ = try? await manager.transcribe(audioFile: warm.audio, language: "pt")
            }

            var clipResults: [ClipResult] = []
            var failure: String?
            for clip in (0..<repetitions).flatMap({ _ in clips }) {
                let start = Date()
                do {
                    let text = try await manager.transcribe(audioFile: clip.audio, language: "pt")
                    let seconds = Date().timeIntervalSince(start)
                    clipResults.append(ClipResult(
                        clip: clip, hypothesis: text, seconds: seconds,
                        strict: WordErrorRate.compute(reference: clip.reference, hypothesis: text),
                        folded: WordErrorRate.compute(
                            reference: clip.reference, hypothesis: text, foldingDiacritics: true)))
                } catch {
                    failure = "\(clip.name): \(error.localizedDescription)"
                    print("⚠️ \(model.variant) failed on \(failure!)")
                }
            }
            results.append(ModelResult(
                variant: model.variant, name: model.name, loadSeconds: loadSeconds,
                clips: clipResults, error: failure))
        }

        let report = "Repetições por áudio e modelo: \(repetitions)\n\n" + makeReport(
            results: results, clips: clips, directory: directory, notDownloaded: notDownloaded)
        print("\n" + report)
        let outURL = try outputURL(env: env)
        try FileManager.default.createDirectory(
            at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try report.write(to: outURL, atomically: true, encoding: .utf8)
        print("📝 Benchmark written to \(outURL.path)")
    }

    // MARK: - Helpers

    private func waitForBackgroundWarmUp(_ manager: TranscriptionManager) async throws {
        let deadline = Date().addingTimeInterval(15 * 60)
        while manager.isWarmingUp || manager.isLoading, Date() < deadline {
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func loadClips(in directory: URL) throws -> [Clip] {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var clips: [Clip] = []
        for audio in files where Self.audioExtensions.contains(audio.pathExtension.lowercased()) {
            let base = audio.deletingPathExtension()
            let txt = base.appendingPathExtension("txt")
            guard FileManager.default.fileExists(atPath: txt.path) else {
                print("⚠️ No transcript for \(audio.lastPathComponent), skipping")
                continue
            }
            let reference = try String(contentsOf: txt, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let file = try AVAudioFile(forReading: audio)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            clips.append(Clip(
                name: base.lastPathComponent, audio: audio, reference: reference, duration: duration))
        }
        return clips.sorted { $0.name < $1.name }
    }

    private func outputURL(env: [String: String]) throws -> URL {
        if let custom = env["SPEAKTYPE_BENCH_OUT"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        // <repo>/speaktypeTests/PTBRBenchmarkTests.swift -> <repo>/build
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return repo.appendingPathComponent("build", isDirectory: true)
            .appendingPathComponent("benchmark-ptbr-\(formatter.string(from: Date())).md")
    }

    private func pct(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }
    private func num(_ value: Double, _ digits: Int = 2) -> String {
        String(format: "%.\(digits)f", value)
    }
    private func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }

    private func makeReport(
        results: [ModelResult], clips: [Clip], directory: URL, notDownloaded: [String]
    ) -> String {
        let totalAudio = clips.map(\.duration).reduce(0, +)
        let shortCount = clips.filter { $0.duration < Self.shortClipLimit }.count
        var lines: [String] = []
        lines.append("# PT-BR benchmark — \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")
        lines.append(
            "Clips: \(clips.count) (\(shortCount) curtos < \(Int(Self.shortClipLimit)) s, "
                + "\(clips.count - shortCount) longos), áudio total \(num(totalAudio, 1)) s — `\(directory.path)`")
        lines.append("")
        lines.append("WER = erros de palavra / palavras de referência (texto em minúsculas, sem pontuação). "
            + "\"WER s/ acento\" ignora diacríticos. RTF = tempo de processamento / duração do áudio (menor é melhor).")
        lines.append("")
        if !notDownloaded.isEmpty {
            lines.append("Não baixados (pulados): " + notDownloaded.map { "`\($0)`" }.joined(separator: ", "))
            lines.append("")
        }
        lines.append("| Modelo | Variante | Carga (s) | WER | WER s/ acento | RTF total | RTF curtos | RTF longos | Erros |")
        lines.append("|---|---|---:|---:|---:|---:|---:|---:|---|")
        for r in results.sorted(by: { $0.wer < $1.wer }) {
            let short = r.rtf { $0.duration < Self.shortClipLimit }.map { num($0, 3) } ?? "—"
            let long = r.rtf { $0.duration >= Self.shortClipLimit }.map { num($0, 3) } ?? "—"
            let ok = !r.clips.isEmpty
            let empty = r.clips.filter {
                $0.hypothesis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.count
            let problems = [r.error, empty > 0 ? "\(empty) transcrição(ões) vazia(s)" : nil]
                .compactMap { $0 }.joined(separator: "; ")
            lines.append(
                "| \(cell(r.name)) | `\(r.variant)` | \(r.loadSeconds.map { num($0, 1) } ?? "já carregado") | "
                    + "\(ok ? pct(r.wer) : "—") | \(ok ? pct(r.foldedWER) : "—") | "
                    + "\(ok ? num(r.rtf, 3) : "—") | \(short) | \(long) | \(cell(problems)) |")
        }

        for r in results where !r.clips.isEmpty {
            lines.append("")
            lines.append("## \(r.name) (`\(r.variant)`)")
            lines.append("")
            lines.append("| Clip | Dur (s) | Proc (s) | RTF | WER | WER s/ acento | Transcrição |")
            lines.append("|---|---:|---:|---:|---:|---:|---|")
            for c in r.clips {
                lines.append(
                    "| \(cell(c.clip.name)) | \(num(c.clip.duration, 1)) | \(num(c.seconds)) | "
                        + "\(num(c.rtf, 3)) | \(pct(c.strict.rate)) | \(pct(c.folded.rate)) | "
                        + "\(cell(c.hypothesis)) |")
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
