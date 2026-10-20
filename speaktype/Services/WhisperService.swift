import CoreML
import Foundation
import Tokenizers
import WhisperKit

@Observable
class WhisperService {
    // Shared singleton instance - use this everywhere
    static let shared = WhisperService()
    private static let placeholderPatterns = [
        #"\[(?:BLANK_AUDIO|SILENCE)\]"#,
        #"<\|nospeech\|>"#,
        #"\[\s*S\s*\]"#,
    ]
    private static let noiseLabelTerms = [
        "applause",
        "background noise",
        "blank audio",
        "breathing",
        "cough",
        "coughing",
        "exhale",
        "heartbeat",
        "indistinct",
        "inaudible",
        "inhale",
        "laughing",
        "laughter",
        "loud noise",
        "muffled speech",
        "music",
        "noise",
        "silence",
        "sigh",
        "sighs",
        "sniffing",
        "static",
        "unclear speech",
        "unintelligible",
        "wind",
        "wind blowing",
        "wind noise",
    ]
    private static let bracketedNoisePattern: String = {
        let escaped = noiseLabelTerms.map(NSRegularExpression.escapedPattern(for:)).joined(
            separator: "|")
        return #"[\[\(]\s*(?:"# + escaped + #")\s*[\]\)]"#
    }()

    var pipe: WhisperKit?
    var isInitialized = false
    var isTranscribing = false
    var isLoading = false
    var loadingStage: String = ""  // Descriptive stage for UI
    var loadingModelVariant: String = ""
    var loadingStartedAt: Date?

    var currentModelVariant: String = ""  // No default - must be explicitly set
    private var lastLoadDuration: TimeInterval?

    @MainActor private var activeLoadTask: Task<Void, Error>?
    @MainActor private var activeLoadVariant: String = ""
    @MainActor private var activeLoadToken: UUID?

    /// Device RAM in GB (cached on init)
    static let deviceRAMGB: Int = {
        Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
    }()

    enum TranscriptionError: Error, LocalizedError {
        case notInitialized
        case fileNotFound
        case alreadyLoading
        case loadingTimeout

        var errorDescription: String? {
            switch self {
            case .notInitialized: return "Model is not initialized"
            case .fileNotFound: return "Audio file not found"
            case .alreadyLoading: return "Model loading already in progress"
            case .loadingTimeout:
                return "Model loading timed out — your Mac may not have enough RAM for this model"
            }
        }
    }

    // Init is internal to allow testing, but prefer using .shared in production
    init() {}

    // Default initialization (loads default or saved model)
    @MainActor
    func initialize() async throws {
        try await loadModel(variant: currentModelVariant)
    }

    // Dynamic model loading with optimized WhisperKitConfig
    @MainActor
    func loadModel(variant: String) async throws {
        // Already loaded this exact model
        if isInitialized && variant == currentModelVariant && pipe != nil {
            print("✅ Model \(variant) already loaded, skipping")
            return
        }

        if let activeLoadTask {
            let inFlightVariant = activeLoadVariant

            if inFlightVariant == variant {
                loadingStage = "Model is still warming up..."
                print("⏳ Model \(variant) load already in progress, waiting for completion")
                try await activeLoadTask.value
                return
            }

            loadingStage = "Finishing current model load..."
            print("⏳ Waiting for current model load (\(inFlightVariant)) to finish before loading \(variant)")
            do {
                try await activeLoadTask.value
            } catch {
                // If another model failed to warm up, still try the model the caller asked for.
                print(
                    "⚠️ In-flight model load (\(inFlightVariant)) failed while waiting: \(error.localizedDescription). Continuing with \(variant)."
                )
            }

            if isInitialized && variant == currentModelVariant && pipe != nil {
                print("✅ Model \(variant) became ready while waiting, skipping duplicate load")
                return
            }
        }

        let token = UUID()
        let task = Task { @MainActor in
            try await self.performModelLoad(variant: variant)
        }
        activeLoadTask = task
        activeLoadVariant = variant
        activeLoadToken = token

        defer {
            if activeLoadToken == token {
                activeLoadTask = nil
                activeLoadVariant = ""
                activeLoadToken = nil
            }
        }

        try await task.value
    }

