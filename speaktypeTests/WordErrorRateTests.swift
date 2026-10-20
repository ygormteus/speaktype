import XCTest
@testable import speaktype

final class WordErrorRateTests: XCTestCase {

    func testIdenticalTextHasZeroErrors() {
        let result = WordErrorRate.compute(reference: "Olá, tudo bem?", hypothesis: "olá tudo bem")
        XCTAssertEqual(result, .init(errors: 0, referenceWords: 3))
        XCTAssertEqual(result.rate, 0)
    }

    func testCountsSubstitutionDeletionAndInsertion() {
        // sub: "manhã" -> "manha"; del: "de"; ins: "hoje"
        let result = WordErrorRate.compute(
            reference: "bom dia de manhã",
            hypothesis: "bom dia manha hoje"
        )
        XCTAssertEqual(result.referenceWords, 4)
        XCTAssertEqual(result.errors, 2)  // "de"->"manha" sub, "manhã"->"hoje" sub
        XCTAssertEqual(result.rate, 0.5, accuracy: 1e-9)
    }

    func testEditDistanceClassicCases() {
        XCTAssertEqual(WordErrorRate.editDistance(["a", "b", "c"], ["a", "c"]), 1)
        XCTAssertEqual(WordErrorRate.editDistance(["a", "c"], ["a", "b", "c"]), 1)
        XCTAssertEqual(WordErrorRate.editDistance(["a", "b"], ["c", "d"]), 2)
        XCTAssertEqual(WordErrorRate.editDistance([], ["x", "y"]), 2)
        XCTAssertEqual(WordErrorRate.editDistance(["x"], []), 1)
    }

    func testAccentsMatterUnlessFolded() {
        let strict = WordErrorRate.compute(reference: "não é você", hypothesis: "nao e voce")
        XCTAssertEqual(strict.errors, 3)

        let folded = WordErrorRate.compute(
            reference: "não é você", hypothesis: "nao e voce", foldingDiacritics: true)
        XCTAssertEqual(folded.errors, 0)
    }

    func testNormalizationStripsPunctuationAndCase() {
        XCTAssertEqual(
            WordErrorRate.normalize("  Ei!  Você viu o João? — São 10h30, né…  "),
            "ei você viu o joão são 10h30 né"
        )
        XCTAssertEqual(WordErrorRate.normalize("guarda-chuva d'água"), "guarda chuva d água")
    }

    func testEmptyReference() {
        XCTAssertEqual(WordErrorRate.compute(reference: "", hypothesis: "").rate, 0)
        XCTAssertEqual(WordErrorRate.compute(reference: "", hypothesis: "oi").rate, 1)
    }
}

final class NemotronCatalogTests: XCTestCase {

    func testBarePortugueseResolvesToBrazilianPrompt() {
        // metadata.json maps bare "pt" to the pt-PT prompt id, so the app's
        // stored "pt" must never reach FluidAudio unchanged.
        XCTAssertEqual(NemotronCatalog.promptLanguage(for: "pt"), "pt-BR")
        XCTAssertEqual(NemotronCatalog.promptLanguage(for: "auto"), "pt-BR")
        XCTAssertEqual(NemotronCatalog.promptLanguage(for: ""), "pt-BR")
        XCTAssertEqual(NemotronCatalog.promptLanguage(for: "pt-BR"), "pt-BR")
        XCTAssertEqual(NemotronCatalog.promptLanguage(for: "pt_br"), "pt-BR")
        XCTAssertEqual(NemotronCatalog.promptLanguage(for: "pt-PT"), "pt-PT")
    }

    func testRecorderPushSizeEvenlyDividesEveryNemotronChunk() {
        // FluidAudio's process(samples:) buffers to the model chunk, so the
        // push size only has to keep boundaries aligned (no added latency).
        let push = AudioRecordingService.directStreamingChunkSamples
        for variant in NemotronCatalog.variants {
            let chunk = try? XCTUnwrap(NemotronCatalog.chunkSamples(for: variant))
            XCTAssertNotNil(chunk)
            XCTAssertEqual((chunk ?? 1) % push, 0, variant)
        }
        XCTAssertEqual(NemotronCatalog.chunkSamples(for: NemotronCatalog.fastVariant), 8_960)
        XCTAssertEqual(NemotronCatalog.chunkSamples(for: NemotronCatalog.qualityVariant), 35_840)
    }
}
