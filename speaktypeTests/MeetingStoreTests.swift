import AVFoundation
import XCTest
@testable import speaktype

@MainActor
final class MeetingStoreTests: XCTestCase {
    private var root: URL!
    private var store: MeetingStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = MeetingStore(root: root)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCreateAndReloadPreservesMeetingMetadata() throws {
        let meeting = try store.create(title: "Planejamento", language: "pt", mode: .inPerson)
        let restored = MeetingStore(root: root)
        XCTAssertEqual(restored.items.first?.id, meeting.id)
        XCTAssertEqual(restored.items.first?.title, "Planejamento")
        XCTAssertEqual(restored.items.first?.schemaVersion, 1)
    }

    func testRecoveryMarksOpenMeetingInterruptedAndKeepsClosedSegments() throws {
        var meeting = try store.create(title: "Reunião", language: "pt", mode: .online)
        meeting.state = .recording
        try store.update(meeting)
        let segment = MeetingAudioSegment(source: .microphone, start: 0, end: 12)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let writer = try AVAudioFile(forWriting: store.audioURL(segment, meetingID: meeting.id), settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        try writer.write(from: buffer)
        try store.appendSegment(segment, for: meeting.id)
        let recovered = try store.recoverInterruptedMeetings()
        XCTAssertEqual(recovered.first?.state, .interrupted)
        XCTAssertEqual(recovered.first?.segments.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(segment, meetingID: meeting.id).path))
    }

    func testCorruptMeetingDoesNotHideOtherMeetings() throws {
        let good = try store.create(title: "Preservada", language: "pt", mode: .inPerson)
        let bad = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("invalid json".utf8).write(to: bad.appendingPathComponent("manifest.json"))
        let restored = MeetingStore(root: root)
        XCTAssertEqual(restored.items.map(\.id), [good.id])
        XCTAssertEqual(restored.unreadableMeetingCount, 1)
    }

    func testDeleteMeetingOnlyRemovesItsOwnDirectory() throws {
        let first = try store.create(title: "Primeira", language: "pt", mode: .inPerson)
        let second = try store.create(title: "Segunda", language: "pt", mode: .inPerson)
        try store.deleteMeeting(first.id)
        XCTAssertEqual(store.items.map(\.id), [second.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(first.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory(second.id).path))
    }

    func testFailedWriteLeavesPreviousManifestReadable() throws {
        var meeting = try store.create(title: "Original", language: "pt", mode: .inPerson)
        meeting.title = "Alterada"
        let blocked = store.directory(meeting.id).appendingPathComponent("manifest.json")
        let original = try Data(contentsOf: blocked)
        let failingStore = MeetingStore(root: root, writeData: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        XCTAssertThrowsError(try failingStore.update(meeting))
        XCTAssertEqual(try Data(contentsOf: blocked), original)
        XCTAssertEqual(store.items.first?.title, "Original")
    }

    func testInterruptedSummaryDoesNotMarkCompletedCaptureInterrupted() throws {
        var meeting = try store.create(title: "Concluída", language: "pt", mode: .inPerson)
        meeting.state = .completed
        meeting.endedAt = Date()
        meeting.summaryState = .generating
        try store.update(meeting)
        try store.recoverInterruptedMeetings()
        XCTAssertEqual(store.meeting(meeting.id)?.state, .completed)
        XCTAssertEqual(store.meeting(meeting.id)?.summaryState, .failed)
    }

    func testDuplicateSegmentIDsAreRejectedBeforePersistence() throws {
        var meeting = try store.create(title: "Inválida", language: "pt", mode: .inPerson)
        let segment = MeetingAudioSegment(source: .microphone, start: 0, end: 1)
        meeting.segments = [segment, segment]
        XCTAssertThrowsError(try store.update(meeting))
        XCTAssertTrue(store.meeting(meeting.id)?.segments.isEmpty == true)
    }

    func testRecoveryImportsOrphanJournalsAfterSourceFailure() throws {
        for state in [MeetingState.interrupted, .failed] {
            var meeting = try store.create(title: "Órfã", language: "pt", mode: .online)
            meeting.state = state
            try store.update(meeting)
            let segment = MeetingAudioSegment(source: .system, start: 12, end: 13)
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            var writer: AVAudioFile? = try AVAudioFile(forWriting: store.audioURL(segment, meetingID: meeting.id), settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
            buffer.frameLength = 160
            try writer?.write(from: buffer)
            writer = nil
            let journal = store.directory(meeting.id).appendingPathComponent(segment.id.uuidString + ".segment.json")
            try JSONEncoder().encode(segment).write(to: journal)
            try store.recoverInterruptedMeetings()
            XCTAssertEqual(store.meeting(meeting.id)?.segments.map(\.id), [segment.id])
        }
    }

    func testManualAudioReconciliationDoesNotInterruptOtherSummary() throws {
        var first = try store.create(title: "Resumindo", language: "pt", mode: .inPerson)
        first.state = .completed
        first.summaryState = .generating
        try store.update(first)
        let second = try store.create(title: "Recuperando", language: "pt", mode: .inPerson)
        try store.reconcileSegments(for: second.id)
        XCTAssertEqual(store.meeting(first.id)?.summaryState, .generating)
    }
}
