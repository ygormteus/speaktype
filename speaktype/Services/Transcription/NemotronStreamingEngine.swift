import AVFoundation
import FluidAudio
import Foundation

/// Streaming Portuguese dictation powered by Nemotron Multilingual.
/// Every tier uses FluidAudio's local Core ML assets. A longer audio window
/// gives the decoder more context before emitting words, trading a little
/// immediacy for better recognition on longer Portuguese phrases.
enum NemotronCatalog {
    static let fastVariant = "nemotron-multilingual-pt-br-560ms"
    static let balancedVariant = "nemotron-multilingual-pt-br-1120ms"
    static let qualityVariant = "nemotron-multilingual-pt-br-2240ms"
    /// Kept as an alias so a persisted selection from earlier builds continues
    /// to resolve to the fast profile.
    static let portugueseVariant = fastVariant
    static let variants = [fastVariant, balancedVariant, qualityVariant]
    static let languageCode = "pt-BR"

    /// Maps the app's language setting to a Nemotron prompt code.
    ///
    /// The model's `metadata.json` `prompt_dictionary` maps the bare code
    /// `"pt"` to the *European* Portuguese prompt (`pt: 13 == pt-PT`, while
    /// `pt-BR: 12`), and the app stores the spoken language as bare `"pt"`.
    /// Passing it through unchanged silently dictated with the pt-PT prompt.
    /// Only an explicit regional code (e.g. `"pt-PT"`) is honoured; anything
    /// else — `"auto"`, `"pt"`, empty — resolves to Brazilian Portuguese.
    static func promptLanguage(for language: String) -> String {
        let normalized = language.replacingOccurrences(of: "_", with: "-")
        let parts = normalized.split(separator: "-", maxSplits: 1).map(String.init)
        if parts.count == 2, parts[0].lowercased() == "pt", !parts[1].isEmpty {
            return "pt-" + parts[1].uppercased()
        }
        return languageCode
    }

    /// Audio samples FluidAudio consumes per encoder step for `variant`
    /// (16 kHz mono). `StreamingNemotronMultilingualAsrManager.process(samples:)`
    /// buffers internally and only runs whole chunks of this size, so callers
    /// may push any size; pushing a divisor of this keeps chunk boundaries
    /// aligned with pushes (no added latency).
    static func chunkSamples(for variant: String) -> Int? {
        chunkMilliseconds(for: variant).map { $0 * 16 }
    }

    static func chunkMilliseconds(for variant: String) -> Int? {
        switch variant {
        case fastVariant: return 560
        case balancedVariant: return 1_120
        case qualityVariant: return 2_240
        default: return nil
        }
    }

    static func cacheDirectory(for variant: String) -> URL? {
        guard let chunkMilliseconds = chunkMilliseconds(for: variant) else { return nil }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return appSupport
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
            .appendingPathComponent("Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML", isDirectory: true)
            .appendingPathComponent("latin/\(chunkMilliseconds)ms", isDirectory: true)
    }

    static func isDownloaded(_ variant: String) -> Bool {
        guard let cacheDirectory = cacheDirectory(for: variant) else { return false }
        return FileManager.default.fileExists(
            atPath: cacheDirectory.appendingPathComponent("metadata.json").path
        )
    }
}

@Observable
final class NemotronStreamingEngine: SpeechToTextEngine {
    static let shared = NemotronStreamingEngine()

    var isInitialized = false
    var isLoading = false
    var isTranscribing = false
    var loadingStage = ""
    var currentModelVariant = ""
    private(set) var partialTranscript = ""
    private(set) var processingDuration: TimeInterval = 0

    private var manager: StreamingNemotronMultilingualAsrManager?

    private init() {}

    var deliveryMode: TranscriptionDeliveryMode { .incremental }

    func loadModel(variant: String) async throws {
        guard let chunkMilliseconds = NemotronCatalog.chunkMilliseconds(for: variant) else {
            throw ASRError.processingFailed("Unsupported Nemotron model: \(variant)")
        }
        if isInitialized, currentModelVariant == variant, manager != nil { return }

        isLoading = true
        isInitialized = false
        loadingStage = "Preparing live Portuguese model…"
        defer { isLoading = false }

        let shared = try await StreamingNemotronMultilingualAsrManager.downloadAndPreloadShared(
            languageCode: NemotronCatalog.languageCode,
            chunkMs: chunkMilliseconds
        )
        loadingStage = "Loading live Portuguese model…"
        let manager = StreamingNemotronMultilingualAsrManager()
        try await manager.loadFromShared(shared)
        await manager.setLanguage(NemotronCatalog.languageCode)

        self.manager = manager
        currentModelVariant = variant
        isInitialized = true
        loadingStage = ""
    }

    func begin(language: String) async throws {
        guard let manager else { throw ASRError.notInitialized }
        partialTranscript = ""
        processingDuration = 0
        await manager.reset()
        await manager.setLanguage(NemotronCatalog.promptLanguage(for: language))
    }

    func append(audioFile: URL) async throws {
        guard let manager else { throw ASRError.notInitialized }
        let file = try AVAudioFile(forReading: audioFile)
        let frames = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)
        else { throw ASRError.processingFailed("Unable to read audio chunk") }
        try file.read(into: buffer)
        let startedAt = Date()
        _ = try await manager.process(audioBuffer: buffer)
        processingDuration += Date().timeIntervalSince(startedAt)
        partialTranscript = await manager.getPartialTranscript()
    }

    func append(samples: [Float]) async throws {
        guard let manager else { throw ASRError.notInitialized }
        guard !samples.isEmpty else { return }
        let startedAt = Date()
        _ = try await manager.process(samples: samples)
        processingDuration += Date().timeIntervalSince(startedAt)
        partialTranscript = await manager.getPartialTranscript()
    }

    func finish() async throws -> String {
        guard let manager else { throw ASRError.notInitialized }
        isTranscribing = true
        defer { isTranscribing = false }
        let startedAt = Date()
        let text = try await manager.finish()
        processingDuration += Date().timeIntervalSince(startedAt)
        partialTranscript = text
        return text
    }

    func transcribe(audioFile: URL, language: String) async throws -> String {
        try await begin(language: language)
        try await append(audioFile: audioFile)
        return try await finish()
    }
}
