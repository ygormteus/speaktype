import XCTest
@testable import speaktype

final class SpeechSegmenterTests: XCTestCase {
    private let buffer: TimeInterval = 0.032
    private let speech: Float = 0.08     // ≈ -22 dBFS
    private let silence: Float = 0.0005  // ≈ -66 dBFS

    /// Feeds `seconds` of buffers at `rms`; returns every cut with the audio
    /// time at which it happened.
    @discardableResult
    private func feed(
        _ segmenter: inout SpeechSegmenter, rms: Float, seconds: TimeInterval,
        elapsed: inout TimeInterval
    ) -> [(at: TimeInterval, stats: SpeechSegmenter.ChunkStats)] {
        var cuts: [(TimeInterval, SpeechSegmenter.ChunkStats)] = []
        for _ in 0..<Int((seconds / buffer).rounded()) {
            elapsed += buffer
            if let stats = segmenter.process(rms: rms, duration: buffer) {
                cuts.append((elapsed, stats))
            }
        }
        return cuts
    }

    func testDoesNotCutBeforeMinimumDurationEvenAtAPause() {
        var segmenter = SpeechSegmenter()
        var t: TimeInterval = 0
        var cuts = feed(&segmenter, rms: speech, seconds: 2, elapsed: &t)
        cuts += feed(&segmenter, rms: silence, seconds: 1, elapsed: &t)
        cuts += feed(&segmenter, rms: speech, seconds: 0.5, elapsed: &t)
        XCTAssertTrue(cuts.isEmpty)
    }

    func testCutsAtFirstPauseAfterMinimumDuration() {
        var segmenter = SpeechSegmenter()
        var t: TimeInterval = 0
        XCTAssertTrue(feed(&segmenter, rms: speech, seconds: 5, elapsed: &t).isEmpty)
        let cuts = feed(&segmenter, rms: silence, seconds: 1, elapsed: &t)
        XCTAssertEqual(cuts.count, 1)
        // Cut once ~350 ms of silence has accumulated, not earlier.
        XCTAssertEqual(cuts[0].at, 5.35, accuracy: 0.05)
        XCTAssertEqual(cuts[0].stats.duration, cuts[0].at, accuracy: 0.001)
        XCTAssertEqual(cuts[0].stats.speechDuration, 5, accuracy: 0.05)
        XCTAssertTrue(segmenter.hasSpeech(cuts[0].stats))
    }

    func testShortGapBetweenWordsDoesNotCut() {
        var segmenter = SpeechSegmenter()
        var t: TimeInterval = 0
        var cuts = feed(&segmenter, rms: speech, seconds: 5, elapsed: &t)
        cuts += feed(&segmenter, rms: silence, seconds: 0.25, elapsed: &t)
        cuts += feed(&segmenter, rms: speech, seconds: 2, elapsed: &t)
        XCTAssertTrue(cuts.isEmpty)
    }

    func testAcceptsShorterPauseInLongChunks() {
        var segmenter = SpeechSegmenter()
        var t: TimeInterval = 0
        XCTAssertTrue(feed(&segmenter, rms: speech, seconds: 16, elapsed: &t).isEmpty)
        let cuts = feed(&segmenter, rms: silence, seconds: 0.2, elapsed: &t)
        XCTAssertEqual(cuts.count, 1)
    }

    func testForcesCutAtMaximumDurationDuringContinuousSpeech() {
        var segmenter = SpeechSegmenter()
        var t: TimeInterval = 0
        let cuts = feed(&segmenter, rms: speech, seconds: 60, elapsed: &t)
        XCTAssertEqual(cuts.count, 2)
        for cut in cuts {
            XCTAssertEqual(cut.stats.duration, 25, accuracy: 0.05)
            XCTAssertLessThan(cut.stats.duration, 30, "must stay inside Whisper's window")
        }
    }

    func testSilentChunkIsTaggedWithoutSpeech() {
        var segmenter = SpeechSegmenter()
        var t: TimeInterval = 0
        let cuts = feed(&segmenter, rms: silence, seconds: 6, elapsed: &t)
        XCTAssertEqual(cuts.count, 1)
        XCTAssertFalse(segmenter.hasSpeech(cuts[0].stats))
        XCTAssertEqual(cuts[0].stats.speechDuration, 0, accuracy: 0.001)
    }

    func testFinishChunkReturnsRemainderAndResets() {
        var segmenter = SpeechSegmenter()
        var t: TimeInterval = 0
        feed(&segmenter, rms: speech, seconds: 1, elapsed: &t)
        let stats = segmenter.finishChunk()
        XCTAssertEqual(stats.duration, 1, accuracy: 0.05)
        XCTAssertTrue(segmenter.hasSpeech(stats))
        XCTAssertEqual(segmenter.finishChunk(), SpeechSegmenter.ChunkStats())
    }

    func testAdaptsToNoisyRoomButNeverTreatsSpeechAsSilence() {
        var segmenter = SpeechSegmenter()
        var t: TimeInterval = 0
        let noise: Float = 0.004  // ≈ -48 dBFS room noise
        feed(&segmenter, rms: noise, seconds: 2, elapsed: &t)
        XCTAssertEqual(segmenter.silenceThreshold, noise * 3, accuracy: 0.0005)

        // Long speech must not drag the threshold above speech level.
        feed(&segmenter, rms: speech, seconds: 20, elapsed: &t)
        XCTAssertLessThanOrEqual(segmenter.silenceThreshold, SpeechEnergy.maximumSilenceThreshold)
        XCTAssertLessThan(segmenter.silenceThreshold, speech)

        // Pauses at the room-noise level are still detected.
        var fresh = SpeechSegmenter()
        var t2: TimeInterval = 0
        feed(&fresh, rms: noise, seconds: 1, elapsed: &t2)
        feed(&fresh, rms: speech, seconds: 5, elapsed: &t2)
        XCTAssertEqual(feed(&fresh, rms: noise, seconds: 0.5, elapsed: &t2).count, 1)
    }

    func testFixedIntervalConfigurationCutsOnDurationOnly() {
        var configuration = SpeechSegmenter.Configuration()
        configuration.minimumChunkDuration = 4
        configuration.maximumChunkDuration = 4
        var segmenter = SpeechSegmenter(configuration: configuration)
        var t: TimeInterval = 0
        var cuts = feed(&segmenter, rms: speech, seconds: 2, elapsed: &t)
        cuts += feed(&segmenter, rms: silence, seconds: 2.5, elapsed: &t)
        cuts += feed(&segmenter, rms: speech, seconds: 4, elapsed: &t)
        XCTAssertEqual(cuts.count, 2)
        XCTAssertEqual(cuts[0].stats.duration, 4, accuracy: 0.05)
    }

    func testSilenceThresholdIsClamped() {
        XCTAssertEqual(SpeechEnergy.silenceThreshold(noiseFloor: nil), SpeechEnergy.minimumSilenceThreshold)
        XCTAssertEqual(SpeechEnergy.silenceThreshold(noiseFloor: 0), SpeechEnergy.minimumSilenceThreshold)
        XCTAssertEqual(SpeechEnergy.silenceThreshold(noiseFloor: 1), SpeechEnergy.maximumSilenceThreshold)
        XCTAssertEqual(SpeechEnergy.rms([0.5, -0.5]), 0.5, accuracy: 1e-6)
        XCTAssertEqual(SpeechEnergy.rms([Float]()), 0)
    }
}
