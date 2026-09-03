import XCTest
@testable import speaktype

final class PortugueseTextNormalizerTests: XCTestCase {
    func testPortugueseNormalizesSpacingAndAccidentalRepeatedPunctuation() {
        XCTAssertEqual(
            PortugueseTextNormalizer.apply(to: "Olá , mundo....", language: "pt-BR"),
            "Olá, mundo…"
        )
    }

    func testOtherLanguagesAreLeftUntouched() {
        XCTAssertEqual(
            PortugueseTextNormalizer.apply(to: "Hello....", language: "en"),
            "Hello...."
        )
    }
}
