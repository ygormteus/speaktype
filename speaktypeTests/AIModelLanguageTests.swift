import XCTest
@testable import speaktype

final class AIModelLanguageTests: XCTestCase {
    func testEnglishOnlyModelsAreExcludedForPortugueseAndAutoDetect() {
        let englishOnly = try! XCTUnwrap(
            AIModel.availableModels.first(where: { $0.variant == "openai_whisper-small.en" })
        )

        XCTAssertTrue(englishOnly.supports(spokenLanguage: "en"))
        XCTAssertFalse(englishOnly.supports(spokenLanguage: "pt"))
        XCTAssertFalse(englishOnly.supports(spokenLanguage: "auto"))
    }

    func testPortugueseCatalogContainsOnlyCompatibleModels() {
        let portugueseModels = AIModel.models(for: .parakeet, spokenLanguage: "pt")

        XCTAssertEqual(portugueseModels.map(\.variant), [ParakeetCatalog.v3Variant])
        XCTAssertFalse(AIModel.recommendedModel(spokenLanguage: "pt").isEnglishOnly)
    }

    func testPortugueseStreamingModelsAreOnlyAvailableForPortuguese() {
        for variant in NemotronCatalog.variants {
            let model = try! XCTUnwrap(
                AIModel.availableModels.first(where: { $0.variant == variant })
            )

            XCTAssertTrue(model.supports(spokenLanguage: "pt"))
            XCTAssertTrue(model.supports(spokenLanguage: "pt-BR"))
            XCTAssertFalse(model.supports(spokenLanguage: "en"))
            XCTAssertFalse(model.supports(spokenLanguage: "auto"))
        }
    }

    func testNemotronWindowProfilesMapToSupportedFluidAudioTiers() {
        XCTAssertEqual(NemotronCatalog.chunkMilliseconds(for: NemotronCatalog.fastVariant), 560)
        XCTAssertEqual(NemotronCatalog.chunkMilliseconds(for: NemotronCatalog.balancedVariant), 1_120)
        XCTAssertEqual(NemotronCatalog.chunkMilliseconds(for: NemotronCatalog.qualityVariant), 2_240)
    }

    func testPortugueseSuggestionsRemainOptIn() {
        XCTAssertTrue(DictionaryService.portugueseSuggestions.contains {
            $0.trigger == "whatsapp" && $0.replacement == "WhatsApp"
        })
    }
}
