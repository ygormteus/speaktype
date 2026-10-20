import AVFoundation
import Combine
import CoreMedia
import Foundation

/// A completed slice of the current recording, written to its own WAV file.
nonisolated struct RecordedAudioChunk: Equatable {
    let url: URL
    /// 0-based position within the recording.
    let index: Int
    let duration: TimeInterval
    /// False when the segmenter heard (almost) no speech in this chunk.
    let hasSpeech: Bool
    /// True when the chunk was cut at the maximum length instead of at a
    /// pause, so the next chunk may start mid-word.
    let endedByForcedCut: Bool
}

/// How the last recording was split into chunks. `chunkCount` counts every
/// chunk that was closed, including ones whose file could not be written, so
/// a consumer that received fewer chunks knows the chunks are incomplete.
nonisolated struct RecordedChunkSummary: Equatable {
    let chunkCount: Int
    /// True if any captured buffer reached the full recording but not a chunk.
    let hasGaps: Bool

    var isUsable: Bool { !hasGaps && chunkCount > 0 }
}

class AudioRecordingService: NSObject, ObservableObject {
    static let shared = AudioRecordingService()  // Shared instance for settings/dashboard sync

    // Chunk publisher: emits each completed audio chunk while recording, always
    // on the main thread. Every chunk is delivered before `stopRecording`
    // returns; `lastChunkSummary` then says how many there were.
    let chunkPublisher = PassthroughSubject<RecordedAudioChunk, Never>()
    let livePCMChunkPublisher = PassthroughSubject<[Float], Never>()
    private static let defaultChunkDuration: TimeInterval = 4.0
    private var chunkDuration: TimeInterval = defaultChunkDuration
    /// When true, chunks are cut at natural pauses by `SpeechSegmenter`
    /// (incremental Whisper); otherwise every `chunkDuration` seconds.
    private var speechSegmentedChunking = false
    private var segmenter = SpeechSegmenter()
    private var closedChunkCount = 0
    private var chunkGapDetected = false
    /// Tracks rotated chunk writers that are still finishing, so
    /// `stopRecording` can wait until every chunk has been published.
    private let chunkFinishGroup = DispatchGroup()
    /// Chunking result of the most recent `stopRecording`.
    private(set) var lastChunkSummary: RecordedChunkSummary?
    private var directStreamingEnabled = false
    private var directStreamingSamples: [Float] = []
    /// 560 ms at 16 kHz. FluidAudio buffers to the model chunk internally, so
    /// this only needs to evenly divide every Nemotron chunk (560/1120/2240 ms).
    static let directStreamingChunkSamples = 8_960

    @Published var isRecording = false
    @Published var audioLevel: Float = 0.0
    @Published var audioFrequency: Float = 0.0  // Normalized 0...1 representation of pitch
    /// Rolling window of recent normalized mic levels for the live waveform UI.
    /// Updated on every audio buffer while recording (independent of any view timer).
    @Published var liveWaveSamples: [Float] = []
    private static let maxLiveWaveSamples = 48
    @Published var availableDevices: [AVCaptureDevice] = []
    @Published var selectedDeviceId: String? {
        didSet {
            setupSession()
            // Persist so the selection survives app restarts.
            if let selectedDeviceId {
                UserDefaults.standard.set(selectedDeviceId, forKey: Self.selectedDeviceDefaultsKey)
            }
        }
    }

    private static let selectedDeviceDefaultsKey = "selectedAudioDeviceId"

    private var captureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    public private(set) var recordingStartTime: Date?
    private var currentFileURL: URL?
    private var isSessionStarted = false
    private var setupTask: Task<Void, Never>?
    private var isStopping = false  // Flag to prevent appending during stop
    private var idleSessionStopWorkItem: DispatchWorkItem?

    // MARK: - Chunking state
    private var chunkAssetWriter: AVAssetWriter?
    private var chunkAssetWriterInput: AVAssetWriterInput?
    private var chunkIsSessionStarted = false
    private var chunkFileURL: URL?
    private var isRotatingChunk = false  // Prevents concurrent rotations
    private var shouldDiscardCurrentRecordingOutput = false
    private var smoothedAudioLevel: Float = 0.0
    private var smoothedAudioFrequency: Float = 0.0

