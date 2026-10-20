import Foundation

/// Conservative inverse text normalization (ITN) for Brazilian Portuguese:
/// spoken numbers become written numbers ("dois mil e vinte e seis" → "2026",
/// "cinquenta reais" → "R$ 50", "dez por cento" → "10%").
///
/// The formatter is pure and deterministic, and it is idempotent: text that
/// already contains digits (as Whisper/Parakeet/Nemotron often emit) is left
/// as is, apart from attaching currency/percent symbols to bare digits
/// ("50 reais" → "R$ 50").
///
/// Rules, chosen to favour leaving words over producing a wrong number:
/// - Compound cardinals always become digits ("vinte e um", "cento e vinte e
///   três", "trinta e cinco mil"). Single number words ≥ 11 ("quinze",
///   "vinte", "duzentos") become digits too.
/// - Zero to ten ("um"/"uma" are also articles) and a lone "mil" ("mil
///   vezes") only become digits before a currency, "por cento", a measurement
///   unit, or as part of a decimal. Prose such as "um carro" or "dois amigos"
///   is untouched. Time words ("horas", "minutos") are not triggers, so
///   "duas horas" stays.
/// - Thousands use the PT-BR "." separator ("35.000", "R$ 1.500"). Values in
///   1900...2100 are treated as years and written without a separator
///   ("2026"), unless they carry a currency/percent/unit, are a decimal, or
///   use feminine forms ("duas mil pessoas" counts things, it is not a year).
/// - Whole millions/billions keep the scale word: "dois milhões" → "2
///   milhões", "um milhão e meio" → "1,5 milhão", "dois milhões de reais" →
///   "R$ 2 milhões". Mixed values are written out ("1.200.000").
/// - Currency: reais → "R$", dólares → "US$", euros → "€", with optional
///   "e N centavos" ("R$ 10,50").
/// - Decimals: number + "vírgula" + number ("três vírgula cinco" → "3,5").
///   Must run before `LocalPunctuationFormatter`, which turns any remaining
///   "vírgula" into ",". "uma vírgula" (the punctuation noun) and
///   "vírgula dois pontos" (spoken comma + colon) are never decimals.
///
/// Deliberately skipped: ordinals ("primeiro lugar" is prose), times and
/// halves ("às três e meia", "quinze para as três" stay as spoken because
/// "duas horas" can be a duration or a clock time), "ponto" as a decimal
/// mark (it is the spoken period command), hyphenated words ("sete-léguas"),
/// and capitalized number words in mid-sentence, which are usually proper
/// nouns ("Rua Sete de Setembro", "Três Corações").
enum PortugueseNumberFormatter {
    static let defaultsKey = "portugueseNumberFormattingEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    static func apply(to text: String, language: String) -> String {
        guard isEnabled,
              language.lowercased().hasPrefix("pt"),
              DictationFormattingProfile.selected != .literal
        else {
            return text
        }
        return format(text)
    }

    // MARK: - Vocabulary (diacritic-folded, lowercase)

    private static let units: [String: Int] = [
        "zero": 0, "um": 1, "uma": 1, "dois": 2, "duas": 2, "tres": 3, "quatro": 4,
        "cinco": 5, "seis": 6, "sete": 7, "oito": 8, "nove": 9,
    ]
    private static let teens: [String: Int] = [
        "dez": 10, "onze": 11, "doze": 12, "treze": 13, "catorze": 14, "quatorze": 14,
        "quinze": 15, "dezesseis": 16, "dezasseis": 16, "dezessete": 17, "dezassete": 17,
        "dezoito": 18, "dezenove": 19, "dezanove": 19,
    ]
    private static let tens: [String: Int] = [
        "vinte": 20, "trinta": 30, "quarenta": 40, "cinquenta": 50, "sessenta": 60,
        "setenta": 70, "oitenta": 80, "noventa": 90,
    ]
    private static let hundreds: [String: Int] = [
        "cem": 100, "cento": 100,
        "duzentos": 200, "duzentas": 200, "trezentos": 300, "trezentas": 300,
        "quatrocentos": 400, "quatrocentas": 400, "quinhentos": 500, "quinhentas": 500,
        "seiscentos": 600, "seiscentas": 600, "setecentos": 700, "setecentas": 700,
        "oitocentos": 800, "oitocentas": 800, "novecentos": 900, "novecentas": 900,
    ]
    private static let feminineWords: Set<String> = [
        "uma", "duas", "duzentas", "trezentas", "quatrocentas", "quinhentas",
        "seiscentas", "setecentas", "oitocentas", "novecentas",
    ]

    private struct Scale {
        let singular: String
        let plural: String
        let value: Int
    }

    private static let scales = [
        Scale(singular: "bilhão", plural: "bilhões", value: 1_000_000_000),
        Scale(singular: "milhão", plural: "milhões", value: 1_000_000),
    ]
    private static let scaleWords: [String: Int] = [
        "bilhao": 1_000_000_000, "bilhoes": 1_000_000_000,
        "milhao": 1_000_000, "milhoes": 1_000_000,
    ]

    private static let currencies: [String: String] = [
        "real": "R$", "reais": "R$", "dolar": "US$", "dolares": "US$", "euro": "€", "euros": "€",
    ]
    private static let measurementUnits: Set<String> = [
        "centavo", "centavos",
        "quilo", "quilos", "quilograma", "quilogramas", "kg", "grama", "gramas",
        "metro", "metros", "quilometro", "quilometros", "km", "centimetro", "centimetros",
        "milimetro", "milimetros", "litro", "litros", "mililitro", "mililitros",
        "grau", "graus", "polegada", "polegadas",
        "megabyte", "megabytes", "gigabyte", "gigabytes", "terabyte", "terabytes",
    ]

    // MARK: - Tokens

    private struct Token {
        let range: Range<String.Index>
        let text: String
        let folded: String
        /// The gap from the previous token is plain spaces (no punctuation or
        /// line break), so the two may belong to one spoken number.
        let linkedToPrevious: Bool
        let isCapitalizedMidSentence: Bool
        let followsSymbol: Bool
    }

    private static let tokenRegex = try? NSRegularExpression(
        pattern: #"[\p{L}\p{M}\p{N}]+(?:[-'’.,][\p{L}\p{M}\p{N}]+)*"#)
    private static let digitRegex = try? NSRegularExpression(
        pattern: #"^(?:\d{1,3}(?:\.\d{3})+|\d+)(?:,\d+)?$"#)

    private static func tokenize(_ text: String) -> [Token] {
        guard let tokenRegex else { return [] }
        var tokens: [Token] = []
        var previousEnd = text.startIndex
        for match in tokenRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let word = String(text[range])
            let gap = text[previousEnd..<range.lowerBound]
            let linked = !tokens.isEmpty && !gap.isEmpty && gap.allSatisfy { $0 == " " || $0 == "\t" }
            let lastVisible = gap.last { !($0 == " " || $0 == "\t") }
            let atSentenceStart: Bool
            if let lastVisible {
                atSentenceStart = ".!?…:\n\r\"“'‘([•-–—".contains(lastVisible)
            } else {
                atSentenceStart = tokens.isEmpty
            }
            let capitalized = word.first?.isUppercase == true && !atSentenceStart
            tokens.append(Token(
                range: range,
                text: word,
                folded: word.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "pt_BR")),
                linkedToPrevious: linked,
                isCapitalizedMidSentence: capitalized,
                followsSymbol: lastVisible.map { "$€".contains($0) } ?? false
            ))
            previousEnd = range.upperBound
        }
        return tokens
    }

    // MARK: - Parsing

    private struct Parsed {
        var value: Int
        var end: Int
        /// Set when the number is a whole multiple of a scale ("dois milhões").
        var scaleMultiplier: Int?
        var scale: Scale?
        var half = false
    }

    private struct Parser {
        let tokens: [Token]

        func word(_ index: Int) -> String? {
            index < tokens.count ? tokens[index].folded : nil
        }

        /// The token at `index` exists and continues the spoken phrase.
        func linked(_ index: Int) -> Bool {
            index < tokens.count && tokens[index].linkedToPrevious
        }

        func connector(_ index: Int) -> Bool {
            linked(index) && tokens[index].text == "e"
        }

        func isNumberWord(_ index: Int) -> Bool {
            guard let w = word(index) else { return false }
            return units[w] != nil || teens[w] != nil || tens[w] != nil || hundreds[w] != nil
                || w == "mil" || scaleWords[w] != nil
        }

        /// 0...999, e.g. "trezentos e quarenta e dois".
        func group(_ i: Int) -> (value: Int, end: Int)? {
            guard let w = word(i) else { return nil }
            if let h = hundreds[w] {
                if w == "cem" { return (100, i + 1) }
                if connector(i + 1), let t = belowHundred(i + 2) { return (h + t.value, t.end) }
                return w == "cento" ? nil : (h, i + 1)
            }
            return belowHundred(i)
        }

        func belowHundred(_ i: Int) -> (value: Int, end: Int)? {
            guard let w = word(i) else { return nil }
            if let t = tens[w] {
                if connector(i + 1), linked(i + 2), let u = word(i + 2).flatMap({ units[$0] }), u > 0 {
                    return (t + u, i + 3)
                }
                return (t, i + 1)
            }
            if let v = teens[w] ?? units[w] { return (v, i + 1) }
            return nil
        }

        /// 0...999_999, e.g. "dois mil e vinte e seis", "mil novecentos".
        func belowMillion(_ i: Int) -> (value: Int, end: Int)? {
            var value: Int
            var j: Int
            if word(i) == "mil" {
                value = 1000
                j = i + 1
            } else {
                guard let g = group(i) else { return nil }
                guard linked(g.end), word(g.end) == "mil" else { return g }
                value = g.value * 1000
                j = g.end + 1
            }
            if connector(j), linked(j + 1), let r = group(j + 1) {
                return (value + r.value, r.end)
            }
            if linked(j), let r = group(j) {
                return (value + r.value, r.end)
            }
            return (value, j)
        }

        func number(_ i: Int, below maxScale: Int = .max) -> Parsed? {
            for scale in scales where scale.value < maxScale {
                guard let g = group(i), linked(g.end),
                      let w = word(g.end), scaleWords[w] == scale.value, g.value > 0
                else { continue }
                let head = g.value * scale.value
                let end = g.end + 1
                if connector(end), linked(end + 1), word(end + 1) == "meio" {
                    return Parsed(value: head, end: end + 2, scaleMultiplier: g.value, scale: scale, half: true)
                }
                if connector(end), linked(end + 1), let r = number(end + 1, below: scale.value) {
                    return Parsed(value: head + r.value, end: r.end)
                }
                if linked(end), let r = number(end, below: scale.value) {
                    return Parsed(value: head + r.value, end: r.end)
                }
                return Parsed(value: head, end: end, scaleMultiplier: g.value, scale: scale)
            }
            guard let r = belowMillion(i) else { return nil }
            return Parsed(value: r.value, end: r.end)
        }
    }

    // MARK: - Formatting

    private static func isDigitToken(_ text: String) -> Bool {
        guard let digitRegex else { return false }
        return digitRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func format(_ text: String) -> String {
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return text }
        let parser = Parser(tokens: tokens)
        var replacements: [(Range<String.Index>, String)] = []
        var i = 0

        while i < tokens.count {
            if let (replacement, end) = convert(at: i, parser: parser) {
                let range = tokens[i].range.lowerBound..<tokens[end - 1].range.upperBound
                replacements.append((range, replacement))
                i = end
            } else {
                i += 1
            }
        }

        var result = text
        for (range, replacement) in replacements.reversed() {
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    /// Returns the written form and the index after the last consumed token,
    /// or nil to leave the token at `i` untouched.
    private static func convert(at i: Int, parser p: Parser) -> (String, Int)? {
        let token = p.tokens[i]
        let isDigits = isDigitToken(token.text)
        let parsed: Parsed?
        if isDigits {
            parsed = nil
        } else {
            guard p.isNumberWord(i), !token.isCapitalizedMidSentence else { return nil }
            parsed = p.number(i)
            guard parsed != nil else { return nil }
        }
        var index = isDigits ? i + 1 : parsed!.end
        let wordCount = (i..<index).filter { p.tokens[$0].text != "e" }.count

        // Halves and clock-style phrases stay as spoken.
        if p.connector(index), p.linked(index + 1),
           ["meia", "meio"].contains(p.word(index + 1) ?? "") {
            return nil
        }
        if isQuarterToPhrase(at: index, parser: p) { return nil }

        // Integer part as text.
        let integerText: String
        if isDigits {
            integerText = token.text
        } else if let parsed, let scale = parsed.scale, let multiplier = parsed.scaleMultiplier {
            let name = multiplier == 1 ? scale.singular : scale.plural
            integerText = "\(grouped(multiplier))\(parsed.half ? ",5" : "") \(name)"
        } else {
            integerText = grouped(parsed!.value)
        }
        let isScaled = parsed?.scale != nil

        // Decimal: "três vírgula cinco".
        var decimalText: String?
        if !isScaled, !isDigits, !continuesSpokenList(at: i, parser: p),
           p.linked(index), p.word(index) == "virgula",
           !(wordCount == 1 && p.word(i) == "uma"),
           let fraction = fractionDigits(at: index + 1, parser: p) {
            decimalText = "\(integerText),\(fraction.digits)"
            index = fraction.end
        }
        let numberText = decimalText ?? integerText

        // Percent.
        if p.linked(index), p.word(index) == "por", p.linked(index + 1), p.word(index + 1) == "cento" {
            return ("\(numberText)%", index + 2)
        }
        if p.linked(index), p.word(index) == "porcento" {
            return ("\(numberText)%", index + 1)
        }

        // Currency.
        var currencyIndex = index
        if isScaled, p.linked(index), p.word(index) == "de" { currencyIndex = index + 1 }
        if p.linked(currencyIndex), let symbol = p.word(currencyIndex).flatMap({ currencies[$0] }),
           !token.followsSymbol {
            var amount = numberText
            var end = currencyIndex + 1
            if let decimalText {
                amount = paddedCents(decimalText)
            } else if !isScaled, let cents = centavos(at: end, parser: p) {
                amount = "\(integerText),\(cents.text)"
                end = cents.end
            }
            return ("\(symbol) \(amount)", end)
        }

        guard !isDigits else { return nil }

        let followedByUnit = p.linked(index) && measurementUnits.contains(p.word(index) ?? "")
        if decimalText != nil || followedByUnit {
            return (numberText, index)
        }

        // Standalone cardinal.
        let parsedValue = parsed!.value
        let isLoneSmallWord = wordCount == 1 && (parsedValue <= 10 || p.word(i) == "mil")
        guard !isLoneSmallWord else { return nil }

        let isFeminine = (i..<index).contains { feminineWords.contains(p.tokens[$0].folded) }
        if !isScaled, !isFeminine, (1900...2100).contains(parsedValue) {
            return (String(parsedValue), index)
        }
        return (numberText, index)
    }

    /// "quinze para as três" is a clock time; leave it spoken.
    private static func isQuarterToPhrase(at index: Int, parser p: Parser) -> Bool {
        guard p.linked(index), let w = p.word(index) else { return false }
        if ["pras", "pra", "pro"].contains(w) {
            return p.linked(index + 1) && p.isNumberWord(index + 1)
        }
        if w == "para", p.linked(index + 1), ["as", "a", "o"].contains(p.word(index + 1) ?? "") {
            return p.linked(index + 2) && p.isNumberWord(index + 2)
        }
        return false
    }

    /// "um vírgula dois vírgula três": the number at `i` follows a spoken
    /// comma after another number, so it is a list item, not a decimal.
    private static func continuesSpokenList(at i: Int, parser p: Parser) -> Bool {
        guard i >= 2, p.linked(i), p.word(i - 1) == "virgula", p.linked(i - 1) else { return false }
        return p.isNumberWord(i - 2) || isDigitToken(p.tokens[i - 2].text)
    }

    private static func fractionDigits(at i: Int, parser p: Parser) -> (digits: String, end: Int)? {
        guard p.linked(i) else { return nil }
        if isDigitToken(p.tokens[i].text), !p.tokens[i].text.contains(",") {
            return (p.tokens[i].text.replacingOccurrences(of: ".", with: ""), i + 1)
        }
        guard p.isNumberWord(i), !p.tokens[i].isCapitalizedMidSentence,
              let parsed = p.number(i), parsed.scale == nil
        else { return nil }
        // "vírgula dois pontos" is a spoken comma followed by a colon.
        if p.word(i) == "dois", p.linked(i + 1), ["ponto", "pontos"].contains(p.word(i + 1) ?? "") {
            return nil
        }
        let fraction = singleDigitRun(at: i, parsed: parsed, parser: p)
        // "um vírgula dois vírgula três" is a spoken list, not a decimal.
        if p.linked(fraction.end), p.word(fraction.end) == "virgula",
           p.linked(fraction.end + 1), p.isNumberWord(fraction.end + 1) || isDigitToken(p.tokens[fraction.end + 1].text) {
            return nil
        }
        return fraction
    }

    private static func singleDigitRun(at i: Int, parsed: Parsed, parser p: Parser) -> (digits: String, end: Int) {
        // A run of single digits: "um vírgula zero cinco" → "1,05".
        if parsed.end == i + 1, let first = units[p.word(i) ?? ""] {
            var digits = String(first)
            var end = i + 1
            while p.linked(end), p.tokens[end].text != "e",
                  let next = units[p.word(end) ?? ""], !p.tokens[end].isCapitalizedMidSentence {
                digits += String(next)
                end += 1
            }
            return (digits, end)
        }
        return (String(parsed.value), parsed.end)
    }

    /// "e cinquenta centavos" after a currency amount.
    private static func centavos(at i: Int, parser p: Parser) -> (text: String, end: Int)? {
        guard p.connector(i), p.linked(i + 1) else { return nil }
        let value: Int
        let end: Int
        if isDigitToken(p.tokens[i + 1].text), let v = Int(p.tokens[i + 1].text) {
            value = v
            end = i + 2
        } else if p.isNumberWord(i + 1), let parsed = p.number(i + 1), parsed.scale == nil {
            value = parsed.value
            end = parsed.end
        } else {
            return nil
        }
        guard (0..<100).contains(value), p.linked(end),
              ["centavo", "centavos"].contains(p.word(end) ?? "")
        else { return nil }
        return (value < 10 ? "0\(value)" : String(value), end + 1)
    }

    /// "3,5" reais → "3,50".
    private static func paddedCents(_ decimal: String) -> String {
        guard let comma = decimal.lastIndex(of: ","),
              decimal[decimal.index(after: comma)...].count == 1
        else { return decimal }
        return decimal + "0"
    }

    private static func grouped(_ value: Int) -> String {
        let digits = String(value)
        guard digits.count > 3 else { return digits }
        var result = ""
        for (offset, character) in digits.enumerated() {
            if offset > 0, (digits.count - offset) % 3 == 0 { result.append(".") }
            result.append(character)
        }
        return result
    }
}
