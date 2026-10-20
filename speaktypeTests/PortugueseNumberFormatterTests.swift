import XCTest
@testable import speaktype

final class PortugueseNumberFormatterTests: XCTestCase {
    // MARK: - Cardinals

    func testCompoundCardinals() {
        assertFormats([
            ("cento e vinte e três", "123"),
            ("vinte e um", "21"),
            ("trinta e cinco mil", "35.000"),
            ("mil e quinhentos", "1.500"),
            ("duzentos e cinquenta mil e trezentos", "250.300"),
            ("cem mil", "100.000"),
            ("mil e um", "1.001"),
            ("dez mil", "10.000"),
            ("trezentos", "300"),
            ("cem", "100"),
            ("noventa e nove", "99"),
        ])
    }

    func testFeminineAndSpellingVariants() {
        assertFormats([
            ("vinte e uma pessoas", "21 pessoas"),
            ("duzentas e duas vagas", "202 vagas"),
            ("trezentas pessoas", "300 pessoas"),
            ("quatorze anos", "14 anos"),
            ("catorze anos", "14 anos"),
            ("dezesseis", "16"),
            ("dezessete", "17"),
            ("dezenove", "19"),
            ("vinte e tres", "23"),
            ("vinte e três", "23"),
            ("cinqüenta e cinco", "55"),
        ])
    }

    func testYearsAreWrittenWithoutThousandsSeparator() {
        assertFormats([
            ("dois mil e vinte e seis", "2026"),
            ("em dois mil e vinte e seis", "em 2026"),
            ("mil novecentos e noventa e nove", "1999"),
            ("dois mil vinte e seis", "2026"),
            ("dois mil", "2000"),
        ])
    }

    func testFeminineThousandsCountThingsAndKeepSeparator() {
        assertFormat("duas mil pessoas", "2.000 pessoas")
    }

    func testScales() {
        assertFormats([
            ("um milhão de pessoas", "1 milhão de pessoas"),
            ("dois milhões", "2 milhões"),
            ("um milhão e meio", "1,5 milhão"),
            ("dois milhões e meio", "2,5 milhões"),
            ("um milhão e duzentos mil", "1.200.000"),
            ("três bilhões", "3 bilhões"),
            ("um milhao", "1 milhão"),
        ])
    }

    // MARK: - Currency, percent, decimals, units

    func testCurrency() {
        assertFormats([
            ("cinquenta reais", "R$ 50"),
            ("dez reais e cinquenta centavos", "R$ 10,50"),
            ("um real e cinco centavos", "R$ 1,05"),
            ("mil e quinhentos reais", "R$ 1.500"),
            ("dois mil reais", "R$ 2.000"),
            ("vinte dólares", "US$ 20"),
            ("vinte dolares", "US$ 20"),
            ("um real", "R$ 1"),
            ("cem euros", "€ 100"),
            ("dois milhões de reais", "R$ 2 milhões"),
            ("três vírgula cinco reais", "R$ 3,50"),
            ("custa cinquenta reais.", "custa R$ 50."),
        ])
    }

    func testPercent() {
        assertFormats([
            ("dez por cento", "10%"),
            ("cinco vírgula cinco por cento", "5,5%"),
            ("cem por cento", "100%"),
            ("cinco porcento", "5%"),
        ])
    }

    func testDecimals() {
        assertFormats([
            ("três vírgula cinco", "3,5"),
            ("tres virgula cinco", "3,5"),
            ("um vírgula zero cinco", "1,05"),
            ("dois vírgula vinte e cinco", "2,25"),
        ])
    }

    func testSmallNumbersBeforeUnitsBecomeDigits() {
        assertFormats([
            ("três quilos", "3 quilos"),
            ("cinco quilômetros", "5 quilômetros"),
            ("cinquenta centavos", "50 centavos"),
        ])
    }

    // MARK: - Digits from the ASR engine

    func testDigitAmountsGetSymbols() {
        assertFormats([
            ("50 reais", "R$ 50"),
            ("10 reais e 50 centavos", "R$ 10,50"),
            ("1.500 reais", "R$ 1.500"),
            ("5,5 por cento", "5,5%"),
        ])
    }

    func testAlreadyFormattedTextIsUnchanged() {
        for text in ["R$ 50", "10%", "Em 2026 vendemos 35.000 unidades.", "3,5", "US$ 20", "1 milhão"] {
            assertFormat(text, text)
        }
    }

    func testFormattingIsIdempotent() {
        let inputs = [
            "dez reais e cinquenta centavos",
            "cinco vírgula cinco por cento",
            "dois mil e vinte e seis",
            "um milhão e meio",
            "50 reais",
        ]
        withPreferences {
            for input in inputs {
                let once = PortugueseNumberFormatter.apply(to: input, language: "pt-BR")
                XCTAssertEqual(PortugueseNumberFormatter.apply(to: once, language: "pt-BR"), once, input)
            }
        }
    }

    // MARK: - Prose that must stay as words

    func testArticlesAndSmallNumbersInProseStay() {
        for text in [
            "um carro",
            "uma ideia",
            "dois amigos chegaram",
            "Comprei um livro e uma caneta.",
            "duas horas",
            "mil vezes obrigado",
            "marco zero",
            "dez",
        ] {
            assertFormat(text, text)
        }
    }

    func testOrdinalsAndPunctuationWordsStay() {
        for text in [
            "primeiro lugar",
            "vírgula",
            "Ponto de ônibus",
            "coloque uma vírgula aqui",
            "coloque uma vírgula dois pontos",
            "três ponto cinco",
        ] {
            assertFormat(text, text)
        }
    }

    func testSpokenListIsNotADecimal() {
        assertFormat("um vírgula dois vírgula três", "um vírgula dois vírgula três")
    }

