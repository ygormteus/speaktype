import Foundation

@MainActor
final class MeetingTranscriptionQueue {
    typealias Transcriber = (URL, String, String) async throws -> String
    private let store: MeetingStore
    private let transcribe: Transcriber
    private var jobs: [UUID] = []
    private var worker: Task<Void, Never>?
    var onUpdate: ((UUID) -> Void)?
    var onStorageFailure: ((UUID) -> Void)?
    var onIdle: (() -> Void)?
    var isIdle: Bool { worker == nil }

    init(store: MeetingStore, transcribe: @escaping Transcriber) {
        self.store = store
        self.transcribe = transcribe
    }

    func enqueue(meetingID: UUID) {
        if !jobs.contains(meetingID) { jobs.append(meetingID) }
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            await self.drain()
        }
    }

    private func drain() async {
        defer {
            jobs.removeAll()
            worker = nil
            onIdle?()
        }
        while !jobs.isEmpty {
            let id = jobs.removeFirst()
            while var meeting = store.meeting(id), let next = meeting.orderedSegments.first(where: { $0.state == .pending }),
                  let index = meeting.segments.firstIndex(where: { $0.id == next.id }) {
                meeting.segments[index].state = .transcribing
                do { try store.update(meeting) }
                catch { onStorageFailure?(id); return }
                let result: Result<String, Error>
                do { result = .success(try await transcribe(store.audioURL(next, meetingID: id), meeting.language, meeting.modelVariant)) }
                catch { result = .failure(error) }
                guard var latest = store.meeting(id), let current = latest.segments.firstIndex(where: { $0.id == next.id }) else { continue }
                switch result {
                case .success(let text):
                    latest.segments[current].transcript = MeetingTranscriptText.clean(text)
                    latest.segments[current].state = .completed
                    latest.segments[current].error = nil
                case .failure:
                    latest.segments[current].state = .failed
                    latest.segments[current].error = String(localized: "This segment could not be transcribed. Its audio has been kept for retry.")
                }
                do { try store.update(latest) }
                catch { onStorageFailure?(id); return }
                onUpdate?(id)
            }
            onUpdate?(id)
        }
    }

    func waitUntilIdle() async { await worker?.value }
}
