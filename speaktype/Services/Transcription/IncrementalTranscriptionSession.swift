import AVFoundation
import Foundation

/// Transcribes a recording chunk by chunk while the user is still speaking,
/// so releasing the hotkey only waits for the tail instead of the whole
/// dictation.
///
/// One decode runs at a time. Whisper's cost per call is dominated by its
/// fixed 30 s window, not by chunk length, so when decoding falls behind
/// capture the chunks that queued up meanwhile are merged into a single
/// decode (up to `maximumBatchDuration`). Fast machines decode every chunk as
/// it arrives; slow ones degrade gracefully instead of building a backlog.
///
/// Raw engine text is kept by chunk index. `finish` joins it with
/// `TranscriptSeam` only if every chunk of the recording arrived and
/// succeeded; otherwise it reports that the caller must transcribe the full
/// recording instead, so a failed chunk can never silently drop words. A
/// chunk with speech that decodes to nothing counts as failed for the same
/// reason.
///
/// Chunks don't overlap, so words repeated across a pause cut were really
/// said twice and are kept. Only seams after a forced max-length cut, where
/// a word may straddle the cut and be heard on both sides, are de-duplicated.
///
/// Every chunk file handed to `append` is deleted once processed, skipped, or
/// cancelled.
final class IncrementalTranscriptionSession {
    typealias Transcriber = (URL) async throws -> String
    /// Concatenates chunk files, in order, into a new temporary file.
    typealias Merger = ([URL]) throws -> URL

    /// Stays inside one Whisper window, so a merged decode costs one call.
    static let maximumBatchDuration: TimeInterval = 28

    enum Outcome: Equatable {
        /// Raw (not yet finalized) text of the whole recording.
        case transcript(String)
        /// The chunks don't cover the recording; transcribe the full file.
        case needsFullTranscription(reason: String)
    }

    private let transcriber: Transcriber
    private let merger: Merger
    private var pending: [RecordedAudioChunk] = []
    private var worker: Task<Void, Never>?
    private var texts: [Int: String] = [:]
    /// Decoded chunks that ended at a forced cut (see `TranscriptSeam.join`).
    private var forcedCutIndices = Set<Int>()
    private var receivedIndices = Set<Int>()
    private var failure: String?
    private var isAccepting = true
    private(set) var isCancelled = false
    /// Number of engine calls made (diagnostics and tests).
    private(set) var decodeCount = 0

    init(transcriber: @escaping Transcriber, merger: @escaping Merger = AudioChunkMerger.merge) {
        self.transcriber = transcriber
        self.merger = merger
    }

    /// Number of chunks received so far (for diagnostics and tests).
    var receivedChunkCount: Int { receivedIndices.count }

    func append(_ chunk: RecordedAudioChunk) {
        guard isAccepting, !isCancelled, receivedIndices.insert(chunk.index).inserted else {
            try? FileManager.default.removeItem(at: chunk.url)
            return
        }
        // After a failure the session falls back anyway; don't spend the
        // model on chunks whose text will be discarded.
        guard failure == nil else {
            try? FileManager.default.removeItem(at: chunk.url)
            return
        }
        pending.append(chunk)
        if worker == nil {
            worker = Task { await self.drain() }
        }
    }

