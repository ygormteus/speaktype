import Combine
import Foundation

@MainActor
final class MeetingCoordinator: ObservableObject {
    static let shared = MeetingCoordinator(store: .shared, capture: MeetingAudioCapture(), prepareModel: { variant, language in
        try await TranscriptionManager.shared.prepareMeeting(variant: variant, language: language)
    }, transcribe: { url, language, variant in
        try await TranscriptionManager.shared.transcribeMeetingSegment(url, language: language, variant: variant)
    }, releaseModel: { TranscriptionManager.shared.releaseMeeting() })

    @Published private(set) var activeMeetingID: UUID?
    @Published private(set) var isStarting = false
    @Published private(set) var isStopping = false
    @Published private(set) var audioLevels: [MeetingAudioSource: Float] = [:]
    @Published var errorMessage: String?
    private let store: MeetingStore
    private let capture: any MeetingCapturing
    private let queue: MeetingTranscriptionQueue
    private let prepareModel: (String, String) async throws -> String
    private let releaseModel: () -> Void
    private var stopRequested = false
    private var captureDrained = true
    private var stopTask: Task<Void, Never>?
    private var storeObservation: AnyCancellable?

    var manifest: MeetingManifest? { activeMeetingID.flatMap(store.meeting) }
    var pendingSegmentCount: Int { manifest?.pendingCount ?? 0 }
    var isCapturingAudio: Bool { activeMeetingID != nil && !captureDrained }
    var liveTranscript: String { manifest?.orderedSegments.compactMap(\.recognizedText).joined(separator: "\n") ?? "" }

    init(store: MeetingStore, capture: any MeetingCapturing,
         prepareModel: @escaping (String, String) async throws -> String,
         transcribe: @escaping MeetingTranscriptionQueue.Transcriber,
         releaseModel: @escaping () -> Void = {}) {
        self.store = store
        self.capture = capture
        self.prepareModel = prepareModel
        self.releaseModel = releaseModel
        queue = MeetingTranscriptionQueue(store: store, transcribe: transcribe)
        queue.onUpdate = { [weak self] id in self?.completeIfReady(id) }
        queue.onStorageFailure = { [weak self] _ in self?.sourceFailed(.microphone, storage: true) }
        queue.onIdle = { [weak self] in
            guard let self, let id = self.activeMeetingID else { return }
            self.completeIfReady(id)
        }
        storeObservation = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        do { try store.recoverInterruptedMeetings() }
        catch { errorMessage = String(localized: "Some meetings could not be recovered. Saved audio has been kept.") }
    }

    func start(title: String, mode: MeetingCaptureMode, language: String, modelVariant: String = "") async throws {
        guard activeMeetingID == nil else { throw MeetingError.busy }
        var meeting = try store.create(title: title, language: language, mode: mode)
        activeMeetingID = meeting.id
        AudioPlayerService.shared.stop()
        captureDrained = false
        isStarting = true
        stopRequested = false
        audioLevels = [:]
        errorMessage = nil
        defer { isStarting = false }
        do {
            meeting.modelVariant = try await prepareModel(modelVariant, language)
            if stopRequested {
                captureDrained = true
                meeting.state = .interrupted
                try store.update(meeting)
                releaseModel()
                activeMeetingID = nil
                return
            }
            meeting.startedAt = Date()
            try store.update(meeting)
            let id = meeting.id
            try await capture.start(directory: store.directory(id), mode: mode, onSegment: { [weak self] segment in
                self?.receive(segment, meetingID: id)
            }, onSourceState: { [weak self] source, state in
                guard let self, var latest = self.store.meeting(id) else { return }
                if latest.sources[source] != .failed { latest.sources[source] = state }
                do { try self.store.update(latest) }
                catch { self.sourceFailed(source, storage: true) }
            }, onLevel: { [weak self] source, level in
                guard self?.activeMeetingID == id, self?.isStopping == false else { return }
                self?.audioLevels[source] = level
            }, onFailure: { [weak self] source, storage in self?.sourceFailed(source, storage: storage) })
            if var latest = store.meeting(id), latest.state == .preparing {
                latest.state = .recording
                try store.update(latest)
            }
            isStarting = false
            if stopRequested { await stop() }
        } catch {
            await capture.stop()
            captureDrained = true
            await queue.waitUntilIdle()
            if var latest = store.meeting(meeting.id) {
                latest.state = .failed
                latest.endedAt = Date()
                latest.issues.append(MeetingIssue(source: nil, offset: 0, message: String(localized: "Meeting capture could not start.")))
                try? store.update(latest)
            }
            releaseModel()
            activeMeetingID = nil
            throw error
        }
    }

