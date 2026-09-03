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
            of: #"\s+([,.;:!?])"#,
            with: "$1",
            options: .regularExpression
        )
        if isTerminalPunctuationEnabled {
            result = addingTerminalPunctuationIfNeeded(to: result, language: language)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacingSpokenPunctuation(in text: String) -> String {
        let replacements: [(String, String)] = [
            (#"(?i)\b(?:ponto de interrogação|ponto de interrogacao|question mark)\b"#, "?"),
            (#"(?i)\b(?:ponto de exclamação|ponto de exclamacao|exclamation mark)\b"#, "!"),
            (#"(?i)\b(?:ponto e vírgula|ponto e virgula|semicolon)\b"#, ";"),
            (#"(?i)\b(?:dois pontos|colon)\b"#, ":"),
            (#"(?i)\b(?:ponto final|full stop|period)\b"#, "."),
            (#"(?i)\b(?:vírgula|virgula|comma)\b"#, ","),
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

    private static func isLikelyQuestion(_ text: String, language: String) -> Bool {
        let firstLine = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? text
        let lowercase = firstLine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let prefixes: [String]
        if language.lowercased().hasPrefix("pt") {
            prefixes = [
                "como ", "quando ", "onde ", "quem ", "qual ", "quais ", "quanto ",
                "por que ", "será que ", "sera que ", "você pode ", "voce pode ", "pode "
            ]
        } else {
            prefixes = ["how ", "when ", "where ", "who ", "what ", "which ", "why ", "can you ", "could you "]
        }
        return prefixes.contains { lowercase.hasPrefix($0) }
    }
}
