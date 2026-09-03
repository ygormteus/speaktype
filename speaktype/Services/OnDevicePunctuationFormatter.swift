import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Uses Apple's system language model as an optional local formatting pass.
/// The response is accepted exclusively when it preserves every word in order,
/// so the model can never silently rewrite the user's dictation.
enum OnDevicePunctuationFormatter {
    static let defaultsKey = "onDevicePunctuationEnabled"
    static let automaticCommitDefaultsKey = "onDeviceFormattingBeforeAutoPaste"
    private static let reviewBeforeAutoPasteDefaultsKey = "reviewBeforeAutoPaste"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    /// Keep the normal hotkey path instantaneous. The system model is allowed
    /// when the user opens the review editor, or when they explicitly choose
    /// the higher-quality (and potentially slower) automatic-commit mode.
    static var shouldRunForCurrentCommit: Bool {
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: reviewBeforeAutoPasteDefaultsKey)
            || defaults.bool(forKey: automaticCommitDefaultsKey)
    }

    static func apply(to text: String, language: String) async -> String? {
        guard isEnabled,
              shouldRunForCurrentCommit,
              DictationFormattingProfile.selected != .literal,
              DictationFormattingProfile.selected != .code,
              text.contains(where: \.isWhitespace),
              text.count <= 1_500,
              !looksLikeStructuredValue(text)
        else {
            return nil
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return await applyWithSystemModel(to: text, language: language)
        }
        #endif
        return nil
    }

    /// Exposed for tests and as a hard gate before the generated text reaches
    /// the clipboard. Case, whitespace and punctuation may change; words and
    /// numbers may not.
    static func preservesOnlyFormatting(original: String, candidate: String) -> Bool {
        contentTokens(in: original) == contentTokens(in: candidate)
    }

    private static func contentTokens(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func looksLikeStructuredValue(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("@") || trimmed.contains("://") || trimmed.hasPrefix("www.")
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func applyWithSystemModel(to text: String, language: String) async -> String? {
        guard case .available = SystemLanguageModel.default.availability else {
            return nil
        }

        let instructions = """
        You format a speech transcript according to the selected local profile.
        Preserve every word, number, order, and meaning exactly. Do not add,
        remove, substitute, translate, summarize, explain, or quote anything.
        Return only the formatted transcript. Use the transcript's language;
        Brazilian Portuguese questions must end in a question mark when their
        wording and intent indicate a question.
        """
        let session = LanguageModelSession(instructions: instructions)

        do {
            let response = try await session.respond(
                to: """
                Language hint: \(language)
                Profile: \(profileInstruction(for: DictationFormattingProfile.selected))

                Transcript:
                \(text)
                """
            )
            let candidate = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty, preservesOnlyFormatting(original: text, candidate: candidate) else {
                return nil
            }
            return candidate
        } catch {
            print("On-device formatting unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    @available(macOS 26.0, *)
    private static func profileInstruction(for profile: DictationFormattingProfile) -> String {
        switch profile {
        case .smart:
            "Use natural punctuation, capitalization, and paragraphs where the spoken thought changes."
        case .message:
            "Format as a concise chat message. Use short paragraphs only when they improve readability."
        case .email:
            "Format as an email body. Use readable paragraphs, but do not invent a subject, greeting, closing, or signature."
        case .notes:
            "Format as notes. You may use a bullet character (•) for separate ideas, but never add headings or label words."
        case .literal, .code:
            "Do not format this profile."
        }
    }
    #endif
}
