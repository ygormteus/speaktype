import XCTest
@testable import speaktype

@MainActor
final class MeetingSummaryServiceTests: XCTestCase {
    private func fixture() throws -> (MeetingStore, MeetingManifest, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = MeetingStore(root: root)
        var meeting = try store.create(title: "Equipe", language: "pt", mode: .inPerson)
        var segment = MeetingAudioSegment(source: .microphone, start: 0, end: 10)
        segment.transcript = "Decidimos lançar o projeto amanhã."
        segment.state = .completed
        meeting.segments = [segment]
        meeting.endedAt = Date()
        meeting.state = .completed
        try store.update(meeting)
        return (store, meeting, root)
    }

    func testCloudProviderIsNotCalledBeforeConsent() async throws {
        let (store, meeting, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeSummaryProvider(cloud: true)
        do {
            _ = try await MeetingSummaryService(store: store).generate(meetingID: meeting.id, provider: provider, consent: nil)
            XCTFail("Expected consent gate")
        } catch {}
        XCTAssertEqual(provider.calls, 0)
        XCTAssertEqual(store.meeting(meeting.id)?.summaryState, .absent)
    }

    func testRejectsInvalidSummaryAndUnknownSegmentReferences() throws {
        let unknown = MeetingSummaryItem(text: "Decisão inventada", segmentIDs: [UUID()])
        let summary = MeetingSummary(overview: [unknown], topics: [], decisions: [], pending: [], tasks: [])
        XCTAssertThrowsError(try MeetingSummaryService.validate(summary, evidence: [UUID(): "Texto real"]))
    }

    func testRejectsOwnerNotMentionedInCitedTranscript() throws {
        let id = UUID()
        let task = MeetingSummaryItem(text: "Lançar projeto", segmentIDs: [id], owner: "Pessoa inventada")
        let summary = MeetingSummary(overview: [task], topics: [], decisions: [], pending: [], tasks: [])
        XCTAssertThrowsError(try MeetingSummaryService.validate(summary, evidence: [id: "Decidimos lançar amanhã."]))
    }

    func testSuccessfulSummaryPersistsIndependentlyOfTranscription() async throws {
        let (store, meeting, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeSummaryProvider(cloud: false)
        let result = try await MeetingSummaryService(store: store).generate(meetingID: meeting.id, provider: provider, consent: nil)
        XCTAssertEqual(result.overview.first?.segmentIDs, [meeting.segments[0].id])
        XCTAssertEqual(store.meeting(meeting.id)?.summaryState, .ready)
        XCTAssertEqual(store.meeting(meeting.id)?.segments, meeting.segments)
    }

    func testCancellationKeepsTranscriptAndAllowsRetry() async throws {
        let (store, meeting, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeSummaryProvider(cloud: false)
        provider.cancel = true
        do {
            _ = try await MeetingSummaryService(store: store).generate(meetingID: meeting.id, provider: provider, consent: nil)
            XCTFail("Expected cancellation")
        } catch {}
        XCTAssertEqual(store.meeting(meeting.id)?.summaryState, .failed)
        XCTAssertEqual(store.meeting(meeting.id)?.segments, meeting.segments)
    }

    func testMatchingConsentAllowsTextSummaryAndStaleConsentIsRejected() async throws {
        let (store, meeting, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeSummaryProvider(cloud: true)
        let service = MeetingSummaryService(store: store)
        let consent = try service.cloudConsent(for: meeting.id, provider: provider)
        _ = try await service.generate(meetingID: meeting.id, provider: provider, consent: consent)
        XCTAssertEqual(provider.calls, 1)
        var changed = try XCTUnwrap(store.meeting(meeting.id))
        changed.segments[0].transcript = "Conteúdo alterado depois da confirmação."
        try store.update(changed)
        do {
            _ = try await service.generate(meetingID: meeting.id, provider: provider, consent: consent)
            XCTFail("Stale consent must not authorize another transcript")
        } catch {}
        XCTAssertEqual(provider.calls, 1)
    }

    func testLongTranscriptIsSummarizedInBlocksThenConsolidated() async throws {
        let (store, meeting, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var longer = meeting
        longer.segments[0].transcript = String(repeating: "Decidimos lançar o projeto. ", count: 120)
        try store.update(longer)
        let provider = FakeSummaryProvider(cloud: false)
        provider.inputLimit = 1000
        _ = try await MeetingSummaryService(store: store).generate(meetingID: meeting.id, provider: provider, consent: nil)
        XCTAssertGreaterThan(provider.calls, 2)
        XCTAssertTrue(provider.didConsolidate)
    }

    func testCloudPayloadContainsTextAndDoesNotContainAudioOrKey() throws {
        let provider = OpenAISummaryProvider(readKey: { "private-test-key" })
        let input = MeetingSummaryRequest(language: "pt", documents: [MeetingSummaryDocument(segmentIDs: [UUID()], text: "Texto da reunião")], isConsolidation: false)
        let request = try provider.makeRequest(input)
        let data = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(payload["store"] as? Bool, false)
        XCTAssertNil(payload["audio"])
        XCTAssertTrue((payload["input"] as? String)?.contains("Texto da reunião") == true)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-test-key"))
        XCTAssertEqual(request.url?.host, "api.openai.com")
    }

    func testMalformedAndIncompleteCloudResponsesAreRejected() throws {
        XCTAssertThrowsError(try OpenAISummaryProvider.decodeResponse(Data("not-json".utf8)))
        let incomplete = Data(#"{"status":"incomplete","output":[]}"#.utf8)
        XCTAssertThrowsError(try OpenAISummaryProvider.decodeResponse(incomplete))
        let malformed = Data(#"{"status":"completed","output":[{"content":[{"type":"output_text","text":"invalid-summary"}]}]}"#.utf8)
        XCTAssertThrowsError(try OpenAISummaryProvider.decodeResponse(malformed))
    }
}

@MainActor
private final class FakeSummaryProvider: MeetingSummaryProvider {
    let isCloud: Bool
    let id = "test"
    let name = "Test"
    var inputLimit = 3500
    var calls = 0
    var cancel = false
    var didConsolidate = false
    init(cloud: Bool) { isCloud = cloud }
    func summarize(_ request: MeetingSummaryRequest) async throws -> MeetingSummary {
        calls += 1
        didConsolidate = didConsolidate || request.isConsolidation
        if cancel { throw CancellationError() }
        let item = MeetingSummaryItem(text: "A equipe decidiu lançar o projeto.", segmentIDs: request.documents[0].segmentIDs)
        return MeetingSummary(overview: [item], topics: [], decisions: [], pending: [], tasks: [])
    }
}
