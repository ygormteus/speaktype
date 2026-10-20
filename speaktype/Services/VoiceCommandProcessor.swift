import Foundation

/// Deterministic local editing commands recognized in a completed dictation.
/// Commands only operate on the current transcript; they never inspect another
/// app, send text away, or trigger automation such as a paste by themselves.
enum VoiceCommandProcessor {
    static let defaultsKey = "voiceCommandsEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    static func apply(to text: String, language: String) -> String {
        guard isEnabled, !text.isEmpty else { return text }

        var result = text
        result = result.replacingOccurrences(
            of: #"(?i)\b(?:novo parágrafo|novo paragrafo|new paragraph)\b[,.;:!?…]?\s*"#,
            with: "\n\n", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"(?i)\b(?:nova linha|new line)\b[,.;:!?…]?\s*"#,
            with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"(?i)\b(?:novo item|próximo item|proximo item|new item|next item)\b[,.;:!?…]?\s*"#,
            with: "\n• ", options: .regularExpression)

        // Destructive voice operations need an explicit command prefix, so a
        // person can still dictate the words naturally in ordinary prose.
        // Earlier stages may already have capitalized the command and closed
        // it with a terminal mark ("Comando limpar texto."), so that is allowed.
        let clearPattern = #"(?i)\b(?:comando\s+)?(?:limpar texto|clear text)\b\s*[.!?…]*\s*$"#
        if result.range(of: clearPattern, options: .regularExpression) != nil {
            return ""
        }
        let deletePattern = #"(?i)\b(?:comando\s+)?(?:apagar última frase|apagar ultima frase|delete last sentence)\b\s*[.!?…]*\s*$"#
        if let range = result.range(of: deletePattern, options: .regularExpression) {
            result.removeSubrange(range)
            result = removingLastSentence(from: result)
        }

        result = result.replacingOccurrences(of: #" *\n *"#, with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removingLastSentence(from text: String) -> String {
        // The final sentence may or may not carry its own terminal mark
        // ("Primeira. Segunda." / "primeira. segunda"); drop it first, then
        // keep everything up to and including the previous sentence's mark.
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = trimmed.last, ".!?…".contains(last) || last.isWhitespace {
            trimmed.removeLast()
        }
        guard let boundary = trimmed.lastIndex(where: { ".!?…\n".contains($0) }) else { return "" }
        let kept = trimmed[boundary] == "\n" ? trimmed[..<boundary] : trimmed[...boundary]
        return String(kept).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
