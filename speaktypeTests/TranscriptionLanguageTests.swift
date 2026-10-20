import XCTest

@testable import speaktype

final class TranscriptionLanguageTests: XCTestCase {
    func testPortugueseSystemDefaultsToPortuguese() {
        XCTAssertEqual(
            TranscriptionLanguage.defaultCode(appLanguage: nil, preferredLanguages: ["pt-BR", "en-US"]),
            "pt")
        XCTAssertEqual(
            TranscriptionLanguage.defaultCode(appLanguage: "system", preferredLanguages: ["pt-PT"]),
            "pt")
    }

    func testOtherSystemsKeepAutoDetection() {
        XCTAssertEqual(
            TranscriptionLanguage.defaultCode(appLanguage: nil, preferredLanguages: ["en-US", "pt-BR"]),
            "auto")
        XCTAssertEqual(TranscriptionLanguage.defaultCode(appLanguage: nil, preferredLanguages: []), "auto")
    }

    func testAppLanguageOverridesSystem() {
        XCTAssertEqual(
            TranscriptionLanguage.defaultCode(appLanguage: "portugueseBrazil", preferredLanguages: ["en-US"]),
            "pt")
        XCTAssertEqual(
            TranscriptionLanguage.defaultCode(appLanguage: "english", preferredLanguages: ["pt-BR"]),
            "auto")
    }

    func testExplicitChoiceWinsOverRegisteredDefault() throws {
        let suite = "TranscriptionLanguageTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        TranscriptionLanguage.registerDefault(in: defaults, preferredLanguages: ["pt-BR"])
        XCTAssertEqual(defaults.string(forKey: TranscriptionLanguage.defaultsKey), "pt")

        defaults.set("auto", forKey: TranscriptionLanguage.defaultsKey)
        TranscriptionLanguage.registerDefault(in: defaults, preferredLanguages: ["pt-BR"])
        XCTAssertEqual(defaults.string(forKey: TranscriptionLanguage.defaultsKey), "auto")
    }
}
