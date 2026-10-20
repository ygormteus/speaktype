import Foundation

/// Keeps partial transcript chunks in capture order. It has no network or
/// model dependency: engines remain responsible for producing a chunk, and
/// the UI can safely render the returned snapshot.
///
/// Each new chunk is stitched onto the previous one with `TranscriptSeam`, so
/// a word Whisper heard on both sides of a cut is only kept once.
actor IncrementalTranscriptAccumulator {
    private var chunks: [String] = []

    @discardableResult
    func append(_ chunk: String) -> String {
        let normalized = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return transcript }
        let stitched = chunks.last.map {
            TranscriptSeam.removingBoundaryRepeat(previous: $0, next: normalized)
        } ?? normalized
        guard !stitched.isEmpty else { return transcript }
        chunks.append(stitched)
        return transcript
    }

    var transcript: String { chunks.joined(separator: " ") }

    func reset() {
        chunks.removeAll()
    }
}

/// Pure helpers for joining independently transcribed audio chunks.
nonisolated enum TranscriptSeam {
    /// Words shorter than this are never de-duplicated on their own: in
    /// Portuguese "a", "o", "e", "é", "de" legitimately repeat across a pause.
    static let minimumSingleWordLength = 3

    /// If `next` starts with the same 1…`maxWords` words `previous` ends with,
    /// drops that repeat from `next`. Comparison ignores case, diacritics and
    /// punctuation; the longest match wins. Returns `next` (trimmed) otherwise.
    static func removingBoundaryRepeat(previous: String, next: String, maxWords: Int = 3) -> String {
        let nextWords = next.split(whereSeparator: \.isWhitespace).map(String.init)
        let previousKeys = previous.split(whereSeparator: \.isWhitespace).map { key(String($0)) }
            .filter { !$0.isEmpty }
        let nextKeys = nextWords.map(key)
        guard !nextWords.isEmpty, !previousKeys.isEmpty else {
            return nextWords.joined(separator: " ")
        }

        let limit = min(maxWords, previousKeys.count, nextKeys.count)
        guard limit > 0 else { return nextWords.joined(separator: " ") }
        for count in stride(from: limit, through: 1, by: -1) {
            let tail = Array(previousKeys.suffix(count))
            let head = Array(nextKeys.prefix(count))
            guard tail == head, head.allSatisfy({ !$0.isEmpty }) else { continue }
            if count == 1, head[0].count < minimumSingleWordLength { continue }
            return nextWords.dropFirst(count).joined(separator: " ")
        }
        return nextWords.joined(separator: " ")
    }

    /// Joins chunk texts in order, stripping boundary repeats.
    static func join(_ chunks: [String]) -> String {
        var joined: [String] = []
        for chunk in chunks {
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let stitched = joined.last.map { removingBoundaryRepeat(previous: $0, next: trimmed) }
                ?? trimmed
            if !stitched.isEmpty { joined.append(stitched) }
        }
        return joined.joined(separator: " ")
    }

    private static func key(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }
}
