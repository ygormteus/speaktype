import XCTest
@testable import speaktype

@MainActor
final class MeetingTranscriptionQueueTests: XCTestCase {
    func testStorageFailureDoesNotReplayAbandonedJobsInAnotherSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var failNextWrite = false
        let store = MeetingStore(root: root, writeData: { data, url in
            if failNextWrite { failNextWrite = false; throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        })
        let first = try store.create(title: "Falha", language: "pt", mode: .inPerson)
        let second = try store.create(title: "Nova sessão", language: "pt", mode: .inPerson)
        let segments = (0..<3).map { MeetingAudioSegment(source: .microphone, start: Double($0), end: Double($0 + 1)) }
        for (index, segment) in segments.enumerated() {
            let id = index < 2 ? first.id : second.id
            try Data([1]).write(to: store.audioURL(segment, meetingID: id))
            try store.appendSegment(segment, for: id)
        }
        let started = expectation(description: "First decode started")
        var finish: CheckedContinuation<Void, Never>?
        var decoded: [String] = []
        let queue = MeetingTranscriptionQueue(store: store, transcribe: { url, _, _ in
            decoded.append(url.lastPathComponent)
            if decoded.count == 1 {
                await withCheckedContinuation { continuation in finish = continuation; started.fulfill() }
                failNextWrite = true
            }
            return "Texto"
        })
        queue.enqueue(meetingID: first.id)
        await fulfillment(of: [started], timeout: 2)
        queue.enqueue(meetingID: first.id)
        finish?.resume()
        await queue.waitUntilIdle()
        queue.enqueue(meetingID: second.id)
        await queue.waitUntilIdle()
        XCTAssertEqual(decoded, [segments[0].fileName, segments[2].fileName])
        XCTAssertEqual(store.meeting(first.id)?.segments[1].state, .pending)
    }

    func testMusicSymbolsDoNotBecomeSpeech() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let meeting = try store.create(title: "Sem fala", language: "pt", mode: .inPerson)
        let segment = MeetingAudioSegment(source: .microphone, start: 0, end: 1)
        try Data([1]).write(to: store.audioURL(segment, meetingID: meeting.id))
        try store.appendSegment(segment, for: meeting.id)
        let queue = MeetingTranscriptionQueue(store: store, transcribe: { _, _, _ in "♪ ♫" })
        queue.enqueue(meetingID: meeting.id)
        await queue.waitUntilIdle()
        XCTAssertEqual(store.meeting(meeting.id)?.segments.first?.transcript, "")
    }

    func testFirstTranscriptWriteFailureTriggersStorageFailureEvenIfNextWriteWorks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var failNextWrite = false
        let store = MeetingStore(root: root, writeData: { data, url in
            if failNextWrite { failNextWrite = false; throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        })
        let meeting = try store.create(title: "Disco", language: "pt", mode: .inPerson)
        let segment = MeetingAudioSegment(source: .microphone, start: 0, end: 1)
        try Data([1]).write(to: store.audioURL(segment, meetingID: meeting.id))
        try store.appendSegment(segment, for: meeting.id)
        let queue = MeetingTranscriptionQueue(store: store, transcribe: { _, _, _ in
            failNextWrite = true
            return "Texto reconhecido"
        })
        var storageFailure = false
        queue.onStorageFailure = { _ in storageFailure = true }
        queue.enqueue(meetingID: meeting.id)
        await queue.waitUntilIdle()
        XCTAssertTrue(storageFailure)
    }

    func testProcessesInOrderAndRetainsAudioAfterSuccess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let meeting = try store.create(title: "Fila", language: "pt", mode: .inPerson)
        let first = MeetingAudioSegment(source: .microphone, start: 0, end: 12)
        let second = MeetingAudioSegment(source: .microphone, start: 12, end: 24)
        for segment in [first, second] {
            try Data([1]).write(to: store.audioURL(segment, meetingID: meeting.id))
            try store.appendSegment(segment, for: meeting.id)
        }
        var decoded: [String] = []
        let queue = MeetingTranscriptionQueue(store: store, transcribe: { url, _, _ in
            decoded.append(url.lastPathComponent)
            await Task.yield()
            return "Texto \(decoded.count)"
        })
        queue.enqueue(meetingID: meeting.id)
        queue.enqueue(meetingID: meeting.id)
        await queue.waitUntilIdle()
        XCTAssertEqual(decoded, [first.fileName, second.fileName])
        XCTAssertEqual(store.meeting(meeting.id)?.segments.map(\.transcript), ["Texto 1", "Texto 2"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(first, meetingID: meeting.id).path))
    }

    func testDecodeFailurePreservesAudioAndMarksSegmentRetryable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let meeting = try store.create(title: "Erro", language: "pt", mode: .inPerson)
        let segment = MeetingAudioSegment(source: .microphone, start: 0, end: 1)
        try Data([1]).write(to: store.audioURL(segment, meetingID: meeting.id))
        try store.appendSegment(segment, for: meeting.id)
        let queue = MeetingTranscriptionQueue(store: store, transcribe: { _, _, _ in throw CocoaError(.fileReadCorruptFile) })
        queue.enqueue(meetingID: meeting.id)
        await queue.waitUntilIdle()
        XCTAssertEqual(store.meeting(meeting.id)?.segments.first?.state, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(segment, meetingID: meeting.id).path))
    }
}
