import XCTest

@testable import speaktype

final class OnDevicePunctuationFormatterTests: XCTestCase {
    func testAllowsOnlyPunctuationAndCapitalizationChanges() {
        XCTAssertTrue(
            OnDevicePunctuationFormatter.preservesOnlyFormatting(
                original: "quando vamos marcar a reunião amanhã",
                candidate: "Quando vamos marcar a reunião amanhã?"
            )
        )
    }

    func testRejectsAddedOrChangedWords() {
        XCTAssertFalse(
            OnDevicePunctuationFormatter.preservesOnlyFormatting(
                original: "vamos marcar amanhã",
                candidate: "Vamos marcar a reunião amanhã."
            )
        )
        XCTAssertFalse(
            OnDevicePunctuationFormatter.preservesOnlyFormatting(
                original: "quando vamos marcar",
                candidate: "Quando podemos marcar?"
            )
        )
    }

    func testOnDeviceFormattingDefaultsToReviewOnlyForFastCommits() {
        let defaults = UserDefaults.standard
        let automaticKey = OnDevicePunctuationFormatter.automaticCommitDefaultsKey
        let reviewKey = "reviewBeforeAutoPaste"
        let previousAutomatic = defaults.object(forKey: automaticKey)
        let previousReview = defaults.object(forKey: reviewKey)
        defer {
            restore(previousAutomatic, key: automaticKey, defaults: defaults)
            restore(previousReview, key: reviewKey, defaults: defaults)
        }

        defaults.removeObject(forKey: automaticKey)
        defaults.set(false, forKey: reviewKey)
        XCTAssertFalse(OnDevicePunctuationFormatter.shouldRunForCurrentCommit)

        defaults.set(true, forKey: reviewKey)
        XCTAssertTrue(OnDevicePunctuationFormatter.shouldRunForCurrentCommit)

        defaults.set(false, forKey: reviewKey)
        defaults.set(true, forKey: automaticKey)
        XCTAssertTrue(OnDevicePunctuationFormatter.shouldRunForCurrentCommit)
    }

    private func restore(_ value: Any?, key: String, defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
