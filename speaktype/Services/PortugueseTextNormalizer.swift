import Foundation

/// Conservative final cleanup for Brazilian Portuguese output. Vocabulary and
/// names remain under the user's Dictionary rules; this only fixes punctuation
/// artifacts that ASR engines commonly emit.
enum PortugueseTextNormalizer {
    static func apply(to text: String, language: String) -> String {
        guard language.lowercased().hasPrefix("pt") else { return text }
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        result = replacing(#"\s+([,.;:!?])"#, with: "$1", in: result)
        // Preserve an intentional ellipsis, but collapse accidental 4+ periods.
        result = replacing(#"\.{4,}"#, with: "…", in: result)
        result = replacing(#"([!?])\1{2,}"#, with: "$1", in: result)
        return result
    }

    private static func replacing(_ pattern: String, with replacement: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
    }
}