    @MainActor
    private func performModelLoad(variant: String) async throws {
        let ramGB = Self.deviceRAMGB
        print("🔄 Initializing WhisperKit with model: \(variant)...")
        print("💻 Device RAM: \(ramGB) GB")

        if let model = AIModel.availableModels.first(where: { $0.variant == variant }),
            ramGB < model.minimumRAMGB
        {
            print(
                "⚠️ WARNING: Model \(variant) recommends \(model.minimumRAMGB)GB+ RAM, device has \(ramGB)GB. Loading may fail or be very slow."
            )
        }

        isLoading = true
        isInitialized = false
        loadingModelVariant = variant
        loadingStartedAt = Date()
        loadingStage = "Preparing \(modelDisplayName(for: variant))..."

        // Release existing model to free memory
        if pipe != nil {
            loadingStage = "Switching models and freeing memory..."
            print("🗑️ Releasing previous model from memory...")
            pipe = nil
        }

        do {
            // Prefer the current Application Support location; fall back to the legacy
            // Documents location so users who downloaded before the move keep working.
            let newModelFolder = ModelStorage.whisperKitModelsDir
                .appendingPathComponent(variant)
            var modelFolder = newModelFolder
            if !FileManager.default.fileExists(atPath: newModelFolder.path),
                let legacyFolder = ModelStorage.legacyModelsDir?.appendingPathComponent(variant),
                FileManager.default.fileExists(atPath: legacyFolder.path)
            {
                modelFolder = legacyFolder
            }

            // Use WhisperKitConfig with optimized settings.
            // `downloadBase` keeps any tokenizer configs WhisperKit fetches out of
            // ~/Documents (the root cause of model-load failures on macOS 15, #38).
            let config = WhisperKitConfig(
                model: variant,
                downloadBase: ModelStorage.whisperKitBase,
                modelFolder: modelFolder.path,
                computeOptions: Self.computeOptions(
                    hasNeuralEngine: DeviceCapability.current.hasNeuralEngine),
                verbose: false,
                logLevel: .error,
                prewarm: true,  // Built-in model specialization (replaces manual warmup)
                load: true,
                download: false  // Already downloaded via ModelDownloadService
            )

            loadingStage = "Loading model into memory..."

            // Start a watchdog timer that will flag a timeout
            let loadStart = Date()

            pipe = try await WhisperKit(config)

            let loadDuration = Date().timeIntervalSince(loadStart)
            lastLoadDuration = loadDuration
            print("⏱️ Model loaded in \(String(format: "%.1f", loadDuration))s")

            currentModelVariant = variant
            isInitialized = true
            isLoading = false
            loadingStage = ""
            loadingModelVariant = ""
            loadingStartedAt = nil
            print("✅ WhisperKit initialized and prewarmed with \(variant)")
        } catch {
            isLoading = false
            loadingStage = ""
            loadingModelVariant = ""
            loadingStartedAt = nil
            print(
                "❌ Failed to initialize WhisperKit with \(variant): \(error.localizedDescription)")
            throw error
        }
    }

    /// Explicit CoreML placement. On Apple Silicon this mirrors WhisperKit 0.9's own
    /// macOS 14+ defaults (mel on GPU, encoder + decoder on the Neural Engine, the tiny
    /// prefill lookup on CPU) so behavior is pinned even if upstream defaults change.
    /// Intel Macs have no ANE, where `.cpuAndNeuralEngine` silently degrades to CPU-only,
    /// so the heavy models go to the GPU instead.
    static func computeOptions(hasNeuralEngine: Bool) -> ModelComputeOptions {
        let heavyUnits: MLComputeUnits = hasNeuralEngine ? .cpuAndNeuralEngine : .cpuAndGPU
        return ModelComputeOptions(
            melCompute: .cpuAndGPU,
            audioEncoderCompute: heavyUnits,
            textDecoderCompute: heavyUnits,
            prefillCompute: .cpuOnly
        )
    }

    private func modelDisplayName(for variant: String) -> String {
        AIModel.availableModels.first(where: { $0.variant == variant })?.name ?? variant
    }

