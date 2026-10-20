import XCTest
@testable import speaktype

@MainActor
final class IncrementalTranscriptionSessionTests: XCTestCase {
    /// Fake transcriber: returns the text stored for each chunk file and
    /// records the order in which files were decoded.
    private final class FakeEngine {
        var texts: [URL: String] = [:]
        var failing: Set<URL> = []
        var decoded: [URL] = []
        var delayNanoseconds: UInt64 = 0
        var merges: [[URL]] = []
        var mergeFails = false

        func transcribe(_ url: URL) async throws -> String {
            if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
            decoded.append(url)
            if failing.contains(url) { throw CocoaError(.fileReadCorruptFile) }
            return texts[url] ?? ""
        }

        /// Stands in for audio concatenation: the merged "file" transcribes
        /// to the parts' texts joined with spaces.
        func merge(_ urls: [URL]) throws -> URL {
            merges.append(urls)
            if mergeFails { throw CocoaError(.fileWriteUnknown) }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("merged-\(UUID().uuidString).wav")
            try Data([0]).write(to: url)
            texts[url] = urls.compactMap { texts[$0] }.joined(separator: " ")
            return url
        }
    }

    private var engine: FakeEngine!

    override func setUp() async throws {
        engine = FakeEngine()
    }

    private func makeSession() -> IncrementalTranscriptionSession {
        let engine = self.engine!
        return IncrementalTranscriptionSession(
            transcriber: { try await engine.transcribe($0) },
            merger: { try engine.merge($0) })
    }

