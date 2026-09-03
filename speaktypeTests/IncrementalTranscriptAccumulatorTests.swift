import XCTest
@testable import speaktype

final class IncrementalTranscriptAccumulatorTests: XCTestCase {
    func testAccumulatorPreservesChunkOrderAndDropsImmediateDuplicates() async {
        let accumulator = IncrementalTranscriptAccumulator()

        let first = await accumulator.append("Olá")
        XCTAssertEqual(first, "Olá")
        let second = await accumulator.append("mundo")
        XCTAssertEqual(second, "Olá mundo")
        let duplicate = await accumulator.append("mundo")
        XCTAssertEqual(duplicate, "Olá mundo")
        await accumulator.reset()
        let empty = await accumulator.transcript
        XCTAssertEqual(empty, "")
    }
}
