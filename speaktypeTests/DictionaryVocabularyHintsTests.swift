import XCTest
@testable import speaktype

final class DictionaryVocabularyHintsTests: XCTestCase {
    func testHintsKeepVocabularyAndSkipSnippets() {
        let entries = [
            DictionaryEntry(trigger: "figjam", replacement: "FigJam"),
            DictionaryEntry(trigger: "speak type", replacement: " SpeakType "),
            DictionaryEntry(trigger: "fig jam", replacement: "figjam"),  // duplicate term
            DictionaryEntry(trigger: "my email", replacement: "roy.sanhik@gmail.com"),
            DictionaryEntry(trigger: "site", replacement: "https://example.com"),
            DictionaryEntry(trigger: "assinatura", replacement: "Atenciosamente,\nYgor"),
            DictionaryEntry(
                trigger: "intro",
                replacement: "Olá, obrigado pelo contato, retorno assim que possível."),
            DictionaryEntry(trigger: "uhm", replacement: ""),  // deletion rule
            DictionaryEntry(trigger: "lgpd", replacement: "LGPD", isEnabled: false),
            DictionaryEntry(trigger: "sao paulo", replacement: "São Paulo"),
            DictionaryEntry(trigger: "numero", replacement: "123"),
        ]

        XCTAssertEqual(
            DictionaryService.vocabularyHints(from: entries),
            ["FigJam", "SpeakType", "São Paulo"])
    }

    func testHintsRespectLimit() {
        let entries = (0..<10).map { DictionaryEntry(trigger: "t\($0)", replacement: "Termo\($0)") }

        XCTAssertEqual(DictionaryService.vocabularyHints(from: entries, limit: 3).count, 3)
        XCTAssertEqual(DictionaryService.vocabularyHints(from: entries, limit: 0), [])
    }
}
