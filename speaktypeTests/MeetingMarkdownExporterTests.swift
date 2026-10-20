import XCTest
@testable import speaktype

final class MeetingMarkdownExporterTests: XCTestCase {
    func testExportIncludesCitedTranscriptWithoutExecutableMarkup() {
        var meeting = MeetingManifest(title: "Planejamento", language: "pt", mode: .inPerson)
        var segment = MeetingAudioSegment(source: .microphone, start: 15, end: 30)
        segment.transcript = "![imagem](https://example.test/private) <script>"
        segment.state = .completed
        meeting.segments = [segment]
        meeting.summary = MeetingSummary(overview: [MeetingSummaryItem(text: "Planejamento do projeto", segmentIDs: [segment.id])], topics: [], decisions: [], pending: [], tasks: [])
        let markdown = MeetingMarkdownExporter.render(meeting)
        XCTAssertTrue(markdown.contains("00:00:15"))
        XCTAssertTrue(markdown.contains("Planejamento do projeto"))
        XCTAssertFalse(markdown.contains("![imagem]"))
        XCTAssertFalse(markdown.contains("<script>"))
        XCTAssertFalse(markdown.contains(".wav"))
    }

    func testTimestampHandlesInvalidAndVeryLargeValues() {
        XCTAssertEqual(MeetingMarkdownExporter.timestamp(.infinity), "00:00:00")
        XCTAssertEqual(MeetingMarkdownExporter.timestamp(-10), "00:00:00")
        XCTAssertFalse(MeetingMarkdownExporter.timestamp(Double.greatestFiniteMagnitude).isEmpty)
    }
}
