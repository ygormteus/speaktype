import Foundation

nonisolated enum MeetingCaptureMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case inPerson, online
    var id: String { rawValue }
    var title: String {
        switch self {
        case .inPerson: String(localized: "In person · Just my voice")
        case .online: String(localized: "Online · My voice and the call")
        }
    }
}

nonisolated enum MeetingAudioSource: String, Codable, CaseIterable, Sendable {
    case microphone, system
    var title: String {
        self == .microphone ? String(localized: "Microphone") : String(localized: "System audio")
    }
}

nonisolated enum MeetingSourceState: String, Codable, Sendable {
    case preparing, active, stopped, failed
}

nonisolated enum MeetingState: String, Codable, Sendable {
    case preparing, recording, finalizing, transcribing, completed, interrupted, failed
    var title: String {
        switch self {
        case .preparing: String(localized: "Preparing meeting")
        case .recording: String(localized: "Recording meeting")
        case .finalizing: String(localized: "Finalizing audio")
        case .transcribing: String(localized: "Finishing transcription")
        case .completed: String(localized: "Transcript ready")
        case .interrupted: String(localized: "Meeting interrupted")
        case .failed: String(localized: "Meeting failed")
        }
    }
    var isCapturing: Bool { self == .preparing || self == .recording || self == .finalizing }
}

nonisolated enum MeetingSegmentState: String, Codable, Sendable {
    case pending, transcribing, completed, failed
}

nonisolated enum MeetingSummaryState: String, Codable, Sendable {
    case absent, generating, ready, failed
}

nonisolated struct MeetingAudioSegment: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    let source: MeetingAudioSource
    let start: TimeInterval
    let end: TimeInterval
    var state: MeetingSegmentState = .pending
    var transcript: String?
    var error: String?
    var fileName: String { id.uuidString + ".wav" }
    var recognizedText: String? {
        guard state == .completed, let transcript else { return nil }
        let text = MeetingTranscriptText.clean(transcript)
        return text.isEmpty ? nil : text
    }
}

nonisolated enum MeetingTranscriptText {
    static func clean(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains(where: { $0.isLetter || $0.isNumber }) ? trimmed : ""
    }
}

nonisolated struct MeetingIssue: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    let source: MeetingAudioSource?
    let offset: TimeInterval
    let message: String
}

nonisolated struct MeetingSummaryItem: Codable, Equatable, Sendable {
    let text: String
    let segmentIDs: [UUID]
    var owner: String?
    var deadline: String?
}

nonisolated struct MeetingSummary: Codable, Equatable, Sendable {
    var overview: [MeetingSummaryItem]
    var topics: [MeetingSummaryItem]
    var decisions: [MeetingSummaryItem]
    var pending: [MeetingSummaryItem]
    var tasks: [MeetingSummaryItem]
    var allItems: [MeetingSummaryItem] { overview + topics + decisions + pending + tasks }
}

nonisolated struct MeetingManifest: Codable, Identifiable, Equatable, Sendable {
    var schemaVersion = 1
    var id = UUID()
    var title: String
    var language: String
    var mode: MeetingCaptureMode
    var startedAt = Date()
    var endedAt: Date?
    var modelVariant = ""
    var state: MeetingState = .preparing
    var sources: [MeetingAudioSource: MeetingSourceState] = [:]
    var segments: [MeetingAudioSegment] = []
    var issues: [MeetingIssue] = []
    var summaryState: MeetingSummaryState = .absent
    var summary: MeetingSummary?
    var summaryProvider: String?
    var summaryError: String?

    var orderedSegments: [MeetingAudioSegment] {
        segments.sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
    }
    var pendingCount: Int { segments.filter { $0.state == .pending || $0.state == .transcribing }.count }
    var processedCount: Int { segments.filter { $0.state == .completed || $0.state == .failed }.count }
    var speechSegments: [MeetingAudioSegment] { orderedSegments.filter { $0.recognizedText != nil } }
    var duration: TimeInterval { max(segments.map(\.end).max() ?? 0, (endedAt ?? startedAt).timeIntervalSince(startedAt)) }
}

enum MeetingError: LocalizedError {
    case unavailable(String)
    case invalidData
    case invalidSummary
    case busy
    var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        case .invalidData: String(localized: "Meeting data could not be read. Your saved audio has been kept.")
        case .invalidSummary: String(localized: "The model returned a summary that could not be verified. Your transcript is available; try generating the summary again.")
        case .busy: String(localized: "Finish the active recording before starting a meeting.")
        }
    }
}