    private func receive(_ segment: MeetingAudioSegment, meetingID: UUID) {
        guard activeMeetingID == meetingID, let current = store.meeting(meetingID),
              !current.segments.contains(where: { $0.id == segment.id }) else { return }
        do {
            try store.appendSegment(segment, for: meetingID)
            queue.enqueue(meetingID: meetingID)
        } catch { sourceFailed(segment.source, storage: true) }
    }

    private func sourceFailed(_ source: MeetingAudioSource, storage: Bool) {
        guard let id = activeMeetingID, var meeting = store.meeting(id) else { return }
        let message = storage
            ? String(localized: "Recording stopped because audio could not be saved. Check free disk space and folder access.")
            : String(localized: "An audio source stopped. This meeting contains a capture gap.")
        if !meeting.issues.contains(where: { $0.message == message && $0.source == source }) {
            meeting.issues.append(MeetingIssue(source: source, offset: Date().timeIntervalSince(meeting.startedAt), message: message))
        }
        meeting.sources[source] = .failed
        meeting.state = storage ? .failed : .interrupted
        do { try store.update(meeting) } catch { errorMessage = message }
        if storage { errorMessage = message }
        guard stopTask == nil else { return }
        stopTask = Task { [weak self] in
            await self?.stop()
            self?.stopTask = nil
        }
    }

    func stop() async {
        guard let id = activeMeetingID, !isStopping else { return }
        if isStarting { stopRequested = true; return }
        isStopping = true
        if var meeting = store.meeting(id), meeting.state == .recording {
            meeting.state = .finalizing
            do { try store.update(meeting) } catch { errorMessage = String(localized: "Meeting storage is unavailable. Check free disk space and folder access.") }
        }
        await capture.stop()
        captureDrained = true
        audioLevels = [:]
        if var meeting = store.meeting(id) {
            meeting.endedAt = Date()
            if meeting.segments.isEmpty || (meeting.mode == .online && !meeting.segments.contains(where: { $0.source == .system })) {
                meeting.issues.append(MeetingIssue(source: meeting.mode == .online ? .system : .microphone, offset: 0,
                    message: String(localized: "No audio was saved from an expected source. Check source permissions and playback before the next meeting.")))
            }
            if meeting.state == .finalizing || meeting.state == .recording { meeting.state = .transcribing }
            do { try store.update(meeting) } catch { errorMessage = String(localized: "Meeting storage is unavailable. Check free disk space and folder access.") }
        }
        isStopping = false
        completeIfReady(id)
    }

    func recover(_ id: UUID, reprocessAll: Bool = false) async throws {
        guard activeMeetingID == nil else { throw MeetingError.busy }
        guard let existing = store.meeting(id), existing.summaryState != .generating else { throw MeetingError.busy }
        try store.reconcileSegments(for: id)
        guard var meeting = store.meeting(id), !meeting.segments.isEmpty else {
            throw MeetingError.unavailable(String(localized: "No saved audio segments are available to transcribe."))
        }
        captureDrained = true
        activeMeetingID = id
        isStarting = true
        defer { isStarting = false }
        do {
            meeting.modelVariant = try await prepareModel(meeting.modelVariant, meeting.language)
            for index in meeting.segments.indices where reprocessAll || meeting.segments[index].state != .completed {
                meeting.segments[index].state = .pending
                meeting.segments[index].error = nil
            }
            meeting.state = .transcribing
            meeting.summary = nil
            meeting.summaryState = .absent
            meeting.summaryError = nil
            try store.update(meeting)
            queue.enqueue(meetingID: id)
        } catch { releaseModel(); activeMeetingID = nil; throw error }
    }

    private func completeIfReady(_ id: UUID) {
        guard activeMeetingID == id, captureDrained, queue.isIdle, !isStarting, !isStopping,
              var meeting = store.meeting(id), !meeting.state.isCapturing,
              meeting.pendingCount == 0 || meeting.state == .failed else { return }
        if meeting.state != .failed {
            meeting.state = meeting.issues.isEmpty && !meeting.segments.contains(where: { $0.state == .failed }) ? .completed : .interrupted
        }
        do { try store.update(meeting) } catch { errorMessage = String(localized: "Meeting storage is unavailable. Check free disk space and folder access.") }
        activeMeetingID = nil
        releaseModel()
    }

    func waitUntilSettled() async {
        await stopTask?.value
        await queue.waitUntilIdle()
        await stopTask?.value
        if let id = activeMeetingID { completeIfReady(id) }
    }
}