    private let audioQueue = DispatchQueue(label: "com.speaktype.audioQueue")
    private let microphoneAuthorizationStatus: () -> AVAuthorizationStatus
    private let requestMicrophoneAccess: (@escaping (Bool) -> Void) -> Void

    /// Batch models do not need frequent chunk files. A streaming engine can
    /// request shorter chunks before recording starts to lower partial-text
    /// latency without changing the final recording quality.
    func setChunkDuration(_ duration: TimeInterval) {
        audioQueue.async {
            self.chunkDuration = max(0.25, duration)
        }
    }

    func restoreDefaultChunkDuration() {
        setChunkDuration(Self.defaultChunkDuration)
        setSpeechSegmentedChunking(false)
    }

    /// Cut chunks at speech pauses (see `SpeechSegmenter`) instead of fixed
    /// intervals. Set before `startRecording`.
    func setSpeechSegmentedChunking(_ enabled: Bool) {
        audioQueue.async {
            self.speechSegmentedChunking = enabled
        }
    }

    /// Segmenter rules for the current mode. Fixed-interval mode reuses the
    /// segmenter with min == max, so it only ever cuts on duration.
    private func makeSegmenter() -> SpeechSegmenter {
        guard !speechSegmentedChunking else { return SpeechSegmenter() }
        var configuration = SpeechSegmenter.Configuration()
        configuration.minimumChunkDuration = chunkDuration
        configuration.maximumChunkDuration = chunkDuration
        return SpeechSegmenter(configuration: configuration)
    }

    func setDirectStreamingEnabled(_ enabled: Bool) {
        audioQueue.async {
            self.directStreamingEnabled = enabled
            self.directStreamingSamples.removeAll(keepingCapacity: true)
        }
    }

    private func validatedAudioFileURL(
        at url: URL,
        writer: AVAssetWriter?,
        label: String
    ) -> URL? {
        if let writer {
            switch writer.status {
            case .completed:
                break
            case .failed:
                AppLogger.error(
                    "\(label) writer failed",
                    error: writer.error,
                    category: AppLogger.audio
                )
                return nil
            case .cancelled:
                AppLogger.warning("\(label) writer was cancelled", category: AppLogger.audio)
                return nil
            default:
                AppLogger.warning(
                    "\(label) writer finished with status \(String(describing: writer.status.rawValue))",
                    category: AppLogger.audio
                )
                return nil
            }
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            AppLogger.warning("\(label) file missing after finishWriting", category: AppLogger.audio)
            return nil
        }

        do {
            _ = try AVAudioFile(forReading: url)
            return url
        } catch {
            AppLogger.error(
                "\(label) file is unreadable after finishWriting",
                error: error,
                category: AppLogger.audio
            )
            return nil
        }
    }

    private func resetMainWriterState() {
        assetWriter = nil
        assetWriterInput = nil
        currentFileURL = nil
        isSessionStarted = false
        smoothedAudioLevel = 0.0
        smoothedAudioFrequency = 0.0
    }

    private func resetChunkWriterState() {
        chunkAssetWriter = nil
        chunkAssetWriterInput = nil
        chunkIsSessionStarted = false
        chunkFileURL = nil
        isRotatingChunk = false
    }

