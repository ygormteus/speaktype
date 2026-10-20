import AVFoundation
import Foundation

/// Trims leading/trailing silence before batch transcription so the engine
/// doesn't spend time (or hallucinate) on dead air around the dictation. The
/// original file is never modified; History keeps it as recorded.
///
/// Silence detection works on 20 ms frames using `SpeechEnergy`: the noise
/// floor is the 10th-percentile frame RMS and the threshold is ~+10 dB above
/// it, clamped to [-50, -36] dBFS. Speech must last at least
/// `minimumSpeechDuration` in total, so a single click or pop is not speech.
nonisolated enum AudioTrimmer {
    static let frameDuration: TimeInterval = 0.02
    static let padding: TimeInterval = 0.15
    static let minimumSpeechDuration: TimeInterval = 0.1
    /// Below this much removable audio the original file is used as-is.
    static let minimumSavings: TimeInterval = 0.3

    enum Result: Equatable {
        /// No speech anywhere in the file.
        case silent
        /// Not worth trimming (or trimming failed); use the original.
        case unchanged
        /// A trimmed temporary copy the caller must delete.
        case trimmed(URL)
    }

    // MARK: - Pure logic

    static func frameRMS(samples: [Float], frameLength: Int) -> [Float] {
        guard frameLength > 0, !samples.isEmpty else { return [] }
        return stride(from: 0, to: samples.count, by: frameLength).map { start in
            SpeechEnergy.rms(samples[start..<min(start + frameLength, samples.count)])
        }
    }

    static func frameRMS(samples: [Int16], frameLength: Int) -> [Float] {
        frameRMS(samples: samples.map { Float($0) / Float(Int16.max) }, frameLength: frameLength)
    }

    /// Range of frames (inclusive of padding) that contains speech, or nil if
    /// the frames contain no speech at all.
    static func speechFrameRange(
        frameRMS: [Float],
        frameDuration: TimeInterval = frameDuration,
        padding: TimeInterval = padding,
        minimumSpeechDuration: TimeInterval = minimumSpeechDuration
    ) -> Range<Int>? {
        guard !frameRMS.isEmpty else { return nil }
        let sorted = frameRMS.sorted()
        let floor = sorted[min(sorted.count - 1, sorted.count / 10)]
        let threshold = SpeechEnergy.silenceThreshold(noiseFloor: floor)

        let voiced = frameRMS.indices.filter { frameRMS[$0] >= threshold }
        let minimumFrames = max(1, Int((minimumSpeechDuration / frameDuration).rounded(.up)))
        guard voiced.count >= minimumFrames, let first = voiced.first, let last = voiced.last
        else { return nil }

        let paddingFrames = Int((padding / frameDuration).rounded(.up))
        return max(0, first - paddingFrames)..<min(frameRMS.count, last + 1 + paddingFrames)
    }

    /// Sample range to keep, or nil if `samples` are all silence.
    static func speechSampleRange(samples: [Float], sampleRate: Double) -> Range<Int>? {
        let frameLength = max(1, Int(sampleRate * frameDuration))
        guard let frames = speechFrameRange(frameRMS: frameRMS(samples: samples, frameLength: frameLength))
        else { return nil }
        return (frames.lowerBound * frameLength)..<min(samples.count, frames.upperBound * frameLength)
    }

    static func speechSampleRange(samples: [Int16], sampleRate: Double) -> Range<Int>? {
        speechSampleRange(samples: samples.map { Float($0) / Float(Int16.max) }, sampleRate: sampleRate)
    }

    // MARK: - File I/O

    /// Analyzes `url` and, when worthwhile, writes the speech portion to a
    /// temporary 16-bit WAV. Reads in blocks so long imported files are never
    /// held in memory whole. Any I/O failure yields `.unchanged`.
    static func trimSilence(in url: URL) -> Result {
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let sampleRate = format.sampleRate
            let totalFrames = AVAudioFramePosition(file.length)
            guard sampleRate > 0, totalFrames > 0 else { return .unchanged }

            let frameLength = max(1, Int(sampleRate * frameDuration))
            let energies = try frameEnergies(of: file, frameLength: frameLength)
            guard let frames = speechFrameRange(frameRMS: energies) else { return .silent }

            let start = AVAudioFramePosition(frames.lowerBound * frameLength)
            let end = min(totalFrames, AVAudioFramePosition(frames.upperBound * frameLength))
            let removed = Double(totalFrames - (end - start)) / sampleRate
            guard removed >= minimumSavings, end > start else { return .unchanged }

            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("speaktype-trim-\(UUID().uuidString).wav")
            do {
                try copyFrames(from: file, range: start..<end, to: output)
            } catch {
                try? FileManager.default.removeItem(at: output)
                throw error
            }
            return .trimmed(output)
        } catch {
            print("⚠️ Silence trim skipped: \(error.localizedDescription)")
            return .unchanged
        }
    }

    private static let blockFrames: AVAudioFrameCount = 16_384

    /// Per-frame RMS of the channel-averaged signal.
    private static func frameEnergies(of file: AVAudioFile, frameLength: Int) throws -> [Float] {
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames) else {
            throw CocoaError(.fileReadUnknown)
        }
        file.framePosition = 0
        var energies: [Float] = []
        var pendingCount = 0
        var sumSquares: Float = 0

        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: blockFrames)
            let count = Int(buffer.frameLength)
            guard count > 0, let channels = buffer.floatChannelData else { break }
            let channelCount = Int(format.channelCount)
            for index in 0..<count {
                var sample: Float = 0
                for channel in 0..<channelCount { sample += channels[channel][index] }
                sample /= Float(channelCount)
                sumSquares += sample * sample
                pendingCount += 1
                if pendingCount == frameLength {
                    energies.append((sumSquares / Float(frameLength)).squareRoot())
                    pendingCount = 0
                    sumSquares = 0
                }
            }
        }
        if pendingCount > 0 {
            energies.append((sumSquares / Float(pendingCount)).squareRoot())
        }
        return energies
    }

    private static func copyFrames(
        from file: AVAudioFile, range: Range<AVAudioFramePosition>, to output: URL
    ) throws {
        let format = file.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let writer = try AVAudioFile(
            forWriting: output, settings: settings,
            commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames) else {
            throw CocoaError(.fileWriteUnknown)
        }
        file.framePosition = range.lowerBound
        while file.framePosition < range.upperBound {
            let remaining = AVAudioFrameCount(range.upperBound - file.framePosition)
            try file.read(into: buffer, frameCount: min(blockFrames, remaining))
            guard buffer.frameLength > 0 else { break }
            try writer.write(from: buffer)
        }
    }
}
