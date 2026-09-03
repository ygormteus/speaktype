import XCTest
@testable import speaktype

final class VoiceCommandProcessorTests: XCTestCase {
    private let defaults = UserDefaults.standard

    override func setUp() {
        super.setUp()
        defaults.set(true, forKey: VoiceCommandProcessor.defaultsKey)
    }

    override func tearDown() {
        defaults.removeObject(forKey: VoiceCommandProcessor.defaultsKey)
        super.tearDown()
    }

    func testFormatsParagraphLineAndListCommandsLocally() {
        XCTAssertEqual(
            VoiceCommandProcessor.apply(
                to: "primeiro novo parágrafo segundo nova linha terceiro próximo item quarto",
                language: "pt"
            ),
            "primeiro\n\nsegundo\nterceiro\n• quarto"
        )
    }

    func testClearingTextOnlyRunsAtEndOfDictation() {
        XCTAssertEqual(
            VoiceCommandProcessor.apply(to: "rascunho comando limpar texto", language: "pt"),
            ""
        )
        XCTAssertEqual(
            VoiceCommandProcessor.apply(to: "limpar texto depois continue", language: "pt"),
            "limpar texto depois continue"
        )
    }

    func testCanBeDisabled() {
        defaults.set(false, forKey: VoiceCommandProcessor.defaultsKey)
        XCTAssertEqual(
            VoiceCommandProcessor.apply(to: "novo parágrafo texto", language: "pt"),
            "novo parágrafo texto"
        )
    }

    func testOldDictionaryEntriesDecodeWithGeneralCategory() throws {
        let data = Data(#"[{"id":"E5DA932C-3383-4F17-970D-DCA583DFBF03","trigger":"teste","replacement":"Teste","isEnabled":true,"matchWholeWord":true}]"#.utf8)
        let entries = try JSONDecoder().decode([DictionaryEntry].self, from: data)
        XCTAssertEqual(entries.first?.category, .general)
    }
}
