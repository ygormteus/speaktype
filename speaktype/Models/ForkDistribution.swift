import Foundation

/// Identity and distribution policy for this independently maintained beta.
/// Keep the existing bundle identifier for now: changing it would make macOS
/// request Microphone and Accessibility permissions again and isolate local data.
enum ForkDistribution {
    static let maintainer = "Ygor Mateus"
    static let sourceRepositoryURL = URL(string: "https://github.com/ygormteus/speaktype")!
    static let automaticUpdatesEnabled = false

}
