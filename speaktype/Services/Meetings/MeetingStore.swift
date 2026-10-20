import AVFoundation
import Combine
import Foundation

@MainActor
final class MeetingStore: ObservableObject {
    static let shared = MeetingStore()
    @Published private(set) var items: [MeetingManifest] = []
    @Published private(set) var unreadableMeetingCount = 0
    @Published private(set) var storageError: String?
    let root: URL
    private let writeData: (Data, URL) throws -> Void

    init(root: URL? = nil, writeData: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpeakType/Meetings", isDirectory: true)
        self.writeData = writeData
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            items = try loadAll()
        } catch {
            storageError = String(localized: "Meeting storage is unavailable. Check free disk space and folder access.")
        }
    }

    func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func audioURL(_ segment: MeetingAudioSegment, meetingID: UUID) -> URL {
        directory(meetingID).appendingPathComponent(segment.fileName)
    }
    func meeting(_ id: UUID) -> MeetingManifest? { items.first { $0.id == id } }

    func create(title: String, language: String, mode: MeetingCaptureMode) throws -> MeetingManifest {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let meeting = MeetingManifest(title: trimmed.isEmpty ? String(localized: "Untitled meeting") : trimmed, language: language, mode: mode)
        try FileManager.default.createDirectory(at: directory(meeting.id), withIntermediateDirectories: true)
        try update(meeting)
        return meeting
    }

    func update(_ manifest: MeetingManifest) throws {
        guard Self.isValid(manifest) else { throw MeetingError.invalidData }
        try writeData(JSONEncoder().encode(manifest), directory(manifest.id).appendingPathComponent("manifest.json"))
        if let index = items.firstIndex(where: { $0.id == manifest.id }) {
            items[index] = manifest
        } else {
            items.append(manifest)
        }
        items.sort { $0.startedAt > $1.startedAt }
    }

    func appendSegment(_ segment: MeetingAudioSegment, for meetingID: UUID) throws {
        guard var manifest = meeting(meetingID), segment.end >= segment.start,
              segment.start.isFinite, segment.end.isFinite, segment.start >= 0,
              FileManager.default.fileExists(atPath: audioURL(segment, meetingID: meetingID).path)
        else { throw MeetingError.invalidData }
        try writeData(JSONEncoder().encode(segment), directory(meetingID).appendingPathComponent(segment.id.uuidString + ".segment.json"))
        if !manifest.segments.contains(where: { $0.id == segment.id }) { manifest.segments.append(segment) }
        try update(manifest)
    }

    func loadAll() throws -> [MeetingManifest] {
        unreadableMeetingCount = 0
        let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        return directories.compactMap { folder in
            guard let id = UUID(uuidString: folder.lastPathComponent) else { return nil }
            do {
                let manifest = try JSONDecoder().decode(MeetingManifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
                guard manifest.id == id, Self.isValid(manifest) else { throw MeetingError.invalidData }
                return manifest
            } catch {
                unreadableMeetingCount += 1
                return nil
            }
        }.sorted { $0.startedAt > $1.startedAt }
    }

    @discardableResult
    func recoverInterruptedMeetings() throws -> [MeetingManifest] {
        for var manifest in items {
            let original = manifest
            let wasCapturing = manifest.state.isCapturing
            if wasCapturing || manifest.state == .transcribing {
                manifest.state = .interrupted
                manifest.endedAt = manifest.endedAt ?? manifest.startedAt.addingTimeInterval(manifest.segments.map(\.end).max() ?? 0)
                for source in manifest.sources.keys { manifest.sources[source] = .stopped }
            }
            if wasCapturing {
                manifest.issues.append(MeetingIssue(source: nil, offset: manifest.duration,
                    message: String(localized: "Capture was interrupted. Only saved audio can be recovered; recording has not resumed.")))
            }
            try reconcileSegments(&manifest)
            if manifest.summaryState == .generating {
                manifest.summaryState = .failed
                manifest.summaryError = String(localized: "Summary interrupted. You can generate it again.")
            }
            if manifest.state == .completed, manifest.segments.contains(where: { $0.state != .completed }) { manifest.state = .interrupted }
            if manifest != original { try update(manifest) }
        }
        return items
    }

    func reconcileSegments(for id: UUID) throws {
        guard var manifest = meeting(id) else { throw MeetingError.invalidData }
        let original = manifest
        try reconcileSegments(&manifest)
        if manifest != original { try update(manifest) }
    }

    private func reconcileSegments(_ manifest: inout MeetingManifest) throws {
        let journals = try FileManager.default.contentsOfDirectory(at: directory(manifest.id), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".segment.json") }
        for journal in journals {
            if let segment = try? JSONDecoder().decode(MeetingAudioSegment.self, from: Data(contentsOf: journal)),
               segment.start.isFinite, segment.end.isFinite, segment.start >= 0, segment.end >= segment.start,
               !manifest.segments.contains(where: { $0.id == segment.id }) { manifest.segments.append(segment) }
        }
        for index in manifest.segments.indices {
            let url = audioURL(manifest.segments[index], meetingID: manifest.id)
            let partial = directory(manifest.id).appendingPathComponent(manifest.segments[index].id.uuidString + ".partial.wav")
            if !FileManager.default.fileExists(atPath: url.path), (try? AVAudioFile(forReading: partial)) != nil {
                try FileManager.default.moveItem(at: partial, to: url)
            }
            if (try? AVAudioFile(forReading: url)) == nil {
                manifest.segments[index].state = .failed
                manifest.segments[index].error = String(localized: "Audio segment is unavailable or incomplete.")
            } else if manifest.segments[index].state == .transcribing {
                manifest.segments[index].state = .pending
            }
        }
    }

    func deleteMeeting(_ id: UUID) throws {
        try FileManager.default.removeItem(at: directory(id))
        items.removeAll { $0.id == id }
    }

    private static func isValid(_ manifest: MeetingManifest) -> Bool {
        manifest.schemaVersion == 1 && Set(manifest.segments.map(\.id)).count == manifest.segments.count
            && manifest.segments.allSatisfy { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start }
    }
}
