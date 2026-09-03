import Foundation

/// A conservative, fully offline formatting layer for completed transcripts.
/// It intentionally has no model or network dependency: user-selected rules
/// are deterministic and can be reviewed before auto-paste.
enum LocalTranscriptFormatter {
    static func apply(to text: String, language: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if UserDefaults.standard.bool(forKey: "enableAutoEdit") {
            result = removingFillerWords(from: result, language: language)
        }

        switch DictationFormattingProfile.selected {
        case .literal, .code:
            return result
        case .smart:
            return capitalizingSentenceStarts(in: result)
        case .message:
            return formattingProse(result)
        case .email:
            return formattingEmail(result)
        case .notes:
            return formattingNotes(result)
        }
    }

    private static func removingFillerWords(from text: String, language: String) -> String {
        // "um" is a Portuguese article/number, so it is intentionally not
        // removed for pt-BR. The small set below is unambiguous across the
        // currently supported dictation languages.
        let pattern = #"(?i)(^|[\s,.;:!?])(?:uh+|umm+|uhm+|erm+|hmm+)(?=$|[\s,.;:!?])[,.;:!?]?"#
        var result = text.replacingOccurrences(of: pattern, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formattingProse(_ text: String) -> String {
        let withBreaks = applyingSpokenBreaks(to: text)
        return capitalizingSentenceStarts(in: withBreaks)
    }

    private static func formattingNotes(_ text: String) -> String {
        var result = applyingSpokenBreaks(to: text)
        result = result.replacingOccurrences(
            of: #"(?i)\b(?:novo item|próximo item|proximo item|new item|next item)\b\s*"#,
            with: "\n• ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(of: #" *\n *"#, with: "\n", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if !result.hasPrefix("• "), !result.isEmpty {
            result = "• \(result)"
        }
        return capitalizingSentenceStarts(in: result)
    }

    private static func formattingEmail(_ text: String) -> String {
        let formatted = formattingProse(text)
        let paragraphs = formatted.components(separatedBy: "\n\n")
        guard let firstParagraph = paragraphs.first,
              firstParagraph.lowercased().hasPrefix("assunto ")
        else {
            return formatted
        }

        let subject = String(firstParagraph.dropFirst("assunto ".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty else { return formatted }
        let body = paragraphs.dropFirst().joined(separator: "\n\n")
        return body.isEmpty ? "Assunto: \(subject)" : "Assunto: \(subject)\n\n\(body)"
    }

    private static func applyingSpokenBreaks(to text: String) -> String {
        var result = text.replacingOccurrences(
            of: #"(?i)\b(?:novo parágrafo|novo paragrafo|new paragraph)\b\s*"#,
            with: "\n\n",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?i)\b(?:nova linha|new line)\b\s*"#,
            with: "\n",
            options: .regularExpression
        )
        result = result.replacingOccurrences(of: #" *\n *"#, with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func capitalizingSentenceStarts(in text: String) -> String {
        var result = ""
        var capitalizeNextLetter = true
        var sawSentenceTerminator = false

        for character in text {
            if capitalizeNextLetter, character.isLetter {
                result += String(character).uppercased()
                capitalizeNextLetter = false
                sawSentenceTerminator = false
                continue
            }

            result.append(character)
            if character == "\n" {
                capitalizeNextLetter = true
                sawSentenceTerminator = false
            } else if character == "." || character == "!" || character == "?" {
                sawSentenceTerminator = true
            } else if sawSentenceTerminator, character.isWhitespace {
                capitalizeNextLetter = true
                sawSentenceTerminator = false
            } else if !character.isWhitespace {
                sawSentenceTerminator = false
            }
        }
        return result
    }
}
