import Foundation

/// Deterministic punctuation for dictation. It supports explicit spoken
/// punctuation and only infers a final mark when a complete prose sentence is
/// clearly missing one. This avoids an opaque rewrite model while making the
/// streaming engine pleasant to use in Portuguese.
enum LocalPunctuationFormatter {
    static let spokenPunctuationDefaultsKey = "spokenPunctuationEnabled"
    static let terminalPunctuationDefaultsKey = "automaticTerminalPunctuation"

    static var isSpokenPunctuationEnabled: Bool {
        UserDefaults.standard.object(forKey: spokenPunctuationDefaultsKey) as? Bool ?? true
    }

    static var isTerminalPunctuationEnabled: Bool {
        UserDefaults.standard.object(forKey: terminalPunctuationDefaultsKey) as? Bool ?? true
    }

    static func apply(to text: String, language: String) -> String {
        guard DictationFormattingProfile.selected != .literal,
              DictationFormattingProfile.selected != .code
        else {
            return text
        }

        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isSpokenPunctuationEnabled {
            result = replacingSpokenPunctuation(in: result)
        }
        result = result.replacingOccurrences(
            of: #"[ \t]+([,.;:!?…])"#,
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(of: #"[ \t]*\n[ \t]*"#, with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        if isTerminalPunctuationEnabled {
            result = addingTerminalPunctuationIfNeeded(to: result, language: language)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Words that, right before "ponto", make it a noun ("o ponto", "um
    /// ponto", "no ponto") rather than a spoken period.
    private static let pontoNounContext =
        "o|um|ao|no|do|pelo|num|esse|este|nesse|neste|desse|deste|aquele|naquele|daquele|"
        + "mesmo|outro|bom|meu|seu|teu|nosso|cada|algum|nenhum|qualquer|tal|último|ultimo|"
        + "primeiro|próximo|proximo|segundo|único|unico|em|de|a|até|ate|sem|com|por|pra|para|"
        + "é|e|ou|que|mais|menos|the|a|an|one|this|that|my|your"

    /// Words that follow a non-technical "ponto com" ("um ponto com o
    /// cliente", "alinhar um ponto com você").
    private static let pontoComProseFollowers =
        "o|a|os|as|ele|ela|eles|elas|você|voce|vocês|voces|todos|todas|meu|minha|seu|sua|"
        + "nosso|nossa|um|uma|isso|esse|essa|este|esta|aquele|aquela|the|you|him|her|them"

    private static func replacingSpokenPunctuation(in text: String) -> String {
        let nounContext = pontoNounContext
        let followers = pontoComProseFollowers
        // Order matters: longer phrases that contain "ponto" must run before
        // the shorter ones and before the bare final "ponto" rule.
        let replacements: [(String, String)] = [
            (#"(?i)[ \t]*\bponto\s+par[áa]grafo\b\s*"#, ".\n\n"),
            (#"(?i)\b(?:ponto de interrogação|ponto de interrogacao|question mark)\b"#, "?"),
            (#"(?i)\b(?:ponto de exclamação|ponto de exclamacao|exclamation mark)\b"#, "!"),
            (#"(?i)\b(?:ponto e vírgula|ponto e virgula|semicolon)\b"#, ";"),
            // Spoken domains are joined to the previous token. A domain is
            // never written after a determiner nor followed by a pronoun or
            // article, which keeps "um ponto com o cliente" as prose.
            (
                #"(?i)(?<=[\p{L}\p{N}])(?<!\b(?:um|uma|o|esse|este|aquele|outro|mesmo|cada|algum|nenhum|qualquer|último|ultimo|meu|seu|nosso|teu|único|unico|bom|the|a|an))\s+(?:ponto|dot)\s+com\s+(?:ponto|dot)\s+br\b"#,
                ".com.br"
            ),
            (
                #"(?i)(?<=[\p{L}\p{N}])(?<!\b(?:um|uma|o|esse|este|aquele|outro|mesmo|cada|algum|nenhum|qualquer|último|ultimo|meu|seu|nosso|teu|único|unico|bom|the|a|an))\s+(?:ponto|dot)\s+com\b(?!\s+(?:"#
                    + followers + #")\b)"#,
                ".com"
            ),
            (#"(?i)\b(?:dois pontos|colon)\b"#, ":"),
            (#"(?i)\b(?:ponto final|full stop|period)\b"#, "."),
            (#"(?i)\b(?:vírgula|virgula|comma)\b"#, ","),
            (#"(?i)[ \t]*\b(?:retic[êe]ncias|ellipsis)\b"#, "…"),
            // Opening marks keep the space before and drop the one after;
            // closing marks drop the space before them.
            (#"(?i)\s*\b(?:(?:abre|abrir)\s+par[êe]nteses?|open\s+paren(?:thesis)?)\b\s*"#, " ("),
            (#"(?i)\s*\b(?:(?:fecha|fechar)\s+par[êe]nteses?|close\s+paren(?:thesis)?)\b"#, ")"),
            (#"(?i)\s*\b(?:(?:abre|abrir)\s+aspas|open\s+quotes?)\b\s*"#, " \""),
            (#"(?i)\s*\b(?:(?:fecha|fechar)\s+aspas|close\s+quotes?|end\s+quotes?|unquote)\b"#, "\""),
            (#"(?i)[ \t]*\b(?:travess[ãa]o|em dash)\b[ \t]*"#, " — "),
            // Joined marks need a real token on both sides. Prose uses of the
            // word ("o hífen de guarda-chuva", "uma arroba de carne") are kept.
            (
                #"(?i)(?<=[\p{L}\p{N}])(?<!\b(?:o|um|com|sem|de|do|no|pelo|esse|este|the|a|with|without))\s+(?:h[íi]fen|hyphen)\s+(?!(?:de|do|da|e|é|ou|que)\b)(?=[\p{L}\p{N}])"#,
                "-"
            ),
            (
                #"(?i)(?<=[\p{L}\p{N}._\-])(?<!\b(?:uma|meia|cada|por|a)|\b\d{1,6})\s+arroba\s+(?!(?:de|do|da|dos|das)\b)(?=[\p{L}\p{N}])"#,
                "@"
            ),
            // "barra" is an everyday word ("barra de chocolate", "segura a
            // barra"), so it only becomes "/" between two numbers ("10 barra 5").
            (#"(?i)(?<=\d)\s+(?:barra|slash)\s+(?=\d)"#, "/"),
            // A bare "ponto" is usually a noun ("ponto de ônibus", "esse é o
            // ponto"). It only means "." as the final word of the dictation
            // and when it does not follow a determiner or preposition.
            (#"(?i)(?<=\p{L})(?<!\b(?:"# + nounContext + #"))\s+ponto\s*$"#, "."),
        ]

        return replacements.reduce(text) { partial, replacement in
            partial.replacingOccurrences(
                of: replacement.0,
                with: replacement.1,
                options: .regularExpression
            )
        }
    }

    private static func addingTerminalPunctuationIfNeeded(to text: String, language: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 2,
              trimmed.contains(where: \.isWhitespace),
              let finalCharacter = trimmed.last,
              !".!?…:;)\"”'".contains(finalCharacter)
        else {
            return trimmed
        }

        return trimmed + (isLikelyQuestion(trimmed, language: language) ? "?" : ".")
    }

    /// The sentence the inferred mark will close: the text after the user's
    /// last explicit terminal mark or line break. No new boundaries are made.
    private static func finalSentence(of text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"[.!?…]+\s+|\n"#) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        guard let last = regex.matches(in: text, range: range).last,
              let boundary = Range(last.range, in: text)
        else {
            return text
        }
        return String(text[boundary.upperBound...])
    }

    private static func isLikelyQuestion(_ text: String, language: String) -> Bool {
        let leadingNoise = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "\"“”'(—–-•"))
        let sentence = finalSentence(of: text)
            .trimmingCharacters(in: leadingNoise)
            .lowercased()

        if language.lowercased().hasPrefix("pt") {
            return isLikelyPortugueseQuestion(sentence)
        }
        let prefixes = ["how ", "when ", "where ", "who ", "what ", "which ", "why ", "can you ", "could you "]
        let tags = [", right", ", isn't it", ", aren't you", ", don't you"]
        return prefixes.contains { sentence.hasPrefix($0) } || tags.contains { sentence.hasSuffix($0) }
    }

    private static func isLikelyPortugueseQuestion(_ sentence: String) -> Bool {
        // Tag questions turn any statement into a question.
        let tags = [
            ", né", " né", ", certo", ", tá bom", ", ta bom", ", beleza", ", ok",
            ", não é", ", nao é", ", nao e",
        ]
        if tags.contains(where: { sentence.hasSuffix($0) }) {
            return true
        }

        // "como" also opens comparisons and asides; "como assim" stays a question.
        let statementOpeners = [
            "como eu disse", "como eu falei", "como disse", "como falei", "como já disse",
            "como ja disse", "como já falei", "como ja falei", "como sempre", "como combinado",
            "como de costume", "como esperado", "como mencionado", "como prometido",
            "como você sabe", "como voce sabe", "como vocês sabem", "como voces sabem",
        ]
        if statementOpeners.contains(where: { sentence.hasPrefix($0) }) {
            return false
        }
        // "o que importa é isso" is a statement; "o que é isso" is not.
        if sentence.hasPrefix("o que "),
           sentence.range(
               of: #"^o que (?:\S+ ){1,5}(?:é|foi|era|são|sao)\s+\S"#,
               options: .regularExpression) != nil {
            return false
        }
        // A purpose clause followed by a comma: "para que todos entendam, ...".
        if sentence.hasPrefix("para que ") || sentence.hasPrefix("pra que "),
           sentence.contains(",") {
            return false
        }

        // "vocês " alone is too broad ("vocês fizeram um ótimo trabalho"), so
        // only verbs that typically open a question are listed.
        let prefixes = [
            "como ", "quando ", "onde ", "quem ", "qual ", "quais ", "quanto ", "quantos ",
            "quantas ", "por que ", "por quê", "será que ", "sera que ", "você pode ",
            "voce pode ", "pode ", "o que ", "o quê", "que horas", "cadê ", "cade ",
            "tem como ", "dá pra ", "da pra ", "dá para ", "da para ", "posso ", "podemos ",
            "poderia ", "você sabe ", "voce sabe ", "vocês podem ", "voces podem ",
            "vocês sabem ", "voces sabem ", "vocês acham ", "voces acham ", "vocês querem ",
            "voces querem ", "vocês vão ", "voces vao ", "e se ", "não seria ", "nao seria ",
            "pra que ", "para que ",
        ]
        return prefixes.contains { sentence.hasPrefix($0) }
    }
}
