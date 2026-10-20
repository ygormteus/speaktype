import CoreML
import WhisperKit
import XCTest
@testable import speaktype

@MainActor
final class WhisperServiceTests: XCTestCase {
    
    var service: WhisperService?
    
    override func setUpWithError() throws {
        service = WhisperService()
    }

    override func tearDownWithError() throws {
        // Rely on automatic deallocation
    }

    func testDefaultInitialization() {
        guard let service = service else { return XCTFail("Service should be initialized") }
        XCTAssertFalse(service.isInitialized)
        XCTAssertEqual(service.currentModelVariant, "")
    }
    
    // Note: detailed loadModel tests require mocking the WhisperKit dependency
    // which is external. We test the state management around it.
    
    func testStateFlags() {
        guard let service = service else { return XCTFail("Service should be initialized") }
        XCTAssertFalse(service.isTranscribing)
        // Simulate transcription start
        service.isTranscribing = true
        XCTAssertTrue(service.isTranscribing)
    }

    func testNormalizedTranscriptionRemovesBlankAudioPlaceholders() {
        let normalized = WhisperService.normalizedTranscription(
            from: " [BLANK_AUDIO]  hello   <|nospeech|> [SILENCE] "
        )

        XCTAssertEqual(normalized, "hello")
    }

    func testNormalizedTranscriptionRemovesBracketedNoiseLabels() {
        let normalized = WhisperService.normalizedTranscription(
            from: "[wind blowing] (heartbeat) answer [S]"
        )

        XCTAssertEqual(normalized, "answer")
    }

    func testNormalizedTranscriptionRemovesNoiseOnlyArtifacts() {
        let normalized = WhisperService.normalizedTranscription(
            from: "[wind] (Loud noise) (indistinct)"
        )

        XCTAssertEqual(normalized, "")
    }

    // MARK: - Portuguese hallucination filter

    func testSubtitleCreditsAreRemovedAnywhere() {
        XCTAssertEqual(
            WhisperService.normalizedTranscription(from: "Legendas pela comunidade Amara.org"), "")
        XCTAssertEqual(
            WhisperService.normalizedTranscription(
                from: "Subtítulos realizados por la comunidad de Amara.org"), "")
        XCTAssertEqual(
            WhisperService.normalizedTranscription(
                from: "Vamos marcar a reunião. Legendas pela comunidade Amara.org. Até amanhã."),
            "Vamos marcar a reunião. Até amanhã.")
    }

    func testOutroPhrasesAreRemovedOnlyAsWholeTranscript() {
        for phrase in [
            "Obrigado por assistir", "Obrigada por assistir!", "OBRIGADO POR ASSISTIR.",
            "Tchau, tchau.", "Até a próxima.", "Ate a proxima", "Thanks for watching!",
            "Obrigado por assistir! Tchau, tchau.",
        ] {
            XCTAssertEqual(WhisperService.normalizedTranscription(from: phrase), "", phrase)
        }

        // Genuine dictation with the same words survives.
        XCTAssertEqual(WhisperService.normalizedTranscription(from: "Obrigado."), "Obrigado.")
        XCTAssertEqual(
            WhisperService.normalizedTranscription(from: "Obrigado pela ajuda, tchau."),
            "Obrigado pela ajuda, tchau.")
        XCTAssertEqual(
            WhisperService.normalizedTranscription(from: "Enviei o relatório. Até a próxima."),
            "Enviei o relatório. Até a próxima.")
    }

    func testYouTubeCallsToActionAreRemovedAtTheEnd() {
        XCTAssertEqual(
            WhisperService.normalizedTranscription(
                from: "Preciso comprar pão. Inscreva-se no canal!"),
            "Preciso comprar pão.")
        XCTAssertEqual(
            WhisperService.normalizedTranscription(
                from: "Texto real. Não se esqueça de se inscrever. Legenda: Fulano de Tal"),
            "Texto real.")
        XCTAssertEqual(WhisperService.normalizedTranscription(from: "Inscreva-se no canal."), "")
        // Only trailing: the same words mid-text, or "legenda" as a normal word, are kept.
        XCTAssertEqual(
            WhisperService.normalizedTranscription(
                from: "Ele disse inscreva-se no canal ontem. Depois saiu."),
            "Ele disse inscreva-se no canal ontem. Depois saiu.")
        XCTAssertEqual(
            WhisperService.normalizedTranscription(from: "A legenda da foto ficou ótima."),
            "A legenda da foto ficou ótima.")
    }

