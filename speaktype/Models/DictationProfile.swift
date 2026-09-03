import Foundation

/// A complete, local-only configuration for a common dictation workflow.
///
/// Profiles never download or switch to an unavailable model. When their
/// preferred model is already installed, it is selected; otherwise the user's
/// current model remains active and the profile still applies its safe text
/// and language settings.
enum DictationProfile: String, CaseIterable, Identifiable {
    case quick
    case portugueseNatural
    case precise
    case technical
    case meeting

    static let defaultsKey = "selectedDictationProfile"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quick: String(localized: "Quick")
        case .portugueseNatural: String(localized: "Natural Portuguese")
        case .precise: String(localized: "High accuracy")
        case .technical: String(localized: "Technical")
        case .meeting: String(localized: "Meeting")
        }
    }

    var detail: String {
        switch self {
        case .quick: String(localized: "Prioritizes immediate dictation and a fast model when available.")
        case .portugueseNatural: String(localized: "Portuguese punctuation and natural messages, optimized for daily use.")
        case .precise: String(localized: "Prioritizes the most accurate installed model and a review step.")
        case .technical: String(localized: "Preserves technical terms, symbols and exact phrasing.")
        case .meeting: String(localized: "Creates clear paragraphs for longer notes and meeting follow-ups.")
        }
    }

    var icon: String {
        switch self {
        case .quick: "bolt.fill"
        case .portugueseNatural: "text.bubble.fill"
        case .precise: "target"
        case .technical: "chevron.left.forwardslash.chevron.right"
        case .meeting: "person.2.fill"
        }
    }

    var language: String {
        switch self {
        case .portugueseNatural: "pt"
        default: "auto"
        }
    }

    var formattingProfile: DictationFormattingProfile {
        switch self {
        case .quick, .portugueseNatural, .precise: .smart
        case .technical: .code
        case .meeting: .notes
        }
    }

    var preferredModelVariant: String {
        switch self {
        case .quick: ParakeetCatalog.v3Variant
        case .portugueseNatural: NemotronCatalog.balancedVariant
        case .precise, .meeting: "openai_whisper-large-v3_turbo"
        case .technical: ParakeetCatalog.v3Variant
        }
    }

    var reviewBeforeAutoPaste: Bool { self == .precise || self == .meeting }

    /// Applies a profile to durable local preferences. Returns whether the
    /// profile's preferred model was already downloaded and could be selected.
    @discardableResult
    func apply() -> Bool {
        let defaults = UserDefaults.standard
        defaults.set(rawValue, forKey: Self.defaultsKey)
        defaults.set(language, forKey: "transcriptionLanguage")
        defaults.set(formattingProfile.rawValue, forKey: DictationFormattingProfile.defaultsKey)
        defaults.set(reviewBeforeAutoPaste, forKey: "reviewBeforeAutoPaste")
        defaults.set(true, forKey: LocalPunctuationFormatter.spokenPunctuationDefaultsKey)
        defaults.set(true, forKey: LocalPunctuationFormatter.terminalPunctuationDefaultsKey)

        guard ModelDownloadService.shared.isDownloaded(preferredModelVariant) else { return false }
        defaults.set(preferredModelVariant, forKey: ModelSelection.defaultsKey)
        TranscriptionManager.shared.warmUp(variant: preferredModelVariant)
        return true
    }
}
