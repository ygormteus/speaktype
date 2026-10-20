import XCTest
@testable import speaktype

@MainActor
final class LocalMeetingSummaryIntegrationTests: XCTestCase {
    func testPortugueseLocalSummaryWithRealModel() async throws {
        guard let path = ProcessInfo.processInfo.environment["SPEAKTYPE_LOCAL_SUMMARY_REPORT"] else {
            throw XCTSkip("Opt-in on-device summary integration check")
        }
        let provider = LocalMeetingSummaryProvider()
        if let reason = provider.unavailability(language: "pt") { throw XCTSkip(reason) }
        let texts = [
            "Testando, testando. Um, dois, três, quatro. Um, dois, três, quatro.",
            "1, 2, 3, 4, 2, 3, 4.", "Testando 1, 2, 3. Testando 1, 2, 3.",
            "Um, dois, três, quatro.", "Um, dois, três. Um, dois, três.",
            "E aí", "E aí", "Testando, testando, testando dois, três."
        ]
        let documents = texts.map { MeetingSummaryDocument(segmentIDs: [UUID()], text: $0) }
        let evidence = Dictionary(uniqueKeysWithValues: documents.map { ($0.segmentIDs[0], $0.text) })
        let request = MeetingSummaryRequest(language: "pt", documents: documents, isConsolidation: false)
        let started = Date()
        var report: [String: Any] = [:]
        do {
            let summary = try await provider.summarize(request)
            report["summary"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(summary))
            report["unknownReferenceCount"] = summary.allItems.flatMap(\.segmentIDs).filter { evidence[$0] == nil }.count
            report["unsupportedMetadataCount"] = summary.allItems.reduce(0) { count, item in
                let source = item.segmentIDs.compactMap { evidence[$0] }.joined(separator: " ")
                return count + [item.owner, item.deadline].compactMap { $0 }.filter {
                    !$0.isEmpty && source.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) == nil
                }.count
            }
            try MeetingSummaryService.validate(summary, evidence: evidence)
            XCTAssertFalse(summary.overview.isEmpty)
            XCTAssertTrue(summary.tasks.isEmpty)
            XCTAssertTrue(summary.decisions.isEmpty)
            report["validated"] = true
        } catch {
            report["error"] = String(describing: error)
            report["elapsedSeconds"] = Date().timeIntervalSince(started)
            try JSONSerialization.data(withJSONObject: report, options: .prettyPrinted).write(to: URL(fileURLWithPath: path))
            throw error
        }
        report["elapsedSeconds"] = Date().timeIntervalSince(started)
        try JSONSerialization.data(withJSONObject: report, options: .prettyPrinted).write(to: URL(fileURLWithPath: path))
    }
}