    init(
        microphoneAuthorizationStatus: @escaping () -> AVAuthorizationStatus = {
            AVCaptureDevice.authorizationStatus(for: .audio)
        },
        requestMicrophoneAccess: @escaping (@escaping (Bool) -> Void) -> Void = {
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: $0)
        }
    ) {
        self.microphoneAuthorizationStatus = microphoneAuthorizationStatus
        self.requestMicrophoneAccess = requestMicrophoneAccess
        super.init()
        // Restore the persisted device before discovery completes; AVCaptureDevice(uniqueID:)
        // resolves it directly, and fetchAvailableDevices() falls back if it is gone.
        // (didSet does not fire during init, matching the previous lazy session setup.)
        selectedDeviceId = UserDefaults.standard.string(forKey: Self.selectedDeviceDefaultsKey)
        fetchAvailableDevices()
        if selectedDeviceId == nil, let first = availableDevices.first {
            selectedDeviceId = first.uniqueID
        }

        // Listen for device changes (plug/unplug)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDeviceChange),
            name: AVCaptureDevice.wasConnectedNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDeviceChange),
            name: AVCaptureDevice.wasDisconnectedNotification,
            object: nil
        )
    }

    @objc private func handleDeviceChange(_ notification: Notification) {
        print("Audio device change detected")
        fetchAvailableDevices()
    }

    func fetchAvailableDevices() {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        DispatchQueue.main.async {
            self.availableDevices = discoverySession.devices.filter { device in
                !device.localizedName.localizedCaseInsensitiveContains("Microsoft Teams")
            }
            // Keep the current (possibly persisted) selection if it is still
            // connected; otherwise fall back to the first available device, or
            // clear it when no inputs remain.
            let selectionIsAvailable = self.availableDevices.contains {
                $0.uniqueID == self.selectedDeviceId
            }
            if !selectionIsAvailable {
                if let first = self.availableDevices.first {
                    print("🎤 Falling back to available input device: \(first.localizedName)")
                    self.selectedDeviceId = first.uniqueID
                } else {
                    self.selectedDeviceId = nil
                }
            }
        }
    }

    func setupSession() {
        captureSession?.stopRunning()
        captureSession = AVCaptureSession()

        guard let deviceId = selectedDeviceId,
            let device = AVCaptureDevice(uniqueID: deviceId),
            let input = try? AVCaptureDeviceInput(device: device)
        else {
            print("Failed to find or add device with ID: \(selectedDeviceId ?? "nil")")
            return
        }

        if captureSession?.canAddInput(input) == true {
            captureSession?.addInput(input)
        }

        audioOutput = AVCaptureAudioDataOutput()
        // Pin a fixed Linear PCM output format so the live level meter always sees a
        // known sample layout. Without this, AVCaptureAudioDataOutput delivers the
        // device's *native* format, which a communication app (Zoom/FaceTime/Meet)
        // can switch mid-call to a layout processAudioLevel can't decode. The file
        // writer keeps working (it appends buffers as-is, so transcription is fine),
        // but the waveform flatlines to 0 — text works, no waveform. Forcing 16-bit
        // interleaved PCM keeps the meter fed regardless of what else holds the mic.
        audioOutput?.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        if captureSession?.canAddOutput(audioOutput!) == true {
            captureSession?.addOutput(audioOutput!)
            audioOutput?.setSampleBufferDelegate(self, queue: audioQueue)
        }

        // Don't start session here - only start when recording begins
        // This prevents continuous CPU usage when idle
    }

    /// Pre-warm the capture session so first recording starts instantly
    func prewarmSession() {
        if captureSession == nil { setupSession() }

        audioQueue.async {
            guard let session = self.captureSession, !session.isRunning else { return }
            print("🎤 Pre-warming audio capture session...")
            session.startRunning()
            // Give it a moment to fully initialize
            Thread.sleep(forTimeInterval: 0.3)
            print("🎤 Audio capture session ready")
            self.scheduleIdleSessionStop()
        }
    }

    /// Stop the prewarmed capture session when the recorder is no longer visible.
    func stopSessionIfIdle() {
        audioQueue.async {
            self.cancelIdleSessionStop()
            guard !self.isRecording, let session = self.captureSession, session.isRunning else {
                return
            }
            print("🎤 Stopping idle audio capture session")
            session.stopRunning()
        }
    }

    @MainActor
    func startRecording() async -> Bool {
        guard !isRecording else { return false }
        guard await hasMicrophoneAccess() else { return false }
        if captureSession == nil { setupSession() }

        // 1. Reset flags and stale writer state before any new samples arrive.
        isStopping = false
        shouldDiscardCurrentRecordingOutput = false
        liveWaveSamples = []
        resetMainWriterState()
        resetChunkWriterState()
        directStreamingSamples.removeAll(keepingCapacity: true)
        lastChunkSummary = nil
        AudioPlayerService.shared.stop()
        isRecording = true
        recordingStartTime = Date()
        // Hop onto audioQueue: idleSessionStopWorkItem and the chunking state
        // are only ever touched there, and startRecording runs on the main thread.
        audioQueue.async {
            self.cancelIdleSessionStop()
            self.segmenter = self.makeSegmenter()
            self.closedChunkCount = 0
            self.chunkGapDetected = false
        }

        // 2. Wrap setup in a Task so stopRecording can wait for it
        setupTask = Task { @MainActor in
            // Ensure the capture session is running before setting up the writer.
            let didColdStart = await withCheckedContinuation {
                (continuation: CheckedContinuation<Bool, Never>) in
                audioQueue.async {
                    if self.captureSession?.isRunning != true {
                        print("🎤 Starting capture session...")
                        self.captureSession?.startRunning()
                        continuation.resume(returning: true)
                    } else {
                        continuation.resume(returning: false)
                    }
                }
            }
            // Let the session settle before wiring the writer — but do NOT block the
            // audio queue to do it. The capture delegate is delivered on `audioQueue`;
            // the old code slept 0.3s ON that queue, so no buffers could arrive while
            // it slept and the live waveform stayed empty for the first ~0.3s of every
            // recording (text still worked — the writer just starts on the first
            // buffer). Awaiting off-queue lets buffers, and the meter, flow while we
            // wait, so the waveform is alive from the first frame.
            if didColdStart {
                try? await Task.sleep(nanoseconds: 300_000_000)
                print("🎤 Capture session started")
            }

            let url = getRecordingsDirectory().appendingPathComponent(
                "recording-\(Date().timeIntervalSince1970).wav")
            currentFileURL = url

            do {
                assetWriter = try AVAssetWriter(outputURL: url, fileType: .wav)

                // Use standard WAV format compatible with WhisperKit
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 16000.0,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]

                assetWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
                assetWriterInput?.expectsMediaDataInRealTime = true

                if assetWriter?.canAdd(assetWriterInput!) == true {
                    assetWriter?.add(assetWriterInput!)
                }

                assetWriter?.startWriting()
                isSessionStarted = false

                DispatchQueue.main.async {
                    self.audioLevel = 0.0
                    self.audioFrequency = 0.0
                }

                print("Recording started: \(url.lastPathComponent)")

            } catch {
                print("Error starting recording: \(error)")
                isRecording = false  // Revert if failed
                audioQueue.async {
                    self.captureSession?.stopRunning()
                }
            }
        }

        return true
    }

    func stopRecording(discardOutput: Bool = false) async -> URL? {
        // Wait for setup to complete if it's running
        _ = await setupTask?.value

        guard isRecording, let url = currentFileURL else { return nil }
        shouldDiscardCurrentRecordingOutput = discardOutput

        // Ensure minimum recording duration to prevent empty/corrupted WAV files
        if let startTime = currentFileURL?.path.components(separatedBy: "-").last?
            .replacingOccurrences(of: ".wav", with: ""),
            let startTimestamp = Double(startTime)
        {
            let duration = Date().timeIntervalSince1970 - startTimestamp
            if duration < 0.5 {
                try? await Task.sleep(nanoseconds: UInt64((0.5 - duration) * 1_000_000_000))
            }
        }

        // Set stopping flag BEFORE anything else to prevent race conditions
        isStopping = true
        isRecording = false  // Stop capturing new frames immediately
        recordingStartTime = nil
        DispatchQueue.main.async {
            self.audioLevel = 0.0
            self.audioFrequency = 0.0
        }

        let result: StopResult = await withCheckedContinuation { continuation in
            audioQueue.async {
                // --- Finalize the last in-flight chunk ---
                let finishGroup = DispatchGroup()
                var finalizedRecordingURL: URL?
                var finalChunk: RecordedAudioChunk?
                let discardOutput = self.shouldDiscardCurrentRecordingOutput
                // The PCM tail is handed back to the caller's actor below
                // instead of being posted asynchronously, so it is delivered
                // before this method returns.
                var pcmTail: [Float] = []
                if self.directStreamingEnabled, !discardOutput {
                    pcmTail = self.takeDirectStreamingTail()
                } else {
                    self.directStreamingSamples.removeAll(keepingCapacity: true)
                }

                // Rotated chunks still finishing must publish before we return.
                finishGroup.enter()
                self.chunkFinishGroup.notify(queue: self.audioQueue) { finishGroup.leave() }

                if let lastChunkInput = self.chunkAssetWriterInput,
                    let lastChunkWriter = self.chunkAssetWriter,
                    let lastChunkURL = self.chunkFileURL,
                    self.chunkIsSessionStarted
                {
                    self.resetChunkWriterState()
                    let stats = self.segmenter.finishChunk()
                    let index = self.closedChunkCount
                    self.closedChunkCount += 1

                    finishGroup.enter()
                    lastChunkInput.markAsFinished()
                    lastChunkWriter.finishWriting {
                        self.audioQueue.async {
                            if discardOutput {
                                try? FileManager.default.removeItem(at: lastChunkURL)
                            } else if let validChunkURL = self.validatedAudioFileURL(
                                at: lastChunkURL,
                                writer: lastChunkWriter,
                                label: "Final chunk"
                            ) {
                                print("🔪 Final chunk saved: \(validChunkURL.lastPathComponent)")
                                finalChunk = self.makeChunk(
                                    url: validChunkURL, index: index, stats: stats, isFinal: true)
                            } else {
                                try? FileManager.default.removeItem(at: lastChunkURL)
                            }
                            finishGroup.leave()
                        }
                    }
                } else if let unusedChunkURL = self.chunkFileURL {
                    // A writer opened by the last rotation that never received audio.
                    self.chunkAssetWriter?.cancelWriting()
                    self.resetChunkWriterState()
                    try? FileManager.default.removeItem(at: unusedChunkURL)
                }

                // --- Finalize main (full) recording ---
                let writer = self.assetWriter
                let writerInput = self.assetWriterInput
                self.resetMainWriterState()

                if let writer {
                    finishGroup.enter()
                    writerInput?.markAsFinished()
                    writer.finishWriting {
                        self.audioQueue.async {
                            if discardOutput {
                                try? FileManager.default.removeItem(at: url)
                            } else {
                                finalizedRecordingURL = self.validatedAudioFileURL(
                                    at: url,
                                    writer: writer,
                                    label: "Recording"
                                )
                                if let finalizedRecordingURL {
                                    print("Recording finished saving to \(finalizedRecordingURL.path)")
                                } else {
                                    try? FileManager.default.removeItem(at: url)
                                }
                            }
                            finishGroup.leave()
                        }
                    }
                }

                finishGroup.notify(queue: self.audioQueue) {
                    // Keep microphone fully idle outside active recordings.
                    self.cancelIdleSessionStop()
                    self.captureSession?.stopRunning()
                    self.isStopping = false
                    self.shouldDiscardCurrentRecordingOutput = false
                    let summary = RecordedChunkSummary(
                        chunkCount: self.closedChunkCount, hasGaps: self.chunkGapDetected)
                    continuation.resume(returning: StopResult(
                        url: finalizedRecordingURL, finalChunk: finalChunk,
                        pcmTail: pcmTail, chunkSummary: summary))
                }
            }
        }

        // Deliver the tail synchronously on the main actor: subscribers run
        // inside `send`, so anything they enqueue exists before we return.
        // Rotated chunks were posted to the main queue before the continuation
        // resumed, so they still arrive in capture order ahead of these.
        await MainActor.run {
            if !result.pcmTail.isEmpty { self.livePCMChunkPublisher.send(result.pcmTail) }
            if let finalChunk = result.finalChunk { self.chunkPublisher.send(finalChunk) }
            self.lastChunkSummary = discardOutput ? nil : result.chunkSummary
        }
        return result.url
    }

    private struct StopResult {
        let url: URL?
        let finalChunk: RecordedAudioChunk?
        let pcmTail: [Float]
        let chunkSummary: RecordedChunkSummary
    }

    private func makeChunk(
        url: URL, index: Int, stats: SpeechSegmenter.ChunkStats, isFinal: Bool = false
    ) -> RecordedAudioChunk {
        RecordedAudioChunk(
            url: url, index: index, duration: stats.duration,
            hasSpeech: segmenter.hasSpeech(stats, isFinalChunk: isFinal),
            endedByForcedCut: stats.endedByForcedCut)
    }

    private func hasMicrophoneAccess() async -> Bool {
        switch microphoneAuthorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                requestMicrophoneAccess { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            print("Microphone access denied")
            return false
        }
    }

    private func getRecordingsDirectory() -> URL {
        // Use Application Support instead of Documents for app-managed storage
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]

        let recordingsDir =
            appSupport
            .appendingPathComponent("SpeakType")
            .appendingPathComponent("Recordings")

        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(
            at: recordingsDir,
            withIntermediateDirectories: true
        )

        return recordingsDir
    }

    private func getChunksDirectory() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]

        let chunksDir =
            appSupport
            .appendingPathComponent("SpeakType")
            .appendingPathComponent("Chunks")

        try? FileManager.default.createDirectory(
            at: chunksDir,
            withIntermediateDirectories: true
        )

        return chunksDir
    }

    private func scheduleIdleSessionStop(delay: TimeInterval = 8) {
        cancelIdleSessionStop()

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard !self.isRecording, let session = self.captureSession, session.isRunning else {
                return
            }
            print("🎤 Auto-stopping prewarmed session to save resources")
            session.stopRunning()
        }

        idleSessionStopWorkItem = work
        audioQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelIdleSessionStop() {
        idleSessionStopWorkItem?.cancel()
        idleSessionStopWorkItem = nil
    }
}

