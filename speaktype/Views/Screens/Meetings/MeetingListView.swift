import SwiftUI
import AVFoundation

struct MeetingListView: View {
    @ObservedObject private var store = MeetingStore.shared
    @ObservedObject private var coordinator = MeetingCoordinator.shared
    @State private var selectedID: UUID?
    @State private var showingSetup = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Meetings").font(Typography.displayLarge)
                Spacer()
                Button { showingSetup = true } label: { Label("New meeting", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                    .disabled(coordinator.activeMeetingID != nil)
            }
            if let message = store.storageError ?? coordinator.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if store.unreadableMeetingCount > 0 {
                Text("Some meeting files could not be read. Their audio has been kept on this Mac.")
                    .font(.callout).foregroundStyle(.orange)
            }
            if let active = coordinator.activeMeetingID, selectedID != active {
                Button("Return to the active meeting") { selectedID = active }.buttonStyle(.bordered)
            }
            if store.items.isEmpty {
                ContentUnavailableView("Your meetings stay on this Mac", systemImage: "person.3.sequence",
                    description: Text("Record in person or capture microphone and system audio online. Transcribe locally, then choose how to summarize."))
            } else {
                HSplitView {
                    List(selection: $selectedID) {
                        ForEach(store.items) { meeting in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(meeting.title).font(.headline).lineLimit(1)
                                Text(meeting.state.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(.vertical, 6)
                            .tag(meeting.id)
                        }
                    }
                    .listStyle(.sidebar)
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 260)
                    if let selectedID, store.meeting(selectedID) != nil {
                        MeetingDetailView(meetingID: selectedID, onDeleted: { self.selectedID = nil })
                            .id(selectedID)
                            .frame(minWidth: 380)
                    } else {
                        ContentUnavailableView("Choose a meeting", systemImage: "text.bubble")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .padding(24)
        .tint(.blue)
        .sheet(isPresented: $showingSetup) {
            MeetingSetupView { title, mode, language, modelVariant in
                showingSetup = false
                Task {
                    do { try await coordinator.start(title: title, mode: mode, language: language, modelVariant: modelVariant) }
                    catch { errorMessage = (error as? MeetingError)?.errorDescription ?? String(localized: "Meeting could not start. Check the selected model and audio permissions.") }
                }
            }
        }
        .onChange(of: coordinator.activeMeetingID) { _, id in if let id { selectedID = id } }
        .onAppear { if selectedID == nil { selectedID = coordinator.activeMeetingID ?? store.items.first?.id } }
        .alert("Meeting", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }
}

private struct MeetingSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var mode: MeetingCaptureMode = .inPerson
    @State private var language = "pt"
    @State private var modelVariant = ""
    @State private var isRefreshingModels = true
    @AppStorage(MeetingModelSelection.defaultsKey) private var savedModelVariant = ""
    @ObservedObject private var downloads = ModelDownloadService.shared
    let start: (String, MeetingCaptureMode, String, String) -> Void

    private var downloadedVariants: Set<String> {
        Set(downloads.downloadProgress.filter { $0.value >= 1 }.map(\.key))
    }

    private var models: [AIModel] {
        MeetingModelSelection.models(language: language, downloaded: downloadedVariants)
    }

    private func resolveModel(preferred: String) {
        modelVariant = MeetingModelSelection.resolvedVariant(preferred: preferred, language: language, downloaded: downloadedVariants)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New meeting").font(.title2.bold())
            TextField("Meeting title", text: $title).textFieldStyle(.roundedBorder)
            Picker("What do you want to record?", selection: $mode) {
                ForEach(MeetingCaptureMode.allCases) { mode in Text(mode.title).tag(mode) }
            }.pickerStyle(.radioGroup)
            Label(AVCaptureDevice.default(for: .audio)?.localizedName ?? String(localized: "System default microphone"), systemImage: "mic.fill").foregroundStyle(.secondary)
            DisclosureGroup("Language") {
                Picker("Spoken language", selection: $language) {
                    Text("Português (Brasil)").tag("pt")
                    Text("English").tag("en")
                    Text("Español").tag("es")
                }.padding(.top, 8)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Transcription model").font(.headline)
                if isRefreshingModels {
                    ProgressView("Checking downloaded models…").controlSize(.small)
                } else if models.isEmpty {
                    Text("Download a multilingual Whisper model in AI Models before starting a meeting.")
                        .font(.callout).foregroundStyle(.orange)
                } else {
                    Picker("Transcription model", selection: $modelVariant) {
                        ForEach(models) { model in
                            Text(MeetingModelSelection.title(for: model)).tag(model.variant)
                        }
                    }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                    if modelVariant == MeetingModelSelection.fastPortugueseVariant {
                        Text("Experimental PT-BR model: faster in local tests. Review names, numbers and mixed-language speech.")
                            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("This choice applies only to new meetings. Your dictation model does not change.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Label("Tell participants that this meeting is being recorded.", systemImage: "record.circle")
            if mode == .online {
                Text("Use headphones for online meetings to avoid echo and duplicate speech.").font(.callout).foregroundStyle(.secondary)
            }
            Text("Audio and transcription stay on this Mac. Cloud summaries are optional and require confirmation after the meeting.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Start meeting") {
                    savedModelVariant = modelVariant
                    start(title, mode, language, modelVariant)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRefreshingModels || !models.contains(where: { $0.variant == modelVariant }))
            }
        }
        .padding(28)
        .tint(.blue)
        .frame(width: 520)
        .task {
            await downloads.refreshDownloadedModels()
            resolveModel(preferred: savedModelVariant)
            isRefreshingModels = false
        }
        .onChange(of: language) { _, _ in
            if !isRefreshingModels { resolveModel(preferred: modelVariant) }
        }
        .onChange(of: downloadedVariants) { _, _ in
            if !isRefreshingModels { resolveModel(preferred: modelVariant) }
        }
    }
}
