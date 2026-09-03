import XCTest

@testable import speaktype

final class LocalPunctuationFormatterTests: XCTestCase {
    func testPortugueseSpokenPunctuationIsInsertedExactly() {
        withPreferences {
            XCTAssertEqual(
                LocalPunctuationFormatter.apply(
                    to: "olá vírgula tudo bem ponto de interrogação", language: "pt-BR"),
                "olá, tudo bem?"
            )
        }
    }

    func testAutomaticTerminalPunctuationHandlesStatementsAndQuestions() {
        withPreferences {
            XCTAssertEqual(
                LocalPunctuationFormatter.apply(to: "vamos marcar para amanhã", language: "pt-BR"),
                "vamos marcar para amanhã."
            )
            XCTAssertEqual(
                LocalPunctuationFormatter.apply(to: "quando vamos marcar", language: "pt-BR"),
                "quando vamos marcar?"
            )
        }
    }

    func testDoesNotDamageDecimalNumbersOrEmails() {
        withPreferences {
            XCTAssertEqual(
                LocalPunctuationFormatter.apply(to: "o valor é 3.14", language: "pt-BR"),
                "o valor é 3.14."
            )
            XCTAssertEqual(
                LocalPunctuationFormatter.apply(
                    to: "meu email é ana@example.com", language: "pt-BR"),
                "meu email é ana@example.com."
            )
        }
    }

    func testLiteralProfileDoesNotChangePunctuation() {
        withPreferences(profile: .literal) {
            XCTAssertEqual(
                LocalPunctuationFormatter.apply(to: "quando vamos marcar", language: "pt-BR"),
                "quando vamos marcar"
            )
        }
    }

    private func withPreferences(
        profile: DictationFormattingProfile = .smart,
        body: () -> Void
    ) {
        let defaults = UserDefaults.standard
        let entries: [(String, Any)] = [
            (DictationFormattingProfile.defaultsKey, profile.rawValue),
            (LocalPunctuationFormatter.spokenPunctuationDefaultsKey, true),
            (LocalPunctuationFormatter.terminalPunctuationDefaultsKey, true),
        ]
        let previous = entries.map { ($0.0, defaults.object(forKey: $0.0)) }
        defer {
            for (key, value) in previous {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        for (key, value) in entries {
            defaults.set(value, forKey: key)
        }
        body()
    }
}
