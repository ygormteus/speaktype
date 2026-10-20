import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

@MainActor
protocol MeetingCapturing: AnyObject {
    func start(directory: URL, mode: MeetingCaptureMode,
               onSegment: @escaping (MeetingAudioSegment) -> Void,
               onSourceState: @escaping (MeetingAudioSource, MeetingSourceState) -> Void,
               onLevel: @escaping (MeetingAudioSource, Float) -> Void,
               onFailure: @escaping (MeetingAudioSource, Bool) -> Void) async throws
    func stop() async
}

@MainActor
final class MeetingAudioCapture: NSObject, MeetingCapturing, SCStreamOutput, SCStreamDelegate {
    private var engine: AVAudioEngine?
    private var microphoneTapInstalled = false
    private var stream: SCStream?
    private var writers: [MeetingAudioSource: MeetingSegmentWriter] = [:]
    private var configurationObserver: NSObjectProtocol?
    private var segmentHandler: ((MeetingAudioSegment) -> Void)?
    private var sourceHandler: ((MeetingAudioSource, MeetingSourceState) -> Void)?
    private var failureHandler: ((MeetingAudioSource, Bool) -> Void)?
    private var active = false
    private var stopping = false
    private var epoch: TimeInterval = 0
    private let systemQueue = DispatchQueue(label: "speaktype.meeting.system")
    nonisolated private let systemSink = MeetingSystemAudioSink()

    func start(directory: URL, mode: MeetingCaptureMode,
               onSegment: @escaping (MeetingAudioSegment) -> Void,
               onSourceState: @escaping (MeetingAudioSource, MeetingSourceState) -> Void,
               onLevel: @escaping (MeetingAudioSource, Float) -> Void,
               onFailure: @escaping (MeetingAudioSource, Bool) -> Void) async throws {
        guard !active else { throw MeetingError.busy }
        active = true
        stopping = false
        segmentHandler = onSegment
        sourceHandler = onSourceState
        failureHandler = onFailure
        do {
            var granted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            if !granted { granted = await AVCaptureDevice.requestAccess(for: .audio) }
            guard granted else { throw MeetingError.unavailable(String(localized: "Allow microphone access in System Settings → Privacy & Security → Microphone.")) }
            var filter: SCContentFilter?
            if mode == .online {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    throw MeetingError.unavailable(String(localized: "System audio capture requires an available display."))
                }
                filter = SCContentFilter(display: display, excludingWindows: [])
            }
            epoch = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            let sharedEpoch = epoch
            for source in mode == .online ? MeetingAudioSource.allCases : [.microphone] {
                onSourceState(source, .preparing)
                writers[source] = MeetingSegmentWriter(directory: directory, source: source, onSegment: { segment in
                    Task { @MainActor in onSegment(segment) }
                }, onFailure: { source, storage in
                    Task { @MainActor in onFailure(source, storage) }
                }, onLevel: { source, level in
                    Task { @MainActor in onLevel(source, level) }
                })
            }
            let audioEngine = AVAudioEngine()
            engine = audioEngine
            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0, let microphoneWriter = writers[.microphone] else {
                throw MeetingError.unavailable(String(localized: "No working microphone was found."))
            }
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
                let timestamp = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : CMClockGetTime(CMClockGetHostTimeClock()).seconds
                microphoneWriter.submit(buffer, offset: max(0, timestamp - sharedEpoch))
            }
            microphoneTapInstalled = true
            try audioEngine.start()
            onSourceState(.microphone, .active)
            configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.active, !self.stopping else { return }
                    self.failureHandler?(.microphone, false)
                }
            }
            if let filter {
                systemSink.configure(writer: writers[.system], epoch: sharedEpoch)
                let configuration = SCStreamConfiguration()
                configuration.capturesAudio = true
                configuration.excludesCurrentProcessAudio = true
                configuration.sampleRate = 16_000
                configuration.channelCount = 1
                configuration.width = 2
                configuration.height = 2
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                let capture = SCStream(filter: filter, configuration: configuration, delegate: self)
                stream = capture
                try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
                try await capture.startCapture()
                onSourceState(.system, .active)
            }
        } catch {
            await stop()
            if let known = error as? MeetingError { throw known }
            throw MeetingError.unavailable(String(localized: "Audio capture could not start. For online meetings, allow Screen & System Audio Recording in System Settings → Privacy & Security, then try again."))
        }
    }

    func stop() async {
        guard active, !stopping else { return }
        stopping = true
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if microphoneTapInstalled { engine?.inputNode.removeTap(onBus: 0) }
        microphoneTapInstalled = false
        engine?.stop()
        engine = nil
        if let stream {
            do { try await stream.stopCapture() }
            catch { failureHandler?(.system, false) }
        }
        stream = nil
        systemSink.configure(writer: nil, epoch: 0)
        for (source, writer) in writers {
            let result = await writer.finish()
            for segment in result.segments { segmentHandler?(segment) }
            if let storage = result.failureStorage { failureHandler?(source, storage) }
            sourceHandler?(source, .stopped)
        }
        writers.removeAll()
        active = false
        stopping = false
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let buffer = Self.pcmBuffer(sampleBuffer) else { return }
        systemSink.submit(buffer, timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.active, !self.stopping else { return }
            self.failureHandler?(.system, false)
        }
    }

    nonisolated private static func pcmBuffer(_ sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sample.formatDescription,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: basic), sample.numSamples > 0,
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sample.numSamples))
        else { return nil }
        var size = 0
        var block: CMBlockBuffer?
        let flags = UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment)
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: &size,
            bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: flags, blockBufferOut: &block) == noErr else { return nil }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: nil,
            bufferListOut: list, bufferListSize: size, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: flags, blockBufferOut: &block) == noErr else { return nil }
        output.frameLength = AVAudioFrameCount(sample.numSamples)
        let source = UnsafeMutableAudioBufferListPointer(list)
        let target = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
        guard source.count == target.count else { return nil }
        for index in source.indices {
            guard let input = source[index].mData, let destination = target[index].mData,
                  source[index].mDataByteSize <= target[index].mDataByteSize else { return nil }
            memcpy(destination, input, Int(source[index].mDataByteSize))
        }
        return output
    }
}

