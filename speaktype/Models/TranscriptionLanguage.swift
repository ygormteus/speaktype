import Foundation

/// Spoken-language preference shared by every recorder surface.
enum TranscriptionLanguage {
    static let defaultsKey = "transcriptionLanguage"
    static let automatic = "auto"

    /// Registers the fallback used until the user picks a language explicitly.
    /// A fixed language skips Whisper's detection pass and stops short
    /// Portuguese clips from being misdetected as Spanish or Galician, so a
    /// Portuguese Mac starts in "pt". An explicit choice (including "auto")
    /// is stored in the app domain and always wins over this registration.
    static func registerDefault(
        in defaults: UserDefaults = .standard,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) {
        defaults.register(defaults: [
            defaultsKey: defaultCode(
                appLanguage: defaults.string(forKey: AppLanguage.defaultsKey),
                preferredLanguages: preferredLanguages
            )
        ])
    }

    static func defaultCode(appLanguage: String?, preferredLanguages: [String]) -> String {
        switch appLanguage.flatMap(AppLanguage.init(rawValue:)) {
        case .portugueseBrazil:
            return "pt"
        case .english:
            return automatic
        case .system, nil:
            let primary = preferredLanguages.first?.lowercased() ?? ""
            return primary.hasPrefix("pt") ? "pt" : automatic
        }
    }
}
