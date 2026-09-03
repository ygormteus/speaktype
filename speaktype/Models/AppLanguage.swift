import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case portugueseBrazil
    case english

    static let defaultsKey = "appLanguage"

    var id: String { rawValue }

    var locale: Locale? {
        switch self {
        case .system: nil
        case .portugueseBrazil: Locale(identifier: "pt-BR")
        case .english: Locale(identifier: "en")
        }
    }

    var displayName: String {
        switch self {
        case .system: String(localized: "Follow System")
        case .portugueseBrazil: "Português (Brasil)"
        case .english: "English"
        }
    }
}
