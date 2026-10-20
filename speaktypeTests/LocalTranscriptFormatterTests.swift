import XCTest

@testable import speaktype

final class LocalTranscriptFormatterTests: XCTestCase {
    func testLiteralPreservesRecognizedText() {
        withPreferences(profile: .literal) {
            XCTAssertEqual(
                LocalTranscriptFormatter.apply(to: "olá mundo. nova linha tudo bem?", language: "pt-BR"),
                "olá mundo. nova linha tudo bem?"
            )
        }
    }

    func testSmartFormatsExplicitSpokenBreaksAndSentenceStarts() {
        withPreferences(profile: .smart) {
            XCTAssertEqual(
                LocalTranscriptFormatter.apply(to: "olá mundo. nova linha tudo bem?", language: "pt-BR"),
                "Olá mundo. Nova linha tudo bem?"
            )
        }
    }

    func testMessageAndEmailProfilesHandleExplicitParagraphCommands() {
        withPreferences(profile: .message) {
            XCTAssertEqual(
                LocalTranscriptFormatter.apply(to: "olá nova linha tudo bem?", language: "pt-BR"),
                "Olá\nTudo bem?"
            )
        }

        withPreferences(profile: .email) {
            XCTAssertEqual(
                LocalTranscriptFormatter.apply(
                    to: "assunto reunião amanhã novo parágrafo olá equipe", language: "pt-BR"),
                "Assunto: reunião amanhã\n\nOlá equipe"
            )
        }
    }

    func testNotesTurnsExplicitItemCommandsIntoBullets() {
        withPreferences(profile: .notes) {
            XCTAssertEqual(
                LocalTranscriptFormatter.apply(
                    to: "comprar leite novo item ligar para joão", language: "pt-BR"),
                "• Comprar leite\n• Ligar para joão"
            )
        }
    }

    func testAutoEditRunsForEveryEngineFinalizationPath() {
        withPreferences(profile: .literal, autoEdit: true) {
            XCTAssertEqual(
                LocalTranscriptFormatter.apply(to: "uh, reunião às três", language: "en"),
                "reunião às três"
            )
        }
    }

    func testPortugueseHesitationsAreRemoved() {
        withPreferences(profile: .literal, autoEdit: true) {
            XCTAssertEqual(
                LocalTranscriptFormatter.apply(
                    to: "ãh, a reunião ahn é hã amanhã hum às éé três eeee horas uhm",
                    language: "pt-BR"),
                "a reunião é amanhã às três horas"
            )
            XCTAssertEqual(
                LocalTranscriptFormatter.apply(to: "então ãhh hmmm vamos", language: "pt-BR"),
                "então vamos"
            )
        }
    }

    func testPortugueseMeaningfulWordsAreKept() {
        withPreferences(profile: .literal, autoEdit: true) {
            for text in [
                "Ah, entendi", "é um bom dia", "tipo assim, né", "então e depois", "um dois três",
                "ele é é bom",
            ] {
                XCTAssertEqual(LocalTranscriptFormatter.apply(to: text, language: "pt-BR"), text)
            }
        }
    }

    func testPortugueseFillersAreOnlyRemovedForPortuguese() {
        withPreferences(profile: .literal, autoEdit: true) {
            XCTAssertEqual(
                LocalTranscriptFormatter.apply(to: "hum yes", language: "en"), "hum yes")
        }
    }

    func testSmartCapitalizesAfterNewSpokenMarks() {
        withPreferences(profile: .smart) {
            XCTAssertEqual(
                LocalTranscriptFormatter.apply(
                    to: "primeira parte.\n\nsegunda parte. \"oi\" disse ele. veja ana@gmail.com.br",
                    language: "pt-BR"),
                "Primeira parte.\n\nSegunda parte. \"Oi\" disse ele. Veja ana@gmail.com.br"
            )
        }
    }

    private func withPreferences(
        profile: DictationFormattingProfile,
        autoEdit: Bool = false,
        body: () -> Void
    ) {
        let defaults = UserDefaults.standard
        let profileKey = DictationFormattingProfile.defaultsKey
        let autoEditKey = "enableAutoEdit"
        let previousProfile = defaults.object(forKey: profileKey)
        let previousAutoEdit = defaults.object(forKey: autoEditKey)
        defer {
            restore(previousProfile, forKey: profileKey, defaults: defaults)
            restore(previousAutoEdit, forKey: autoEditKey, defaults: defaults)
        }

        defaults.set(profile.rawValue, forKey: profileKey)
        defaults.set(autoEdit, forKey: autoEditKey)
        body()
    }

    private func restore(_ value: Any?, forKey key: String, defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