    /// Lets the session's worker run until it is idle.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func chunk(
        _ index: Int, _ text: String, hasSpeech: Bool = true, duration: TimeInterval = 5
    ) throws -> RecordedAudioChunk {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-test-\(UUID().uuidString).wav")
        try Data([0]).write(to: url)
        engine.texts[url] = text
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return RecordedAudioChunk(url: url, index: index, duration: duration, hasSpeech: hasSpeech)
    }

    private func exists(_ chunk: RecordedAudioChunk) -> Bool {
        FileManager.default.fileExists(atPath: chunk.url.path)
    }

    func testDecodesEachChunkAsItArrivesWhenEngineKeepsUp() async throws {
        let session = makeSession()
        let chunks = [
            try chunk(0, "Olá, hoje vamos testar o ditado"),
            try chunk(1, "o ditado em português."),
            try chunk(2, "Você pode me enviar o relatório?"),
        ]
        for chunk in chunks {
            session.append(chunk)
            await settle()
        }

        let outcome = await session.finish(summary: RecordedChunkSummary(chunkCount: 3, hasGaps: false))

        XCTAssertEqual(
            outcome,
            .transcript("Olá, hoje vamos testar o ditado em português. Você pode me enviar o relatório?"))
        XCTAssertEqual(engine.decoded, chunks.map(\.url), "decoded serially in arrival order")
        XCTAssertTrue(engine.merges.isEmpty)
        XCTAssertEqual(session.decodeCount, 3)
        XCTAssertFalse(chunks.contains(where: exists))
    }

    func testMergesBacklogIntoOneDecodeWhenEngineFallsBehind() async throws {
        engine.delayNanoseconds = 100_000_000
        let session = makeSession()
        let first = try chunk(0, "um")
        let second = try chunk(1, "dois")
        let third = try chunk(2, "três")
        session.append(first)
        await settle()  // chunk 0 is now decoding
        session.append(second)
        session.append(third)

        let outcome = await session.finish(summary: RecordedChunkSummary(chunkCount: 3, hasGaps: false))

        XCTAssertEqual(outcome, .transcript("um dois três"))
        XCTAssertEqual(engine.merges, [[second.url, third.url]])
        XCTAssertEqual(session.decodeCount, 2)
        XCTAssertFalse([first, second, third].contains(where: exists))
    }

    func testBatchExcludesSilentChunksAndRespectsWindowLimit() async throws {
        let session = makeSession()
        let a = try chunk(0, "um", duration: 10)
        let silent = try chunk(1, "Obrigado.", hasSpeech: false, duration: 5)
        let b = try chunk(2, "dois", duration: 10)
        let c = try chunk(3, "três", duration: 10)  // would exceed the 28 s window
        [a, silent, b, c].forEach(session.append)

        let outcome = await session.finish(summary: RecordedChunkSummary(chunkCount: 4, hasGaps: false))

        XCTAssertEqual(outcome, .transcript("um dois três"))
        XCTAssertEqual(engine.merges, [[a.url, b.url]])
        XCTAssertEqual(engine.decoded.last, c.url)
        XCTAssertFalse([a, silent, b, c].contains(where: exists))
    }

    func testFailedMergeDecodesChunksIndividually() async throws {
        engine.mergeFails = true
        let session = makeSession()
        let chunks = [try chunk(0, "um"), try chunk(1, "dois")]
        chunks.forEach(session.append)
        let outcome = await session.finish(summary: RecordedChunkSummary(chunkCount: 2, hasGaps: false))
        XCTAssertEqual(outcome, .transcript("um dois"))
        XCTAssertEqual(engine.decoded, chunks.map(\.url))
    }

    func testOutOfOrderArrivalStillJoinsByIndex() async throws {
        let session = makeSession()
        let second = try chunk(1, "mundo")
        let first = try chunk(0, "olá")
        session.append(second)
        session.append(first)
        let outcome = await session.finish(summary: RecordedChunkSummary(chunkCount: 2, hasGaps: false))
        XCTAssertEqual(outcome, .transcript("olá mundo"))
    }

    func testSilentChunksAreSkippedWithoutDecoding() async throws {
        let session = makeSession()
        let silent = try chunk(0, "Obrigado por assistir.", hasSpeech: false)
        let speech = try chunk(1, "Podemos fechar hoje")
        session.append(silent)
        session.append(speech)
        let outcome = await session.finish(summary: RecordedChunkSummary(chunkCount: 2, hasGaps: false))
        XCTAssertEqual(outcome, .transcript("Podemos fechar hoje"))
        XCTAssertEqual(engine.decoded, [speech.url])
        XCTAssertFalse(exists(silent))
    }

    func testWaitsForChunksStillBeingDelivered() async throws {
        let session = makeSession()
        let first = try chunk(0, "primeiro")
        let last = try chunk(1, "último")
        session.append(first)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            session.append(last)
        }
        let outcome = await session.finish(summary: RecordedChunkSummary(chunkCount: 2, hasGaps: false))
        XCTAssertEqual(outcome, .transcript("primeiro último"))
    }

    func testFailedChunkFallsBackAndStopsDecoding() async throws {
        let session = makeSession()
        let first = try chunk(0, "um")
        let second = try chunk(1, "dois")
        let third = try chunk(2, "três")
        engine.failing = [first.url]
        session.append(first)
        await settle()
        session.append(second)
        session.append(third)
        let outcome = await session.finish(summary: RecordedChunkSummary(chunkCount: 3, hasGaps: false))
        guard case .needsFullTranscription = outcome else { return XCTFail("expected fallback") }
        XCTAssertEqual(engine.decoded, [first.url], "no decode after a failure")
        XCTAssertFalse([first, second, third].contains(where: exists))
    }

    func testMissingChunkFallsBack() async throws {
        let session = makeSession()
        session.append(try chunk(0, "um"))
        session.append(try chunk(2, "três"))
        let outcome = await session.finish(
            summary: RecordedChunkSummary(chunkCount: 3, hasGaps: false), arrivalTimeout: 0.05)
        XCTAssertEqual(outcome, .needsFullTranscription(reason: "missing chunks [1]"))
    }

    func testGapsOrMissingSummaryFallBack() {
        let texts = [0: "um"]
        XCTAssertEqual(
            IncrementalTranscriptionSession.outcome(
                texts: texts, receivedIndices: [0], failure: nil,
                summary: RecordedChunkSummary(chunkCount: 1, hasGaps: true)),
            .needsFullTranscription(reason: "audio missing from chunks"))
        XCTAssertEqual(
            IncrementalTranscriptionSession.outcome(
                texts: texts, receivedIndices: [0], failure: nil, summary: nil),
            .needsFullTranscription(reason: "no chunk summary"))
        XCTAssertEqual(
            IncrementalTranscriptionSession.outcome(
                texts: [:], receivedIndices: [], failure: nil,
                summary: RecordedChunkSummary(chunkCount: 0, hasGaps: false)),
            .needsFullTranscription(reason: "no chunks"))
        XCTAssertEqual(
            IncrementalTranscriptionSession.outcome(
                texts: [0: "", 1: " "], receivedIndices: [0, 1], failure: nil,
                summary: RecordedChunkSummary(chunkCount: 2, hasGaps: false)),
            .needsFullTranscription(reason: "empty transcript"))
        XCTAssertEqual(
            IncrementalTranscriptionSession.outcome(
                texts: [0: "um", 1: "dois"], receivedIndices: [0, 1], failure: nil,
                summary: RecordedChunkSummary(chunkCount: 2, hasGaps: false)),
            .transcript("um dois"))
    }

    func testCancelDiscardsPendingAndLateChunks() async throws {
        engine.delayNanoseconds = 50_000_000
        let session = makeSession()
        let chunks = [try chunk(0, "um"), try chunk(1, "dois"), try chunk(2, "três")]
        chunks.forEach(session.append)

        await session.cancel()
        let late = try chunk(3, "quatro")
        session.append(late)

        XCTAssertTrue(session.isCancelled)
        XCTAssertLessThanOrEqual(engine.decoded.count, 1, "only an already in-flight decode may finish")
        XCTAssertFalse((chunks + [late]).contains(where: exists))
        let outcome = await session.finish(summary: RecordedChunkSummary(chunkCount: 4, hasGaps: false))
        XCTAssertEqual(outcome, .needsFullTranscription(reason: "session cancelled"))
    }

    func testChunksAfterFinishAreDeleted() async throws {
        let session = makeSession()
        session.append(try chunk(0, "um"))
        _ = await session.finish(summary: RecordedChunkSummary(chunkCount: 1, hasGaps: false))
        let late = try chunk(1, "dois")
        session.append(late)
        XCTAssertFalse(exists(late))
        XCTAssertEqual(session.receivedChunkCount, 1)
    }
}
