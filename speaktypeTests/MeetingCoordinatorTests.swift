import AVFoundation
import XCTest
@testable import speaktype

@MainActor
final class MeetingCoordinatorTests: XCTestCase {
    func testExplicitMeetingModelIsPreparedAndPinnedToSavedSegments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let capture = FakeMeetingCapture()
        let variant = "freds0_distil-whisper-large-v3-ptbr"
        var requested: String?
        var decoded: String?
        let coordinator = MeetingCoordinator(store: store, capture: capture, prepareModel: { selected, language in
            requested = selected
            XCTAssertEqual(language, "pt")
            return selected
        }, transcribe: { _, _, selected in decoded = selected; return "Teste" })
        try await coordinator.start(title: "Modelo rápido", mode: .inPerson, language: "pt", modelVariant: variant)
        let id = try XCTUnwrap(coordinator.activeMeetingID)
        XCTAssertEqual(requested, variant)
        XCTAssertEqual(store.meeting(id)?.modelVariant, variant)
        let segment = MeetingAudioSegment(source: .microphone, start: 0, end: 1)
        try Data([1]).write(to: store.audioURL(segment, meetingID: id))
        capture.segment?(segment)
        await coordinator.stop()
        await coordinator.waitUntilSettled()
        XCTAssertEqual(decoded, variant)
        XCTAssertEqual(store.meeting(id)?.modelVariant, variant)
    }

    func testReprocessAllReplacesCompletedTranscriptAndClearsSummary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        var meeting = try store.create(title: "Reprocessar", language: "pt", mode: .inPerson)
        meeting.modelVariant = "freds0_distil-whisper-large-v3-ptbr"
        var segment = MeetingAudioSegment(source: .microphone, start: 0, end: 1)
        segment.state = .completed
        segment.transcript = "Texto anterior"
        let url = store.audioURL(segment, meetingID: meeting.id)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        var audio: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 16_000)
        try audio?.write(from: buffer)
        audio = nil
        meeting.segments = [segment]
        meeting.state = .completed
        meeting.summaryState = .failed
        meeting.summaryError = "Erro anterior"
        try store.update(meeting)
        var calls = 0
        let coordinator = MeetingCoordinator(store: store, capture: FakeMeetingCapture(), prepareModel: { selected, _ in
            XCTAssertEqual(selected, meeting.modelVariant)
            return selected
        }, transcribe: { _, language, selected in
            XCTAssertEqual(language, "pt")
            XCTAssertEqual(selected, meeting.modelVariant)
            calls += 1
            return "Texto atualizado"
        })
        try await coordinator.recover(meeting.id, reprocessAll: true)
        await coordinator.waitUntilSettled()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(store.meeting(meeting.id)?.segments.first?.transcript, "Texto atualizado")
        XCTAssertEqual(store.meeting(meeting.id)?.summaryState, .absent)
        XCTAssertNil(store.meeting(meeting.id)?.summaryError)
        XCTAssertNil(coordinator.activeMeetingID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testStorageFailureKeepsReservationUntilDecodeFinishes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let capture = FakeMeetingCapture()
        let started = expectation(description: "ASR started")
        var finish: CheckedContinuation<String, Never>?
        var releases = 0
        let coordinator = MeetingCoordinator(store: store, capture: capture, prepareModel: { _, _ in "test" }, transcribe: { _, _, _ in
            await withCheckedContinuation { continuation in finish = continuation; started.fulfill() }
        }, releaseModel: { releases += 1 })
        try await coordinator.start(title: "Storage", mode: .inPerson, language: "pt")
        let id = try XCTUnwrap(coordinator.activeMeetingID)
        let segment = MeetingAudioSegment(source: .microphone, start: 0, end: 1)
        try Data([1]).write(to: store.audioURL(segment, meetingID: id))
        capture.segment?(segment)
        await fulfillment(of: [started], timeout: 2)
        capture.failure?(.microphone, true)
        await coordinator.stop()
        XCTAssertEqual(coordinator.activeMeetingID, id)
        XCTAssertEqual(releases, 0)
        finish?.resume(returning: "Texto preservado")
        await coordinator.waitUntilSettled()
        XCTAssertNil(coordinator.activeMeetingID)
        XCTAssertEqual(releases, 1)
    }

    func testDecodeCompletionAfterSourceFailureStillDrainsCapture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let capture = FakeMeetingCapture()
        let coordinator = MeetingCoordinator(store: store, capture: capture, prepareModel: { _, _ in "test-model" }, transcribe: { _, _, _ in
            capture.failure?(.system, false)
            return "Transcrição concluída junto da falha"
        })
        try await coordinator.start(title: "Corrida", mode: .online, language: "pt")
        let id = try XCTUnwrap(coordinator.activeMeetingID)
        let segment = MeetingAudioSegment(source: .microphone, start: 0, end: 1)
        try Data([1]).write(to: store.audioURL(segment, meetingID: id))
        capture.segment?(segment)
        await coordinator.waitUntilSettled()
        await coordinator.waitUntilSettled()
        XCTAssertTrue(capture.stopped)
        XCTAssertNil(coordinator.activeMeetingID)
        XCTAssertEqual(store.meeting(id)?.state, .interrupted)
    }

    func testSourceFailureMarksGapWithoutClaimingCompleteCapture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let capture = FakeMeetingCapture()
        let coordinator = MeetingCoordinator(store: store, capture: capture, prepareModel: { _, _ in "test-model" }, transcribe: { _, _, _ in "Olá" })
        try await coordinator.start(title: "Online", mode: .online, language: "pt")
        capture.failure?(.system, false)
        await coordinator.waitUntilSettled()
        XCTAssertEqual(store.items.first?.state, .interrupted)
        XCTAssertEqual(store.items.first?.issues.first?.source, .system)
        XCTAssertTrue(capture.stopped)
    }

    func testSegmentWriteFailureStopsCaptureAndPersistsFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let capture = FakeMeetingCapture()
        let coordinator = MeetingCoordinator(store: store, capture: capture, prepareModel: { _, _ in "test-model" }, transcribe: { _, _, _ in "" })
        try await coordinator.start(title: "Presencial", mode: .inPerson, language: "pt")
        capture.failure?(.microphone, true)
        await coordinator.waitUntilSettled()
        XCTAssertEqual(store.items.first?.state, .failed)
        XCTAssertTrue(capture.stopped)
        XCTAssertNil(coordinator.activeMeetingID)
    }
}

@MainActor
private final class FakeMeetingCapture: MeetingCapturing {
    var failure: ((MeetingAudioSource, Bool) -> Void)?
    var segment: ((MeetingAudioSegment) -> Void)?
    var stopped = false
    func start(directory: URL, mode: MeetingCaptureMode, onSegment: @escaping (MeetingAudioSegment) -> Void,
               onSourceState: @escaping (MeetingAudioSource, MeetingSourceState) -> Void,
               onLevel: @escaping (MeetingAudioSource, Float) -> Void,
               onFailure: @escaping (MeetingAudioSource, Bool) -> Void) async throws {
        failure = onFailure
        segment = onSegment
        onSourceState(.microphone, .active)
        if mode == .online { onSourceState(.system, .active) }
    }
    func stop() async { stopped = true }
}
