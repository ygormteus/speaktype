import XCTest
@testable import speaktype

@MainActor
final class MeetingModelSelectionTests: XCTestCase {
    private let fast = "freds0_distil-whisper-large-v3-ptbr"
    private let fidelity = "openai_whisper-large-v3_turbo"

    func testOnlyDownloadedCompatibleMeetingModelsAreOffered() {
        let downloaded: Set<String> = [fast, fidelity, ParakeetCatalog.v3Variant, "openai_whisper-small.en"]
        XCTAssertEqual(Set(MeetingModelSelection.models(language: "pt", downloaded: downloaded).map(\.variant)), [fast, fidelity])
        XCTAssertEqual(MeetingModelSelection.models(language: "en", downloaded: downloaded).map(\.variant), [fidelity])
        XCTAssertTrue(MeetingModelSelection.models(language: "pt", downloaded: []).isEmpty)
    }

    func testSavedChoiceIsRememberedOnlyWhenDownloadedAndLanguageCompatible() {
        let downloaded: Set<String> = [fast, fidelity]
        XCTAssertEqual(MeetingModelSelection.resolvedVariant(preferred: fast, language: "pt", downloaded: downloaded), fast)
        XCTAssertEqual(MeetingModelSelection.resolvedVariant(preferred: fast, language: "en", downloaded: downloaded), fidelity)
        XCTAssertEqual(MeetingModelSelection.resolvedVariant(preferred: fast, language: "pt", downloaded: [fidelity]), fidelity)
        XCTAssertEqual(MeetingModelSelection.resolvedVariant(preferred: fidelity, language: "pt", downloaded: []), "")
    }

    func testMeetingPreferenceIsIndependentAndDoesNotPromoteExperimentalModelByDefault() {
        XCTAssertNotEqual(MeetingModelSelection.defaultsKey, ModelSelection.defaultsKey)
        XCTAssertEqual(MeetingModelSelection.resolvedVariant(preferred: "", language: "pt", downloaded: [fast, fidelity]), fidelity)
    }
}