    func testTimesAndHalvesStayAsSpoken() {
        for text in ["às três e meia", "às quinze e meia", "quinze para as três", "meio-dia", "meia-noite"] {
            assertFormat(text, text)
        }
    }

    func testProperNounsAndHyphenatedWordsStay() {
        for text in ["Rua Sete de Setembro", "Moro em Três Corações", "botas de sete-léguas"] {
            assertFormat(text, text)
        }
    }

    func testPunctuationAndSurroundingWordsArePreserved() {
        assertFormats([
            ("Vinte e cinco pessoas vieram.", "25 pessoas vieram."),
            ("Chegaram quinze, depois vinte e dois!", "Chegaram 15, depois 22!"),
            ("O Brasil tem duzentos milhões de habitantes", "O Brasil tem 200 milhões de habitantes"),
        ])
    }

    func testPunctuationBreaksANumber() {
        // A comma (not the spoken word) separates two numbers.
        assertFormat("vinte, e um", "20, e um")
    }

    func testSpokenPunctuationStillWorksAfterNumbersPass() {
        withPreferences {
            let numbers = PortugueseNumberFormatter.apply(
                to: "o valor é três vírgula cinco vírgula depois revisamos", language: "pt-BR")
            XCTAssertEqual(numbers, "o valor é 3,5 vírgula depois revisamos")
            XCTAssertEqual(
                LocalPunctuationFormatter.apply(to: numbers, language: "pt-BR"),
                "o valor é 3,5, depois revisamos."
            )
        }
    }

    // MARK: - Gating

    func testOtherLanguagesAreLeftUntouched() {
        withPreferences {
            XCTAssertEqual(
                PortugueseNumberFormatter.apply(to: "vinte e cinco reais", language: "en"),
                "vinte e cinco reais"
            )
            XCTAssertEqual(
                PortugueseNumberFormatter.apply(to: "twenty five dollars", language: "en-US"),
                "twenty five dollars"
            )
        }
    }

    func testLiteralProfileIsLeftUntouched() {
        withPreferences(profile: .literal) {
            XCTAssertEqual(
                PortugueseNumberFormatter.apply(to: "cinquenta reais", language: "pt-BR"),
                "cinquenta reais"
            )
        }
    }

    func testDisabledToggleIsLeftUntouched() {
        withPreferences(enabled: false) {
            XCTAssertEqual(
                PortugueseNumberFormatter.apply(to: "cinquenta reais", language: "pt-BR"),
                "cinquenta reais"
            )
        }
    }

    func testEnabledByDefault() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: PortugueseNumberFormatter.defaultsKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: PortugueseNumberFormatter.defaultsKey)
            } else {
                defaults.removeObject(forKey: PortugueseNumberFormatter.defaultsKey)
            }
        }
        defaults.removeObject(forKey: PortugueseNumberFormatter.defaultsKey)
        XCTAssertTrue(PortugueseNumberFormatter.isEnabled)
    }

    // MARK: - Regressions

    func testMetroIsNotTheUnitMetro() {
        assertFormats([
            ("vou pegar um metrô", "vou pegar um metrô"),
            ("dois metrôs lotados", "dois metrôs lotados"),
            ("três metros", "3 metros"),
            ("cinco quilometros", "5 quilometros"),
        ])
    }

    func testRealAsAdjectiveIsNotCurrency() {
        assertFormats([
            ("é uma real possibilidade", "é uma real possibilidade"),
            ("existe um real problema aqui", "existe um real problema aqui"),
            ("custa um real cada", "custa R$ 1 cada"),
            ("paguei um real pelo pão", "paguei R$ 1 pelo pão"),
        ])
    }

    func testUmAfterVirgulaIsNotAFractionBeforeProse() {
        assertFormats([
            ("eram quinze vírgula um deles reclamou", "eram 15 vírgula um deles reclamou"),
            ("três vírgula um", "3,1"),
            ("três vírgula um por cento", "3,1%"),
            ("dois vírgula um quilos", "2,1 quilos"),
        ])
    }

    func testThousandsBeforeANounAreCountsNotYears() {
        assertFormats([
            ("dois mil funcionários", "2.000 funcionários"),
            ("cerca de dois mil funcionários", "cerca de 2.000 funcionários"),
            ("mil e novecentos alunos", "1.900 alunos"),
            ("em dois mil e vinte e seis", "em 2026"),
            ("o ano de dois mil", "o ano de 2000"),
            ("desde dois mil e dez trabalho aqui", "desde 2010 trabalho aqui"),
            ("dois mil e vinte e seis foi um ano difícil", "2026 foi um ano difícil"),
            ("em dois mil e vinte e seis, mudamos", "em 2026, mudamos"),
            ("mil e uma utilidades", "mil e uma utilidades"),
        ])
    }

    // MARK: - Helpers

    private func assertFormats(
        _ cases: [(String, String)], file: StaticString = #filePath, line: UInt = #line
    ) {
        for (input, expected) in cases {
            assertFormat(input, expected, file: file, line: line)
        }
    }

    private func assertFormat(
        _ input: String, _ expected: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        withPreferences {
            XCTAssertEqual(
                PortugueseNumberFormatter.apply(to: input, language: "pt-BR"), expected,
                "input: \(input)", file: file, line: line)
        }
    }

    private func withPreferences(
        profile: DictationFormattingProfile = .smart,
        enabled: Bool = true,
        body: () -> Void
    ) {
        let defaults = UserDefaults.standard
        let entries: [(String, Any)] = [
            (DictationFormattingProfile.defaultsKey, profile.rawValue),
            (PortugueseNumberFormatter.defaultsKey, enabled),
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
