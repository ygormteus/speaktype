import Foundation

/// Energy thresholds shared by the live segmenter and the batch silence
/// trimmer, so "silence" means the same thing on both paths.
///
/// Levels are linear RMS of normalized samples (full scale = 1.0):
/// - `minimumSilenceThreshold` 0.003 ≈ -50 dBFS. A quiet room on a laptop mic
///   sits around -60…-55 dBFS, so anything below this is treated as silence
///   regardless of the measured noise floor.
/// - `maximumSilenceThreshold` 0.015 ≈ -36 dBFS. The adaptive threshold never
///   rises above this, so normal speech (roughly -30…-15 dBFS) is always
///   classified as voiced even in a noisy room where the floor estimate is
///   high. In such rooms pauses are simply detected less often and chunks
///   fall back to the max-duration cut.
/// - `noiseFloorMultiplier` 3 ≈ +10 dB above the estimated floor.
nonisolated enum SpeechEnergy {
    static let minimumSilenceThreshold: Float = 0.003
    static let maximumSilenceThreshold: Float = 0.015
    static let noiseFloorMultiplier: Float = 3

    static func silenceThreshold(noiseFloor: Float?) -> Float {
        guard let noiseFloor else { return minimumSilenceThreshold }
        return min(maximumSilenceThreshold, max(minimumSilenceThreshold, noiseFloor * noiseFloorMultiplier))
    }

    static func rms<C: Collection>(_ samples: C) -> Float where C.Element == Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
}

/// Decides where to cut a live recording into chunks for incremental Whisper
/// transcription. Pure and clock-free: callers feed it each capture buffer's
/// RMS and duration (in audio time, not wall time) and it answers whether the
/// chunk should be closed *after* that buffer.
///
/// Rules:
/// - Never cut before `minimumChunkDuration` (~4 s): short chunks lose the
///   context Whisper needs and multiply per-call overhead.
/// - After that, cut once the trailing silence reaches `pauseDuration`
///   (~350 ms), i.e. at a natural pause between phrases.
/// - After `relaxedPauseAfter` (~15 s) a shorter pause (~150 ms) is enough,
///   so long run-on speech still gets cut between words.
/// - Always cut at `maximumChunkDuration` (~25 s), safely inside Whisper's
///   30 s window.
///
/// The noise floor tracks the quietest recent buffers: it drops immediately
/// and rises slowly (time constant `noiseFloorRiseTime`), so a burst of
/// speech barely moves it. Combined with the capped threshold in
/// `SpeechEnergy`, speech is never mistaken for silence.
nonisolated struct SpeechSegmenter {
    struct Configuration: Equatable {
        var minimumChunkDuration: TimeInterval = 4.0
        var pauseDuration: TimeInterval = 0.35
        var relaxedPauseAfter: TimeInterval = 15.0
        var relaxedPauseDuration: TimeInterval = 0.15
        var maximumChunkDuration: TimeInterval = 25.0
        /// A chunk with less voiced audio than this is tagged as silent and
        /// is not sent to Whisper, which tends to hallucinate on silence.
        var minimumSpeechDuration: TimeInterval = 0.3
        var noiseFloorRiseTime: TimeInterval = 10.0
    }

    /// Summary of the chunk being built, reported when it is cut.
    struct ChunkStats: Equatable {
        var duration: TimeInterval = 0
        var speechDuration: TimeInterval = 0
    }

    let configuration: Configuration
    private(set) var noiseFloor: Float?
    private(set) var current = ChunkStats()
    private var trailingSilence: TimeInterval = 0

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    var silenceThreshold: Float { SpeechEnergy.silenceThreshold(noiseFloor: noiseFloor) }

    /// True when the chunk so far contains enough voiced audio to transcribe.
    func hasSpeech(_ stats: ChunkStats) -> Bool {
        stats.speechDuration >= configuration.minimumSpeechDuration
    }

    /// Feeds one capture buffer. Returns the finished chunk's stats when the
    /// chunk should be closed after this buffer (the buffer belongs to the
    /// closing chunk), otherwise nil.
    mutating func process(rms: Float, duration: TimeInterval) -> ChunkStats? {
        guard duration > 0 else { return nil }
        // Classify against the floor *before* this buffer updates it, so a
        // first loud buffer is not its own reference.
        let isSilent = rms < silenceThreshold
        updateNoiseFloor(rms: rms, duration: duration)

        current.duration += duration
        if isSilent {
            trailingSilence += duration
        } else {
            trailingSilence = 0
            current.speechDuration += duration
        }

        guard shouldCut() else { return nil }
        let finished = current
        current = ChunkStats()
        trailingSilence = 0
        return finished
    }

    /// Closes the in-progress chunk (e.g. when recording stops).
    mutating func finishChunk() -> ChunkStats {
        let finished = current
        current = ChunkStats()
        trailingSilence = 0
        return finished
    }

    mutating func reset() {
        self = SpeechSegmenter(configuration: configuration)
    }

    private func shouldCut() -> Bool {
        let length = current.duration
        if length >= configuration.maximumChunkDuration { return true }
        guard length >= configuration.minimumChunkDuration else { return false }
        let requiredPause = length >= configuration.relaxedPauseAfter
            ? configuration.relaxedPauseDuration : configuration.pauseDuration
        return trailingSilence >= requiredPause
    }

    private mutating func updateNoiseFloor(rms: Float, duration: TimeInterval) {
        guard let floor = noiseFloor else {
            noiseFloor = rms
            return
        }
        if rms < floor {
            noiseFloor = rms
        } else {
            let alpha = Float(min(1, duration / configuration.noiseFloorRiseTime))
            noiseFloor = floor + (rms - floor) * alpha
        }
    }
}
