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

    func testJoinKeepsRepeatsAtPauseSeamsAndSkipsEmpty() {
        XCTAssertEqual(
            TranscriptSeam.join(["Eu acho que sim.", "", "Sim, com certeza.", "  Você pode?"]),
            "Eu acho que sim. Sim, com certeza. Você pode?")
        XCTAssertEqual(TranscriptSeam.join([]), "")
        XCTAssertEqual(TranscriptSeam.join(["", " "]), "")
    }

    func testJoinDeduplicatesOnlyAfterForcedCuts() {
        // Chunk 0 ended at a forced cut; chunk 2 follows a pause.
        XCTAssertEqual(
            TranscriptSeam.join(
                ["Olá, hoje vamos testar", "testar o ditado.", "Ditado é bom."],
                deduplicatingAfter: [0]),
            "Olá, hoje vamos testar o ditado. Ditado é bom.")
        // A forced cut whose next chunk is silent: the following text comes
        // after a pause, so it is kept as is.
        XCTAssertEqual(
            TranscriptSeam.join(["vamos testar", "", "testar de novo"], deduplicatingAfter: [0]),
            "vamos testar testar de novo")
    }

    func testAccumulatorKeepsRepeatedWordsAcrossChunks() async {
        let accumulator = IncrementalTranscriptAccumulator()
        await accumulator.append("Eu acho que sim.")
        let text = await accumulator.append("Sim, com certeza.")
        XCTAssertEqual(text, "Eu acho que sim. Sim, com certeza.")
    }
}