extension AudioRecordingService: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Only process audio when actually recording (saves CPU)
        guard isRecording else { return }

        let rms = processAudioLevel(from: sampleBuffer) ?? 0

        // Don't append if we're stopping - prevents race condition crash.
        // `isStopping` is set from another thread; read it once so a buffer
        // goes either to both the full recording and the chunk, or to neither.
        guard !isStopping else { return }
        guard let writer = assetWriter, let input = assetWriterInput else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // --- Main writer (full recording) ---
        var appendedToRecording = false
        if writer.status == .writing {
            if !isSessionStarted {
                writer.startSession(atSourceTime: pts)
                isSessionStarted = true
            }

            if input.isReadyForMoreMediaData {
                appendedToRecording = input.append(sampleBuffer)
            }
        }

        // --- Chunk writer (background segments) ---
        appendToChunk(
            sampleBuffer: sampleBuffer, pts: pts, rms: rms,
            appendedToRecording: appendedToRecording)
    }

    // MARK: - Chunk Writer Helpers (audioQueue)

    /// Appends the buffer to the current chunk and closes the chunk when the
    /// segmenter says so. Seams: the buffer that triggers a cut is the last
    /// one in the closing chunk, and the next chunk's session starts at the
    /// *next* buffer's PTS, so every buffer lands in exactly one chunk.
    private func appendToChunk(
        sampleBuffer: CMSampleBuffer, pts: CMTime, rms: Float, appendedToRecording: Bool
    ) {
        guard !directStreamingEnabled else { return }

        // Initialize first chunk on first buffer
        if chunkAssetWriter == nil {
            startNewChunkWriter()
        }

        var appendedToChunk = false
        if let cw = chunkAssetWriter, let ci = chunkAssetWriterInput, cw.status == .writing {
            if !chunkIsSessionStarted {
                cw.startSession(atSourceTime: pts)
                chunkIsSessionStarted = true
            }
            if ci.isReadyForMoreMediaData {
                appendedToChunk = ci.append(sampleBuffer)
            }
        }
        // The chunks no longer add up to the full recording; consumers must
        // fall back to transcribing the full file.
        if appendedToRecording && !appendedToChunk {
            chunkGapDetected = true
        }
        guard appendedToChunk else { return }

        let sampleRate = CMSampleBufferGetFormatDescription(sampleBuffer)
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate }
            ?? 16_000
        let duration = Double(CMSampleBufferGetNumSamples(sampleBuffer)) / max(1, sampleRate)

        guard !isRotatingChunk,
            let stats = segmenter.process(rms: rms, duration: duration)
        else { return }

        rotateChunk(stats: stats)
    }

    private func startNewChunkWriter() {
        let url = getChunksDirectory().appendingPathComponent(
            "chunk-\(Date().timeIntervalSince1970).wav")
        chunkFileURL = url

        guard let cw = try? AVAssetWriter(outputURL: url, fileType: .wav) else { return }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let ci = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        ci.expectsMediaDataInRealTime = true

        if cw.canAdd(ci) { cw.add(ci) }
        cw.startWriting()

        chunkAssetWriter = cw
        chunkAssetWriterInput = ci
        chunkIsSessionStarted = false
    }

    private func rotateChunk(stats: SpeechSegmenter.ChunkStats) {
        isRotatingChunk = true

        guard let oldWriter = chunkAssetWriter,
            let oldInput = chunkAssetWriterInput,
            let finishedURL = chunkFileURL
        else {
            isRotatingChunk = false
            return
        }
        let index = closedChunkCount
        closedChunkCount += 1
        let chunk = makeChunk(url: finishedURL, index: index, stats: stats)

        // Detach before finishing so new samples go to the fresh writer
        chunkAssetWriter = nil
        chunkAssetWriterInput = nil
        chunkIsSessionStarted = false
        chunkFileURL = nil

        // Spin up the next chunk immediately so no audio is lost
        startNewChunkWriter()
        isRotatingChunk = false

        // Finish the old writer asynchronously. The group lets stopRecording
        // wait until this chunk has been published.
        chunkFinishGroup.enter()
        oldInput.markAsFinished()
        oldWriter.finishWriting {
            self.audioQueue.async {
                defer { self.chunkFinishGroup.leave() }
                if self.shouldDiscardCurrentRecordingOutput {
                    try? FileManager.default.removeItem(at: finishedURL)
                } else if self.validatedAudioFileURL(
                    at: finishedURL, writer: oldWriter, label: "Chunk") != nil
                {
                    print("🔪 Chunk saved: \(finishedURL.lastPathComponent)")
                    DispatchQueue.main.async { self.chunkPublisher.send(chunk) }
                } else {
                    // Its index is never delivered, which consumers detect.
                    try? FileManager.default.removeItem(at: finishedURL)
                }
            }
        }
    }

    /// Updates the level meter and returns the buffer's RMS (0…1), or nil if
    /// the buffer could not be decoded.
    @discardableResult
    private func processAudioLevel(from sampleBuffer: CMSampleBuffer) -> Float? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
        else { return nil }

        var audioBufferListSizeNeeded = 0
        var blockBuffer: CMBlockBuffer?
        let bufferFlags = UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment)

        let sizeQueryStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &audioBufferListSizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: bufferFlags,
            blockBufferOut: &blockBuffer
        )

        guard sizeQueryStatus == noErr, audioBufferListSizeNeeded > 0 else { return nil }

        let audioBufferListStorage = UnsafeMutableRawPointer.allocate(
            byteCount: audioBufferListSizeNeeded,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { audioBufferListStorage.deallocate() }

        let audioBufferList = audioBufferListStorage.assumingMemoryBound(to: AudioBufferList.self)

        let bufferListStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &audioBufferListSizeNeeded,
            bufferListOut: audioBufferList,
            bufferListSize: audioBufferListSizeNeeded,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: bufferFlags,
            blockBufferOut: &blockBuffer
        )

        guard bufferListStatus == noErr else { return nil }

        let audioBuffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let sampleStride = 4
        var sumSquares: Float = 0.0
        var peakLevel: Float = 0.0  // max abs sample — drives the lively waveform
        var processedSampleCount = 0
        var zeroCrossings = 0
        var previousSample: Float?

        for audioBuffer in audioBuffers {
            guard let data = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else { continue }

            if (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0 {
                let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
                guard sampleCount > 0 else { continue }

                let samples = data.assumingMemoryBound(to: Float.self)
                for index in Swift.stride(from: 0, to: sampleCount, by: sampleStride) {
                    let sample = samples[index]
                    let amplitude = abs(sample)
                    sumSquares += sample * sample
                    peakLevel = max(peakLevel, amplitude)
                    if let previousSample,
                        (previousSample > 0 && sample <= 0) || (previousSample <= 0 && sample > 0)
                    {
                        zeroCrossings += 1
                    }
                    previousSample = sample
                    processedSampleCount += 1
                }
            } else if asbd.mBitsPerChannel == 16 {
                let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.size
                guard sampleCount > 0 else { continue }

                let samples = data.assumingMemoryBound(to: Int16.self)
                if directStreamingEnabled {
                    directStreamingSamples.append(contentsOf: UnsafeBufferPointer(
                        start: samples, count: sampleCount
                    ).map { Float($0) / Float(Int16.max) })
                    emitDirectStreamingChunksIfReady()
                }
                for index in Swift.stride(from: 0, to: sampleCount, by: sampleStride) {
                    let sample = Float(samples[index]) / Float(Int16.max)
                    let amplitude = abs(sample)
                    sumSquares += sample * sample
                    peakLevel = max(peakLevel, amplitude)
                    if let previousSample,
                        (previousSample > 0 && sample <= 0) || (previousSample <= 0 && sample > 0)
                    {
                        zeroCrossings += 1
                    }
                    previousSample = sample
                    processedSampleCount += 1
                }
            } else if asbd.mBitsPerChannel == 32 {
                let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int32>.size
                guard sampleCount > 0 else { continue }

                let samples = data.assumingMemoryBound(to: Int32.self)
                for index in Swift.stride(from: 0, to: sampleCount, by: sampleStride) {
                    let sample = Float(samples[index]) / Float(Int32.max)
                    let amplitude = abs(sample)
                    sumSquares += sample * sample
                    peakLevel = max(peakLevel, amplitude)
                    if let previousSample,
                        (previousSample > 0 && sample <= 0) || (previousSample <= 0 && sample > 0)
                    {
                        zeroCrossings += 1
                    }
                    previousSample = sample
                    processedSampleCount += 1
                }
            }
        }

        guard processedSampleCount > 0 else { return nil }

        let rms = sqrt(sumSquares / Float(processedSampleCount))

        // Convert to Decibels
        // 20 * log10(rms) gives dB.
        let dB = 20 * log10(rms > 0 ? rms : 0.0001)
        let peakDB = 20 * log10(peakLevel > 0 ? peakLevel : 0.0001)

        // Normalize to 0...1 for UI
        let lowerLimit: Float = -58.0
        let upperLimit: Float = 0.0

        let clamped = max(lowerLimit, min(upperLimit, dB))
        let peakClamped = max(lowerLimit, min(upperLimit, peakDB))

        let normalizedRMS = (clamped - lowerLimit) / (upperLimit - lowerLimit)
        let normalizedPeak = (peakClamped - lowerLimit) / (upperLimit - lowerLimit)
        var normalizedLevel = max(normalizedRMS * 0.8, normalizedPeak)

        if normalizedLevel < 0.015 {
            normalizedLevel = 0
            zeroCrossings = 0
        }

        let zcr = Float(zeroCrossings) / Float(processedSampleCount)
        var normalizedFreq = zcr * 4.0
        normalizedFreq = max(0.0, min(1.0, normalizedFreq))

        let levelSmoothing: Float = normalizedLevel > smoothedAudioLevel ? 0.55 : 0.18
        let frequencySmoothing: Float = normalizedFreq > smoothedAudioFrequency ? 0.45 : 0.2
        smoothedAudioLevel += (normalizedLevel - smoothedAudioLevel) * levelSmoothing
        smoothedAudioFrequency += (normalizedFreq - smoothedAudioFrequency) * frequencySmoothing

        DispatchQueue.main.async {
            self.audioLevel = self.smoothedAudioLevel
            self.audioFrequency = self.smoothedAudioFrequency
            self.liveWaveSamples.append(min(1.0, peakLevel))
            if self.liveWaveSamples.count > Self.maxLiveWaveSamples {
                self.liveWaveSamples.removeFirst(
                    self.liveWaveSamples.count - Self.maxLiveWaveSamples)
            }
        }
        return rms
    }

    private func emitDirectStreamingChunksIfReady() {
        while directStreamingSamples.count >= Self.directStreamingChunkSamples {
            let chunk = Array(directStreamingSamples.prefix(Self.directStreamingChunkSamples))
            directStreamingSamples.removeFirst(Self.directStreamingChunkSamples)
            DispatchQueue.main.async { self.livePCMChunkPublisher.send(chunk) }
        }
    }

    /// Removes and returns the samples not yet emitted as a full chunk.
    private func takeDirectStreamingTail() -> [Float] {
        let tail = directStreamingSamples
        directStreamingSamples.removeAll(keepingCapacity: true)
        return tail
    }
}
