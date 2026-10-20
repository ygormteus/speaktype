import Foundation

enum MeetingModelSelection {
    static let defaultsKey = "meetingTranscriptionModelVariant"
    static let fastPortugueseVariant = "freds0_distil-whisper-large-v3-ptbr"
    static let fidelityVariant = "openai_whisper-large-v3_turbo"

    static func models(language: String, downloaded: Set<String>) -> [AIModel] {
        AIModel.availableModels.filter {
            $0.engine == .whisper && !$0.isEnglishOnly && $0.supports(spokenLanguage: language)
                && downloaded.contains($0.variant)
        }
    }

    static func resolvedVariant(preferred: String, language: String, downloaded: Set<String>) -> String {
        let available = models(language: language, downloaded: downloaded)
        return available.first(where: { $0.variant == preferred })?.variant ?? available.first?.variant ?? ""
    }

    static func title(for model: AIModel) -> String {
        switch model.variant {
        case fastPortugueseVariant: return String(localized: "Fast PT-BR (experimental)") + " · " + model.name
        case fidelityVariant: return String(localized: "Higher fidelity") + " · " + model.name
        default: return model.name
        }
    }
}
