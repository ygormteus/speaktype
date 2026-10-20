import SwiftUI

struct MeetingTranscriptView: View {
    let meeting: MeetingManifest
    @ObservedObject private var player = AudioPlayerService.shared
    @ObservedObject private var recorder = AudioRecordingService.shared
    @ObservedObject private var coordinator = MeetingCoordinator.shared
    private var store: MeetingStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if meeting.speechSegments.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label(meeting.pendingCount > 0 ? String(localized: "Processing your speech…") : meeting.state.isCapturing ? String(localized: "Waiting for your speech") : String(localized: "No speech was recognized"), systemImage: "waveform")
                        .font(.headline)
                    Text(meeting.pendingCount > 0
                        ? String(localized: "The local model is working on the saved audio. The first result can take longer while the model warms up.")
                        : meeting.state.isCapturing
                            ? String(localized: "Check the microphone level above. The first text appears after a pause and local processing.")
                            : String(localized: "Listen to the saved audio to check what the microphone captured, then reprocess if needed."))
                        .foregroundStyle(.secondary)
                }.padding(.vertical, 12)
            }
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(meeting.speechSegments) { segment in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(MeetingMarkdownExporter.timestamp(segment.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            if meeting.mode == .online { Text(segment.source.title).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            playbackButton(segment)
                        }
                        Text(segment.recognizedText ?? "").font(.body).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.id(segment.id)
                }
            }
            if meeting.pendingCount > 0, !meeting.speechSegments.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("More text is being transcribed…").foregroundStyle(.secondary)
                }
            }
            if meeting.segments.contains(where: { $0.state == .failed }) {
                Label("Some audio could not be transcribed. You can retry using the saved recording.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if !meeting.segments.isEmpty {
                Divider()
                DisclosureGroup("Listen to the saved audio") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Compare the original recording with the transcript.").font(.caption).foregroundStyle(.secondary)
                        ForEach(meeting.orderedSegments) { segment in
                            HStack {
                                Text("\(MeetingMarkdownExporter.timestamp(segment.start)) · \(segment.source.title)").font(.callout)
                                Spacer()
                                playbackButton(segment)
                            }
                        }
                    }.padding(.top, 10)
                }
            }
        }
        .onDisappear {
            if player.currentAudioURL?.deletingLastPathComponent() == store.directory(meeting.id) { player.stop() }
        }
    }

    private func playbackButton(_ segment: MeetingAudioSegment) -> some View {
        let url = store.audioURL(segment, meetingID: meeting.id)
        let playing = player.isPlaying && player.currentAudioURL == url
        return Button {
            if playing { player.pause() }
            else { player.loadAudio(from: url); player.play() }
        } label: {
            Label(playing ? String(localized: "Pause audio") : String(localized: "Listen"), systemImage: playing ? "pause.fill" : "play.fill").font(.caption)
        }
        .buttonStyle(.borderless)
        .disabled(recorder.isRecording || coordinator.isCapturingAudio)
    }
}