    // MARK: - Vocabulary prompt

    func testPortuguesePromptIsLabelledTermList() {
        XCTAssertEqual(
            WhisperService.promptText(language: "pt", vocabulary: ["SpeakType", " LGPD "]),
            "Termos: SpeakType, LGPD.")
        // No dictionary terms means no prompt at all, so the prefill cache stays on.
        XCTAssertNil(WhisperService.promptText(language: "pt-BR", vocabulary: []))
    }

    func testNonPortuguesePromptIsOnlyTheTermList() {
        XCTAssertEqual(
            WhisperService.promptText(language: "en", vocabulary: ["FigJam", "Kubernetes"]),
            "FigJam, Kubernetes.")
        XCTAssertNil(WhisperService.promptText(language: "en", vocabulary: []))
        XCTAssertNil(WhisperService.promptText(language: "auto", vocabulary: ["  "]))
    }

    func testPromptEchoIsStripped() {
        let prompt = WhisperService.promptText(language: "pt", vocabulary: ["SpeakType"])!
        XCTAssertEqual(WhisperService.strippingPromptEcho(from: prompt, prompt: prompt), "")
        XCTAssertEqual(
            WhisperService.strippingPromptEcho(from: "termos: speaktype", prompt: prompt), "")
        XCTAssertEqual(
            WhisperService.strippingPromptEcho(from: prompt + " Bom dia.", prompt: prompt),
            "Bom dia.")
        // Real speech that only shares words with the prompt is untouched.
        XCTAssertEqual(
            WhisperService.strippingPromptEcho(from: "Olá! Tudo bem?", prompt: prompt),
            "Olá! Tudo bem?")
        XCTAssertEqual(WhisperService.strippingPromptEcho(from: "SpeakType", prompt: nil), "SpeakType")
    }

    // MARK: - Decoding / compute options

    func testDecodingOptionsForPortuguese() {
        let options = WhisperService.decodingOptions(for: "pt", promptTokens: [1, 2, 3])
        XCTAssertEqual(options.language, "pt")
        XCTAssertTrue(options.withoutTimestamps)
        XCTAssertTrue(options.skipSpecialTokens)
        XCTAssertTrue(options.usePrefillPrompt)
        XCTAssertFalse(options.detectLanguage)
        XCTAssertEqual(options.chunkingStrategy, .vad)
        XCTAssertEqual(options.concurrentWorkerCount, 4)
        XCTAssertEqual(options.promptTokens, [1, 2, 3])
        // Temperature fallback keeps WhisperKit's defaults.
        XCTAssertEqual(options.temperatureFallbackCount, DecodingOptions().temperatureFallbackCount)
        XCTAssertEqual(
            options.temperatureIncrementOnFallback, DecodingOptions().temperatureIncrementOnFallback)
    }

    func testAutoLanguageRequestsDetectionAndEmptyPromptIsDropped() {
        let options = WhisperService.decodingOptions(
            for: "auto", promptTokens: [], hasNeuralEngine: false)
        XCTAssertNil(options.language)
        XCTAssertTrue(options.detectLanguage)
        XCTAssertNil(options.promptTokens)
        XCTAssertEqual(options.concurrentWorkerCount, 2)
    }

    func testComputeOptionsAvoidNeuralEngineOnIntel() {
        let appleSilicon = WhisperService.computeOptions(hasNeuralEngine: true)
        XCTAssertEqual(appleSilicon.melCompute, .cpuAndGPU)
        XCTAssertEqual(appleSilicon.audioEncoderCompute, .cpuAndNeuralEngine)
        XCTAssertEqual(appleSilicon.textDecoderCompute, .cpuAndNeuralEngine)
        XCTAssertEqual(appleSilicon.prefillCompute, .cpuOnly)

        let intel = WhisperService.computeOptions(hasNeuralEngine: false)
        XCTAssertEqual(intel.audioEncoderCompute, .cpuAndGPU)
        XCTAssertEqual(intel.textDecoderCompute, .cpuAndGPU)
    }
}