nonisolated struct MeetingCaptureCompletion: Sendable {
    let segments: [MeetingAudioSegment]
    let failureStorage: Bool?
}

nonisolated private struct OwnedMeetingPCMBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

nonisolated private final class MeetingSystemAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: MeetingSegmentWriter?
    private var epoch: TimeInterval = 0
    func configure(writer: MeetingSegmentWriter?, epoch: TimeInterval) {
        lock.lock()
        self.writer = writer
        self.epoch = epoch
        lock.unlock()
    }
    func submit(_ buffer: AVAudioPCMBuffer, timestamp: TimeInterval) {
        lock.lock()
        let target = writer
        let start = epoch
        lock.unlock()
        target?.submit(buffer, offset: max(0, timestamp - start))
    }
}

nonisolated final class MeetingSegmentWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "speaktype.meeting.writer")
    private let slots = DispatchSemaphore(value: 8)
    private let ingress = NSLock()
    private var accepting = true
    private let directory: URL
    private let source: MeetingAudioSource
    private let onSegment: @Sendable (MeetingAudioSegment) -> Void
    private let onFailure: @Sendable (MeetingAudioSource, Bool) -> Void
    private let onLevel: @Sendable (MeetingAudioSource, Float) -> Void
    private var converter: AVAudioConverter?
    private let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private var file: AVAudioFile?
    private var segment: MeetingAudioSegment?
    private var lastEnd: TimeInterval = 0
    private var receivedAudio = false
    private var lastLevelTime: TimeInterval = -.infinity
    private var segmenter: SpeechSegmenter = {
        var configuration = SpeechSegmenter.Configuration()
        configuration.minimumChunkDuration = 3
        configuration.maximumChunkDuration = 8
        configuration.pauseDuration = 0.4
        configuration.relaxedPauseAfter = 6
        configuration.relaxedPauseDuration = 0.25
        return SpeechSegmenter(configuration: configuration)
    }()
    private var closed: [MeetingAudioSegment] = []
    private var failed = false
    private var failureStorage: Bool?

    init(directory: URL, source: MeetingAudioSource,
         onSegment: @escaping @Sendable (MeetingAudioSegment) -> Void,
         onFailure: @escaping @Sendable (MeetingAudioSource, Bool) -> Void,
         onLevel: @escaping @Sendable (MeetingAudioSource, Float) -> Void = { _, _ in }) {
        self.directory = directory
        self.source = source
        self.onSegment = onSegment
        self.onFailure = onFailure
        self.onLevel = onLevel
    }

    func submit(_ input: AVAudioPCMBuffer, offset: TimeInterval) {
        ingress.lock()
        defer { ingress.unlock() }
        guard accepting else { return }
        guard slots.wait(timeout: .now()) == .success else {
            queue.async { [self] in failed = true; failureStorage = true }
            onFailure(source, true)
            return
        }
        guard let copy = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength) else {
            slots.signal()
            onFailure(source, true)
            return
        }
        copy.frameLength = input.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        let targets = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in sourceBuffers.indices {
            if let destination = targets[index].mData, let data = sourceBuffers[index].mData {
                memcpy(destination, data, Int(sourceBuffers[index].mDataByteSize))
            }
        }
        let transfer = OwnedMeetingPCMBuffer(buffer: copy)
        queue.async { [self] in
            defer { slots.signal() }
            guard !failed else { return }
            do { try append(transfer.buffer, offset: offset) }
            catch { failed = true; failureStorage = true; file = nil; onFailure(source, true) }
        }
    }

    private func append(_ input: AVAudioPCMBuffer, offset: TimeInterval) throws {
        guard offset.isFinite else { throw MeetingError.invalidData }
        if receivedAudio, abs(offset - lastEnd) > 0.75 {
            try close()
            failed = true
            failureStorage = false
            onFailure(source, false)
            return
        }
        if converter?.inputFormat != input.format {
            try close()
            converter = AVAudioConverter(from: input.format, to: format)
        }
        let output = input.format == format ? input : try converted(input)
        guard output.frameLength > 0 else { return }
        if file == nil {
            let next = MeetingAudioSegment(source: source, start: offset, end: offset)
            segment = next
            file = try AVAudioFile(forWriting: directory.appendingPathComponent(next.id.uuidString + ".partial.wav"), settings: format.settings)
        }
        try file?.write(from: output)
        receivedAudio = true
        lastEnd = offset + Double(input.frameLength) / input.format.sampleRate
        let samples = output.floatChannelData.map { UnsafeBufferPointer(start: $0[0], count: Int(output.frameLength)) }
        let rms = samples.map(SpeechEnergy.rms) ?? 0
        if offset - lastLevelTime >= 0.1 {
            lastLevelTime = offset
            let level = min(1, max(0, (20 * log10(max(rms, 0.000_001)) + 55) / 45))
            onLevel(source, level)
        }
        if segmenter.process(rms: rms, duration: Double(output.frameLength) / format.sampleRate) != nil { try close() }
    }

    private func converted(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let converter,
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * 16_000 / input.format.sampleRate)) + 256)
        else { throw MeetingError.invalidData }
        let transfer = OwnedMeetingPCMBuffer(buffer: input)
        var inputOffset: AVAudioFrameCount = 0
        var conversionError: NSError?
        let result = converter.convert(to: output, error: &conversionError) { requested, status in
            guard inputOffset < transfer.buffer.frameLength else { status.pointee = .noDataNow; return nil }
            let count = min(AVAudioFrameCount(requested), transfer.buffer.frameLength - inputOffset)
            guard let slice = AVAudioPCMBuffer(pcmFormat: transfer.buffer.format, frameCapacity: count) else {
                status.pointee = .noDataNow
                return nil
            }
            slice.frameLength = count
            let sources = UnsafeMutableAudioBufferListPointer(transfer.buffer.mutableAudioBufferList)
            let targets = UnsafeMutableAudioBufferListPointer(slice.mutableAudioBufferList)
            let bytesPerFrame = Int(transfer.buffer.format.streamDescription.pointee.mBytesPerFrame)
            for index in sources.indices {
                guard let source = sources[index].mData, let destination = targets[index].mData else { continue }
                memcpy(destination, source.advanced(by: Int(inputOffset) * bytesPerFrame), Int(count) * bytesPerFrame)
            }
            inputOffset += count
            status.pointee = .haveData
            return slice
        }
        if let conversionError { throw conversionError }
        guard result != .error else { throw MeetingError.invalidData }
        return output
    }

    private func close() throws {
        guard let current = segment, file != nil else { return }
        file = nil
        let completed = MeetingAudioSegment(id: current.id, source: source, start: current.start, end: lastEnd)
        let final = directory.appendingPathComponent(completed.fileName)
        try JSONEncoder().encode(completed).write(to: directory.appendingPathComponent(completed.id.uuidString + ".segment.json"), options: .atomic)
        try FileManager.default.moveItem(at: directory.appendingPathComponent(current.id.uuidString + ".partial.wav"), to: final)
        closed.append(completed)
        segment = nil
        onSegment(completed)
    }

    func finish() async -> MeetingCaptureCompletion {
        await withCheckedContinuation { continuation in
            ingress.lock()
            accepting = false
            queue.async { [self] in
                do { try close() } catch { failureStorage = true; onFailure(source, true) }
                continuation.resume(returning: MeetingCaptureCompletion(segments: closed, failureStorage: failureStorage))
            }
            ingress.unlock()
        }
    }
}