    /// Waits for the outstanding chunks and returns the joined raw text.
    ///
    /// - Parameters:
    ///   - summary: The recorder's chunk summary; nil means chunking state is
    ///     unknown, which always falls back.
    ///   - arrivalTimeout: How long to wait for chunks the recorder reported
    ///     but that haven't been delivered yet. The recorder delivers every
    ///     chunk before `stopRecording` returns, so by default nothing is
    ///     awaited and a missing chunk falls back immediately.
    func finish(summary: RecordedChunkSummary?, arrivalTimeout: TimeInterval = 0) async -> Outcome {
        guard !isCancelled else { return .needsFullTranscription(reason: "session cancelled") }

        if let summary, summary.isUsable {
            let deadline = Date().addingTimeInterval(arrivalTimeout)
            while receivedIndices.count < summary.chunkCount, Date() < deadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        isAccepting = false
        await worker?.value

        let outcome = Self.outcome(
            texts: texts, receivedIndices: receivedIndices, failure: failure, summary: summary,
            forcedCutIndices: forcedCutIndices)
        texts.removeAll()
        return outcome
    }

    /// Stops transcribing and discards pending chunks. Waits for an in-flight
    /// decode to return, so the caller can safely reuse the model afterwards.
    func cancel() async {
        isCancelled = true
        isAccepting = false
        let worker = self.worker
        worker?.cancel()
        await worker?.value
        discardPending()
        texts.removeAll()
    }

    // MARK: - Worker

    private func drain() async {
        while !isCancelled, failure == nil, let batch = takeNextBatch() {
            await decode(batch)
        }
        // No suspension between the empty check above and here, so a chunk
        // appended from now on starts a fresh worker.
        worker = nil
        if isCancelled || failure != nil { discardPending() }
    }

    /// Removes and returns the earliest run of consecutive chunks that fits
    /// in one decode.
    private func takeNextBatch() -> [RecordedAudioChunk]? {
        guard !pending.isEmpty else { return nil }
        pending.sort { $0.index < $1.index }
        var batch = [pending[0]]
        var duration = pending[0].duration
        for chunk in pending.dropFirst() {
            guard chunk.index == batch[batch.count - 1].index + 1,
                  duration + chunk.duration <= Self.maximumBatchDuration
            else { break }
            batch.append(chunk)
            duration += chunk.duration
        }
        pending.removeFirst(batch.count)
        return batch
    }

    private func decode(_ batch: [RecordedAudioChunk]) async {
        defer { batch.forEach { try? FileManager.default.removeItem(at: $0.url) } }
        // Near-silent chunks are where Whisper hallucinates ("Obrigado.",
        // subtitle credits); they carry no words, so they are never decoded.
        for chunk in batch { texts[chunk.index] = "" }
        let speech = batch.filter(\.hasSpeech)
        guard let first = speech.first else { return }
        forcedCutIndices.formUnion(speech.filter(\.endedByForcedCut).map(\.index))

        do {
            if speech.count == 1 {
                texts[first.index] = try await transcribe(first.url)
                return
            }
            if let merged = try? merger(speech.map(\.url)) {
                defer { try? FileManager.default.removeItem(at: merged) }
                texts[first.index] = try await transcribe(merged)
                return
            }
            // Merging failed: decode each chunk on its own.
            for chunk in speech {
                guard !isCancelled else { return }
                texts[chunk.index] = try await transcribe(chunk.url)
            }
        } catch {
            if !isCancelled {
                failure = "chunks \(batch.map(\.index)) failed: \(error.localizedDescription)"
            }
        }
    }

    /// Decodes audio the segmenter heard speech in. Empty text there means
    /// words were lost (or the file was), so it fails the chunk.
    private func transcribe(_ url: URL) async throws -> String {
        decodeCount += 1
        let text = try await transcriber(url)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EmptyDecodeError()
        }
        return text
    }

    private struct EmptyDecodeError: LocalizedError {
        var errorDescription: String? { "speech decoded to empty text" }
    }

    private func discardPending() {
        pending.forEach { try? FileManager.default.removeItem(at: $0.url) }
        pending.removeAll()
    }

    /// Pure decision: the joined transcript if the chunks are complete,
    /// otherwise why the full recording must be transcribed.
    static func outcome(
        texts: [Int: String],
        receivedIndices: Set<Int>,
        failure: String?,
        summary: RecordedChunkSummary?,
        forcedCutIndices: Set<Int> = []
    ) -> Outcome {
        guard let summary else { return .needsFullTranscription(reason: "no chunk summary") }
        guard !summary.hasGaps else {
            return .needsFullTranscription(reason: "audio missing from chunks")
        }
        guard summary.chunkCount > 0 else { return .needsFullTranscription(reason: "no chunks") }
        if let failure { return .needsFullTranscription(reason: failure) }

        let expected = Set(0..<summary.chunkCount)
        guard expected.isSubset(of: receivedIndices) else {
            let missing = expected.subtracting(receivedIndices).sorted()
            return .needsFullTranscription(reason: "missing chunks \(missing)")
        }
        guard expected.allSatisfy({ texts[$0] != nil }) else {
            return .needsFullTranscription(reason: "chunk not transcribed")
        }

        let joined = TranscriptSeam.join(
            (0..<summary.chunkCount).map { texts[$0] ?? "" }, deduplicatingAfter: forcedCutIndices)
        // Empty incremental text is cheap to double-check: the full path trims
        // silence first and returns empty immediately when there is no speech.
        guard !joined.isEmpty else { return .needsFullTranscription(reason: "empty transcript") }
        return .transcript(joined)
    }
}

/// Concatenates recorded chunk WAVs (same format) into one temporary WAV.
nonisolated enum AudioChunkMerger {
    static func merge(_ urls: [URL]) throws -> URL {
        guard let firstURL = urls.first else { throw CocoaError(.fileReadNoSuchFile) }
        let first = try AVAudioFile(forReading: firstURL)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("speaktype-merged-\(UUID().uuidString).wav")
        do {
            let writer = try AVAudioFile(
                forWriting: output, settings: first.fileFormat.settings,
                commonFormat: first.processingFormat.commonFormat,
                interleaved: first.processingFormat.isInterleaved)
            for url in urls {
                let file = try AVAudioFile(forReading: url)
                guard file.processingFormat == first.processingFormat,
                      let buffer = AVAudioPCMBuffer(
                        pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
                else { throw CocoaError(.fileReadCorruptFile) }
                try file.read(into: buffer)
                try writer.write(from: buffer)
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return output
    }
}
