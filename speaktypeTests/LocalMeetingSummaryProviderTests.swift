import XCTest
@testable import speaktype

@MainActor
final class LocalMeetingSummaryProviderTests: XCTestCase {
    func testLocalPromptUsesShortDocumentIndicesInsteadOfUUIDs() throws {
        let id = UUID()
        let request = MeetingSummaryRequest(language: "pt", documents: [MeetingSummaryDocument(segmentIDs: [id], text: "Texto de teste")], isConsolidation: false)
        let prompt = try LocalMeetingSummaryProvider.encodedPrompt(request)
        XCTAssertFalse(prompt.contains(id.uuidString))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(prompt.utf8)) as? [String: Any])
        let documents = try XCTUnwrap(payload["documents"] as? [[String: Any]])
        XCTAssertEqual(documents[0]["index"] as? Int, 0)
        XCTAssertEqual(documents[0]["text"] as? String, "Texto de teste")
        XCTAssertEqual(payload["language"] as? String, "pt")
    }

    func testDocumentIndicesResolveAllConsolidatedSourcesAndRejectUnknownIndices() throws {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let documents = [MeetingSummaryDocument(segmentIDs: [first, second], text: "Síntese"), MeetingSummaryDocument(segmentIDs: [third, first], text: "Outra síntese")]
        XCTAssertEqual(try LocalMeetingSummaryProvider.sourceIDs(for: [1, 0, 1], documents: documents), [third, first, second])
        for indices in [[], [-1], [2], [0, 999]] {
            XCTAssertThrowsError(try LocalMeetingSummaryProvider.sourceIDs(for: indices, documents: documents))
        }
    }

    func testLiteralNullMetadataIsOmittedWithoutDiscardingCitedSummary() throws {
        let id = UUID()
        let summary = MeetingSummary(overview: [MeetingSummaryItem(text: "Teste de áudio com contagem.", segmentIDs: [id], owner: "null", deadline: "null")], topics: [], decisions: [], pending: [], tasks: [])
        let documents = [MeetingSummaryDocument(segmentIDs: [id], text: "Testando um, dois, três.")]
        let grounded = LocalMeetingSummaryProvider.normalized(summary)
        XCTAssertNil(grounded.overview[0].owner)
        XCTAssertNil(grounded.overview[0].deadline)
        XCTAssertEqual(grounded.overview[0].text, summary.overview[0].text)
        XCTAssertEqual(grounded.overview[0].segmentIDs, [id])
        XCTAssertNoThrow(try MeetingSummaryService.validate(grounded, evidence: [id: documents[0].text]))
    }

    func testRealMetadataIsPreservedAndUnsupportedNamesStillFailValidation() {
        let cited = UUID()
        let other = UUID()
        let documents = [MeetingSummaryDocument(segmentIDs: [cited], text: "Márcia fará a revisão amanhã."), MeetingSummaryDocument(segmentIDs: [other], text: "Pedro entregará sexta-feira.")]
        let supported = MeetingSummaryItem(text: "Revisar", segmentIDs: [cited], owner: "Márcia", deadline: "amanhã")
        let unsupported = MeetingSummaryItem(text: "Outra revisão", segmentIDs: [cited], owner: "Pedro", deadline: "sexta-feira")
        let summary = MeetingSummary(overview: [supported], topics: [], decisions: [], pending: [], tasks: [unsupported])
        let grounded = LocalMeetingSummaryProvider.normalized(summary)
        XCTAssertEqual(grounded.overview[0].owner, "Márcia")
        XCTAssertEqual(grounded.overview[0].deadline, "amanhã")
        XCTAssertEqual(grounded.tasks[0].owner, "Pedro")
        XCTAssertEqual(grounded.tasks[0].deadline, "sexta-feira")
        XCTAssertThrowsError(try MeetingSummaryService.validate(grounded, evidence: [cited: documents[0].text, other: documents[1].text]))
    }

    func testGroundingDoesNotAcceptUnknownReferences() {
        let id = UUID()
        let unknown = UUID()
        let summary = MeetingSummary(overview: [MeetingSummaryItem(text: "Visão geral", segmentIDs: [unknown])], topics: [], decisions: [], pending: [], tasks: [])
        let grounded = LocalMeetingSummaryProvider.normalized(summary)
        XCTAssertThrowsError(try MeetingSummaryService.validate(grounded, evidence: [id: "Fonte"]))
    }

    func testRepeatedReferencesAreDeduplicatedInSourceOrder() throws {
        let first = UUID()
        let second = UUID()
        let item = MeetingSummaryItem(text: "Teste de áudio", segmentIDs: [first, second, first, second])
        let summary = MeetingSummary(overview: [item], topics: [item], decisions: [item], pending: [item], tasks: [item])
        let normalized = LocalMeetingSummaryProvider.normalized(summary)
        for result in normalized.allItems {
            XCTAssertEqual(result.segmentIDs, [first, second])
        }
        XCTAssertNoThrow(try MeetingSummaryService.validate(normalized, evidence: [first: "Teste", second: "de áudio"]))
    }

    func testWhitespacePlaceholdersAreOmittedButActualNameNullIsPreserved() throws {
        let id = UUID()
        let item = MeetingSummaryItem(text: "Revisão", segmentIDs: [id], owner: "Null", deadline: " \n")
        let summary = MeetingSummary(overview: [item], topics: [], decisions: [], pending: [], tasks: [])
        let normalized = LocalMeetingSummaryProvider.normalized(summary)
        XCTAssertEqual(normalized.overview[0].owner, "Null")
        XCTAssertNil(normalized.overview[0].deadline)
        XCTAssertNoThrow(try MeetingSummaryService.validate(normalized, evidence: [id: "Null fará a revisão."]))
    }
}
