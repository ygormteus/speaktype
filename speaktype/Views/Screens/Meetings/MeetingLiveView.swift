import SwiftUI

struct MeetingLiveView: View {
    let meeting: MeetingManifest
    @ObservedObject private var coordinator = MeetingCoordinator.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if meeting.state == .recording {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red).font(.title2)
                } else if meeting.state == .transcribing || meeting.state == .finalizing || meeting.state == .preparing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: meeting.state == .completed ? "checkmark.circle.fill" : "exclamationmark.triangle")
                        .foregroundStyle(meeting.state == .completed ? .green : .orange)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(meeting.state.title).font(.headline)
                    if meeting.state == .recording {
                        Text("Speak normally. Text appears after short pauses.").font(.callout).foregroundStyle(.secondary)
                    } else if meeting.state == .transcribing || meeting.state == .finalizing {
                        Text("Recording has stopped. Your saved audio is still being transcribed.").font(.callout).foregroundStyle(.secondary)
                    } else if meeting.state == .preparing {
                        Text("Loading the local model and checking the microphone…").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if meeting.state.isCapturing {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(MeetingMarkdownExporter.timestamp(max(0, context.date.timeIntervalSince(meeting.startedAt)))).monospacedDigit()
                    }
                    Button(coordinator.isStarting ? String(localized: "Cancel preparation") : String(localized: "Stop recording")) {
                        Task { await coordinator.stop() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(meeting.state == .recording ? .red : .blue)
                    .disabled(coordinator.isStopping)
                }
            }
            if meeting.state == .recording {
                ForEach(MeetingAudioSource.allCases, id: \.self) { source in
                    if meeting.sources[source] == .active {
                        HStack(spacing: 10) {
                            Label(source.title, systemImage: source == .microphone ? "mic.fill" : "speaker.wave.2.fill")
                                .font(.caption).frame(width: 110, alignment: .leading)
                            ProgressView(value: Double(coordinator.audioLevels[source] ?? 0)).tint(.green).frame(maxWidth: 180)
                            Text("Audio level").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if meeting.pendingCount > 0 || meeting.state == .transcribing || meeting.state == .finalizing {
                ProgressView(value: Double(meeting.processedCount), total: Double(max(1, meeting.segments.count)))
                Text("Processed: \(meeting.processedCount) of \(meeting.segments.count) audio parts").font(.caption).foregroundStyle(.secondary)
            }
            if !meeting.modelVariant.isEmpty {
                let modelName = AIModel.availableModels.first(where: { $0.variant == meeting.modelVariant })?.name ?? meeting.modelVariant
                Text("Transcription model: \(modelName)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}
