import Foundation

/// The local presentation style applied after speech recognition. These modes
/// never call a network service or invent content; they only apply explicit,
/// deterministic cleanup rules chosen by the user.
enum DictationFormattingProfile: String, CaseIterable, Identifiable {
    case literal
    case smart
    case message
    case email
    case notes
    case code

    static let defaultsKey = "dictationFormattingProfile"

    var id: String { rawValue }

    static var selected: DictationFormattingProfile {
        guard let stored = UserDefaults.standard.string(forKey: defaultsKey),
              let profile = DictationFormattingProfile(rawValue: stored)
        else {
            return .smart
        }
        return profile
    }

    var displayName: String {
        switch self {
        case .literal: String(localized: "Literal")
        case .smart: String(localized: "Smart dictation")
        case .message: String(localized: "Message")
        case .email: String(localized: "Email")
        case .notes: String(localized: "Notes")
        case .code: String(localized: "Code")
        }
    }

    var detail: String {
        switch self {
        case .literal: String(localized: "Keep the transcript as recognized")
        case .smart: String(localized: "Clean spacing and sentence starts")
        case .message: String(localized: "Natural text for chats and messages")
        case .email: String(localized: "Clear paragraphs for email dictation")
        case .notes: String(localized: "Turn spoken item commands into bullets")
        case .code: String(localized: "Preserve symbols and technical text")
        }
    }
}