    func transcribe(audioFile: URL, language: String = "auto") async throws -> String {
        guard let pipe = pipe, isInitialized else {
            throw TranscriptionError.notInitialized
        }

        guard FileManager.default.fileExists(atPath: audioFile.path) else {
            throw TranscriptionError.fileNotFound
        }

        isTranscribing = true
        defer { isTranscribing = false }

        print("Starting transcription for: \(audioFile.lastPathComponent)")

        do {
            let text = try await decode(audioPath: audioFile.path, language: language, pipe: pipe)

            print("Transcription complete: \(text.prefix(50))...")
            return text
        } catch {
            print("Transcription failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Transcribe a background audio chunk without affecting the global `isTranscribing` flag.
    /// Chunk files are automatically deleted after transcription.
    func transcribeChunk(audioFile: URL, language: String = "auto") async throws -> String {
        guard let pipe = pipe, isInitialized else {
            throw TranscriptionError.notInitialized
        }

        guard FileManager.default.fileExists(atPath: audioFile.path) else {
            // Chunk file may have been cleaned up already - return empty gracefully
            return ""
        }

        print("🔪 Chunk transcription started: \(audioFile.lastPathComponent)")

        let text = try await decode(audioPath: audioFile.path, language: language, pipe: pipe)

        print("🔪 Chunk done: \(text.prefix(40))...")
        // Clean up temp chunk file after transcription
        try? FileManager.default.removeItem(at: audioFile)
        return text
    }

    /// Runs one decode with the vocabulary prompt. A prompt can make Whisper
    /// decide the audio is already transcribed and stop immediately, so an
    /// empty prompted result is retried once without conditioning.
    private func decode(audioPath: String, language: String, pipe: WhisperKit) async throws -> String {
        let prompt = conditioningPrompt(for: language, pipe: pipe)
        let results = try await pipe.transcribe(
            audioPath: audioPath,
            decodeOptions: decodingOptions(for: language, promptTokens: prompt?.tokens)
        )
        let text = Self.strippingPromptEcho(
            from: Self.normalizedTranscription(from: results.map { $0.text }.joined(separator: " ")),
            prompt: prompt?.text)
        guard text.isEmpty, prompt != nil else { return text }

        print("⚠️ Prompted decode was empty; retrying without vocabulary prompt")
        let retry = try await pipe.transcribe(
            audioPath: audioPath,
            decodeOptions: decodingOptions(for: language, promptTokens: nil)
        )
        return Self.normalizedTranscription(from: retry.map { $0.text }.joined(separator: " "))
    }

    private func decodingOptions(for language: String, promptTokens: [Int]?) -> DecodingOptions {
        Self.decodingOptions(
            for: language,
            promptTokens: promptTokens,
            hasNeuralEngine: DeviceCapability.current.hasNeuralEngine
        )
    }

    /// Decoding settings shared by full-file and chunk transcription. Temperature
    /// fallback and the quality thresholds keep WhisperKit's defaults.
    static func decodingOptions(
        for language: String,
        promptTokens: [Int]? = nil,
        hasNeuralEngine: Bool = true
    ) -> DecodingOptions {
        var options = DecodingOptions()
        options.task = .transcribe
        options.language = (language == "auto") ? nil : language
        // With the prefill prompt on, WhisperKit forces `<|en|>` when no language is
        // set unless detection is requested explicitly, so "auto" must ask for it.
        options.usePrefillPrompt = true
        options.detectLanguage = options.language == nil
        // The app only consumes plain text, so skip timestamp tokens entirely.
        options.withoutTimestamps = true
        options.skipSpecialTokens = true
        // Audio longer than one 30 s window is split at silences and the chunks are
        // decoded in parallel instead of sequentially seeking through the file.
        options.chunkingStrategy = .vad
        options.concurrentWorkerCount = hasNeuralEngine ? 4 : 2
        options.promptTokens = (promptTokens?.isEmpty ?? true) ? nil : promptTokens
        return options
    }

    // MARK: - Vocabulary prompt

    /// Upper bound for conditioning tokens. Whisper accepts up to ~223, but every
    /// prompt token is force-decoded once per 30 s window (and disables the prefill
    /// KV cache), so a short prompt keeps latency low.
    static let maxPromptTokens = 96

    /// Text used to condition Whisper: the user's dictionary terms, biasing it
    /// toward their spellings. Nil means "no prompt". A full-sentence preamble
    /// was tried for Portuguese and made large-v3-turbo emit nothing (it reads
    /// the prompt as an already-finished transcript), so only the list is sent.
    static func promptText(language: String, vocabulary: [String]) -> String? {
        let terms = vocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        let termList = terms.joined(separator: ", ") + "."
        return language.lowercased().hasPrefix("pt") ? "Termos: " + termList : termList
    }

    /// Builds the prompt text and its tokens for the loaded model, dropping
    /// dictionary terms from the end until the prompt fits `maxPromptTokens`.
    private func conditioningPrompt(for language: String, pipe: WhisperKit) -> (
        text: String, tokens: [Int]
    )? {
        guard let tokenizer = pipe.tokenizer else { return nil }
        var vocabulary = DictionaryService.vocabularyHints()

        while let text = Self.promptText(language: language, vocabulary: vocabulary) {
            // A leading space matches how Whisper tokenizes running text (as in
            // WhisperKit's own CLI); special tokens must never reach the prompt.
            let tokens = tokenizer.encode(text: " " + text)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            if tokens.count <= Self.maxPromptTokens {
                return tokens.isEmpty ? nil : (text, tokens)
            }
            guard !vocabulary.isEmpty else { return nil }
            vocabulary.removeLast()
        }
        return nil
    }

    /// On silence Whisper can repeat its conditioning prompt verbatim. Removes an
    /// output that equals the prompt (or one of its trailing sentences, e.g. just
    /// the "Termos: …" list) or that starts with the whole prompt.
    static func strippingPromptEcho(from text: String, prompt: String?) -> String {
        guard let prompt, !text.isEmpty else { return text }
        let promptSentences = sentences(in: prompt)
        let textKey = comparisonKey(text)

        for start in promptSentences.indices {
            let candidate = promptSentences[start...].joined(separator: " ")
            if comparisonKey(candidate) == textKey { return "" }
        }

        if let range = text.range(
            of: prompt, options: [.anchored, .caseInsensitive, .diacriticInsensitive])
        {
            return String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    // MARK: - Hallucination filter

    /// Sentences Whisper invents on silence because its training data is full of
    /// subtitled videos. Keys are compared after `comparisonKey` folding.
    private static let outroOnlyPhrases: Set<String> = [
        "obrigado por assistir", "obrigada por assistir", "obrigado por assistirem",
        "obrigada por assistirem", "obrigado por assistir ao video",
        "obrigada por assistir ao video", "muito obrigado por assistir",
        "muito obrigada por assistir", "tchau tchau", "tchau tchau tchau",
        "ate a proxima", "ate o proximo video",
        "gracias por ver", "gracias por ver el video", "muchas gracias por ver",
        "hasta la proxima", "thanks for watching", "thank you for watching",
        "thank you so much for watching",
    ]

    /// YouTube-style calls to action that nobody dictates as a final sentence.
    /// Removed even after real text, and also as the whole transcript.
    private static let trailingYouTubePhrases: Set<String> = [
        "inscreva se no canal", "se inscreva no canal", "inscrevam se no canal",
        "se inscrevam no canal", "inscreva se no meu canal", "se inscreva no meu canal",
        "nao se esqueca de se inscrever", "nao se esqueca de se inscrever no canal",
        "nao esqueca de se inscrever", "nao esqueca de se inscrever no canal",
        "deixe seu like", "deixe o seu like", "deixe seu like e se inscreva no canal",
        "ativa o sininho", "ative o sininho", "suscribete al canal",
        "no olvides suscribirte", "subscribe to my channel", "please subscribe",
        "like and subscribe", "don t forget to subscribe",
    ]

    /// Subtitle-credit lines ("Legendas pela comunidade Amara.org"). These are
    /// never real dictation, so they are dropped wherever they appear.
    private static let subtitleCreditPatterns = [
        #"\bamara org\b"#,
        #"^(?:legendas?|legendado|subtitulos?|subtitulado|subtitles?|captions?)\b.*\b(?:comunidade|comunidad|community)\b"#,
        #"^subtitulos? (?:realizados?|hechos?|creados?) por\b"#,
    ]

    /// Credit lines that are only removed at the end ("Legenda: Fulano"), since
    /// "legenda" is also an ordinary word mid-text.
    private static let trailingCreditPattern =
        #"^(?:legendas?|legendado|subtitulos?|subtitles?|traducao e legendas?)\s*(?::|por\b|pela\b|pelo\b|by\b)"#

    static func removingHallucinatedPhrases(from text: String) -> String {
        var kept = sentences(in: text).filter { sentence in
            let key = comparisonKey(sentence)
            return !subtitleCreditPatterns.contains {
                key.range(of: $0, options: .regularExpression) != nil
            }
        }

        while let last = kept.last, isTrailingHallucination(last) {
            kept.removeLast()
        }

        if !kept.isEmpty, kept.allSatisfy({ outroOnlyPhrases.contains(comparisonKey($0)) }) {
            kept.removeAll()
        }
        return kept.joined(separator: " ")
    }

    private static func isTrailingHallucination(_ sentence: String) -> Bool {
        if trailingYouTubePhrases.contains(comparisonKey(sentence)) { return true }
        // Match the credit on the folded text, but keep ":" so "Legenda:" is detectable.
        let folded = sentence.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: nil
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return folded.range(of: trailingCreditPattern, options: .regularExpression) != nil
    }

    /// Splits on sentence-ending punctuation followed by whitespace or the end, so
    /// "Amara.org" stays inside its sentence.
    private static func sentences(in text: String) -> [String] {
        let pattern = #"\S.*?(?:[.!?…]+(?=\s|$)|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        else { return [text] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map {
                String(text[$0]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }.filter { !$0.isEmpty }
    }

    /// Case-, diacritic- and punctuation-insensitive form used for phrase matching.
    private static func comparisonKey(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func normalizedTranscription(from rawText: String) -> String {
        var normalized = rawText

        for pattern in placeholderPatterns {
            normalized = normalized.replacingOccurrences(
                of: pattern,
                with: " ",
                options: .regularExpression
            )
        }

        normalized = normalized.replacingOccurrences(
            of: bracketedNoisePattern,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )

        normalized = normalized.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )

        return removingHallucinatedPhrases(
            from: normalized.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
