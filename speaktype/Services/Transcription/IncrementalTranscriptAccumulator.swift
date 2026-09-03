import Foundation

/// Keeps partial transcript chunks in capture order for a future live-dictation
/// surface. It has no network or model dependency: engines remain responsible
/// for producing a chunk, and the UI can safely render the returned snapshot.
actor IncrementalTranscriptAccumulator {
    private var chunks: [String] = []

    @discardableResult
    func append(_ chunk: String) -> String {
        let normalized = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return transcript }
        guard chunks.last != normalized else { return transcript }
        chunks.append(normalized)
        return transcript
    }

    var transcript: String { chunks.joined(separator: " ") }

    func reset() {
        chunks.removeAll()
    }
}
