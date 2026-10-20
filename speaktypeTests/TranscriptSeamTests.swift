import XCTest
@testable import speaktype

final class TranscriptSeamTests: XCTestCase {
    func testDropsRepeatedWordsAtBoundary() {
        XCTAssertEqual(
            TranscriptSeam.removingBoundaryRepeat(
                previous: "vamos testar o ditado", next: "o ditado em português"),
            "em português")
        XCTAssertEqual(
            TranscriptSeam.removingBoundaryRepeat(
                previous: "me envie o relatório amanhã", next: "o relatório amanhã cedo"),
            "cedo")
        XCTAssertEqual(
            TranscriptSeam.removingBoundaryRepeat(previous: "enviar o relatório", next: "relatório amanhã"),
            "amanhã")
    }

    func testComparisonIgnoresCaseDiacriticsAndPunctuation() {
        XCTAssertEqual(
            TranscriptSeam.removingBoundaryRepeat(previous: "Vamos testar o ditado.", next: "Ditado em portugues"),
            "em portugues")
        XCTAssertEqual(
            TranscriptSeam.removingBoundaryRepeat(previous: "falei de Português,", next: "portugues: e mais"),
            "e mais")
    }

    func testLongestMatchWins() {
        XCTAssertEqual(
            TranscriptSeam.removingBoundaryRepeat(previous: "isso isso isso", next: "isso isso isso agora"),
            "agora")
    }

    func testKeepsTextWithoutOverlap() {
        XCTAssertEqual(
            TranscriptSeam.removingBoundaryRepeat(previous: "Olá, hoje vamos", next: "  testar o ditado "),
            "testar o ditado")
        // Only matches at the seam itself, not words elsewhere.
        XCTAssertEqual(
            TranscriptSeam.removingBoundaryRepeat(previous: "o ditado funciona", next: "o ditado de novo"),
            "o ditado de novo")
    }

    func testShortSingleWordsAreNotDeduplicated() {
        XCTAssertEqual(TranscriptSeam.removingBoundaryRepeat(previous: "pão e", next: "e leite"), "e leite")
        XCTAssertEqual(TranscriptSeam.removingBoundaryRepeat(previous: "isso é", next: "é verdade"), "é verdade")
        // …but count inside a multi-word match.
        XCTAssertEqual(TranscriptSeam.removingBoundaryRepeat(previous: "disse que é", next: "que é verdade"), "verdade")
    }

    func testHandlesEmptyInputs() {
        XCTAssertEqual(TranscriptSeam.removingBoundaryRepeat(previous: "", next: "olá mundo"), "olá mundo")
        XCTAssertEqual(TranscriptSeam.removingBoundaryRepeat(previous: "olá", next: ""), "")
        XCTAssertEqual(TranscriptSeam.removingBoundaryRepeat(previous: "mundo", next: "mundo"), "")
    }

    func testJoinStitchesChunksInOrderAndSkipsEmpty() {
        XCTAssertEqual(
            TranscriptSeam.join(["Olá, hoje vamos testar", "", "testar o ditado.", "  Você pode?"]),
            "Olá, hoje vamos testar o ditado. Você pode?")
        XCTAssertEqual(TranscriptSeam.join([]), "")
        XCTAssertEqual(TranscriptSeam.join(["", " "]), "")
    }

    func testAccumulatorUsesSeamDeduplication() async {
        let accumulator = IncrementalTranscriptAccumulator()
        await accumulator.append("vamos testar o ditado")
        let text = await accumulator.append("o ditado em português")
        XCTAssertEqual(text, "vamos testar o ditado em português")
    }
}
