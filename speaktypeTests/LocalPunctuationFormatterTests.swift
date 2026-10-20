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

    // MARK: - Spoken punctuation

    func testEllipsisIsJoinedToThePreviousWord() {
        assertPT("espera reticências já volto", "espera… já volto.")
        assertPT("deixa eu pensar reticencias", "deixa eu pensar…")
    }

    func testParenthesesHaveNoInnerSpaces() {
        assertPT(
            "a reunião abre parênteses de amanhã fecha parênteses foi adiada",
            "a reunião (de amanhã) foi adiada.")
        assertPT(
            "o prazo abrir parenteses sexta fechar parenteses vírgula ok",
            "o prazo (sexta), ok?")
    }

    func testQuotesHaveNoInnerSpaces() {
        assertPT(
            "ele disse abre aspas tudo certo fecha aspas e saiu",
            "ele disse \"tudo certo\" e saiu.")
        assertPT(
            "ele respondeu abrir aspas não fechar aspas ponto final",
            "ele respondeu \"não\".")
    }

    func testDashJoinsWithSpacesAndHyphenJoinsWithout() {
        assertPT("a resposta travessão sim travessão veio rápido", "a resposta — sim — veio rápido.")
        assertPT("comprei um guarda hífen chuva", "comprei um guarda-chuva.")
        assertPT("fiz um bate hifen papo", "fiz um bate-papo.")
    }

    func testHyphenAsANounIsKept() {
        assertPT("o hífen de guarda-chuva caiu", "o hífen de guarda-chuva caiu.")
        assertPT("palavras com hífen são difíceis", "palavras com hífen são difíceis.")
    }

    func testEmailAndDomainsAreJoined() {
        assertPT("meu email é ana arroba gmail ponto com", "meu email é ana@gmail.com.")
        assertPT("acesse empresa ponto com ponto br", "acesse empresa.com.br.")
        assertPT(
            "escreva para joao arroba empresa ponto com ponto br hoje",
            "escreva para joao@empresa.com.br hoje.")
    }

    func testProseUsesOfArrobaAndPontoComAreKept() {
        assertPT("comprei uma arroba de carne", "comprei uma arroba de carne.")
        assertPT("tenho um ponto com o cliente amanhã", "tenho um ponto com o cliente amanhã.")
        assertPT("alinhei esse ponto com você", "alinhei esse ponto com você.")
    }

    func testBarraOnlyBecomesSlashBetweenNumbers() {
        assertPT("a reunião é dia 10 barra 5", "a reunião é dia 10/5.")
        assertPT("comi uma barra de chocolate", "comi uma barra de chocolate.")
        assertPT("segura a barra aí", "segura a barra aí.")
    }

    func testParagraphPeriodBreaksTheParagraph() {
        assertPT(
            "primeira parte ponto parágrafo segunda parte",
            "primeira parte.\n\nsegunda parte.")
        assertPT("fim do texto ponto paragrafo", "fim do texto.")
    }

    func testBarePontoOnlyAsFinalWord() {
        assertPT("vamos sair agora ponto", "vamos sair agora.")
        assertPT("fiquei no ponto de ônibus", "fiquei no ponto de ônibus.")
        assertPT("esse é o ponto", "esse é o ponto.")
        assertPT("chegamos a um ponto", "chegamos a um ponto.")
    }

    func testEnglishEquivalents() {
        withPreferences {
            XCTAssertEqual(
                LocalPunctuationFormatter.apply(
                    to: "send it to ana at example dot com open paren today close paren please",
                    language: "en"),
                "send it to ana at example.com (today) please."
            )
            XCTAssertEqual(
                LocalPunctuationFormatter.apply(
                    to: "she said open quote hi end quote", language: "en"),
                "she said \"hi\""
            )
        }
    }

    // MARK: - Question detection

    func testPortugueseQuestionPrefixes() {
        let questions = [
            "o que você acha", "o quê você disse", "que horas são", "cadê meu celular",
            "tem como mandar hoje", "dá pra mandar hoje", "da pra mandar hoje",
            "dá para mandar hoje", "posso entrar agora", "podemos começar",
            "poderia me ajudar", "você sabe onde fica", "voce sabe onde fica",
            "vocês podem vir amanhã", "e se der errado", "não seria melhor esperar",
            "por quê você foi embora", "pra que serve isso", "para que serve isso",
            "como assim você não vem",
        ]
        for question in questions {
            assertPT(question, question + "?")
        }
    }

    func testPortugueseTagQuestions() {
        assertPT("você vem amanhã, né", "você vem amanhã, né?")
        assertPT("você vem amanhã né", "você vem amanhã né?")
        assertPT("a gente se fala depois, certo", "a gente se fala depois, certo?")
        assertPT("te ligo às cinco, tá bom", "te ligo às cinco, tá bom?")
        assertPT("fechamos assim, beleza", "fechamos assim, beleza?")
        assertPT("mando o arquivo depois, ok", "mando o arquivo depois, ok?")
        assertPT("isso é verdade, não é", "isso é verdade, não é?")
    }

    func testPortugueseStatementsAreNotQuestions() {
        assertPT("como eu disse ontem a reunião mudou", "como eu disse ontem a reunião mudou.")
        assertPT("como sempre ele chegou atrasado", "como sempre ele chegou atrasado.")
        assertPT("o que importa é a saúde", "o que importa é a saúde.")
        assertPT(
            "para que todos entendam, vou explicar de novo",
            "para que todos entendam, vou explicar de novo.")
        assertPT("vocês fizeram um ótimo trabalho", "vocês fizeram um ótimo trabalho.")
    }

    func testQuestionDetectionUsesTheFinalSentence() {
        assertPT("já cheguei. onde você está", "já cheguei. onde você está?")
        assertPT("onde você está? já cheguei aqui", "onde você está? já cheguei aqui.")
        assertPT("tudo certo por aqui\nquando você chega", "tudo certo por aqui\nquando você chega?")
        assertPT("quanto custa 3.14 reais", "quanto custa 3.14 reais?")
    }

    func testEnglishTagQuestion() {
        withPreferences {
            XCTAssertEqual(
                LocalPunctuationFormatter.apply(to: "you are coming, right", language: "en"),
                "you are coming, right?"
            )
        }
    }

    private func assertPT(
        _ input: String, _ expected: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        withPreferences {
            XCTAssertEqual(
                LocalPunctuationFormatter.apply(to: input, language: "pt-BR"), expected,
                file: file, line: line)
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
