import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MeetingDetailView: View {
    let meetingID: UUID
    let onDeleted: () -> Void
    @ObservedObject private var store = MeetingStore.shared
    @ObservedObject private var coordinator = MeetingCoordinator.shared
    @State private var errorMessage: String?
    @State private var confirmingCloud = false
    @State private var confirmingDelete = false
    @State private var cloudProvider: OpenAISummaryProvider?
    @State private var cloudConsent: MeetingCloudConsent?
    @State private var summaryTask: Task<Void, Never>?
    @State private var selectedTab = 0
    @State private var useCloudSummary = false

    var body: some View {
        if let meeting = store.meeting(meetingID) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(meeting.title).font(.title2.bold())
                                Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { export(meeting) } label: { Label("Export", systemImage: "square.and.arrow.up") }.buttonStyle(.bordered)
                            Menu {
                                Button("Reprocess saved audio") { reprocess() }
                                    .disabled(coordinator.activeMeetingID != nil || meeting.summaryState == .generating)
                                Divider()
                                Button("Delete meeting", role: .destructive) { confirmingDelete = true }
                                    .disabled(coordinator.activeMeetingID == meetingID || meeting.summaryState == .generating)
                            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
                        }
                        MeetingLiveView(meeting: meeting)
                        ForEach(meeting.issues) { issue in
                            Label(issue.message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                        }
                        if coordinator.activeMeetingID == nil && (meeting.state == .failed || meeting.state == .interrupted) {
                            Button("Retry saved audio transcription") {
                                Task {
                                    do { try await coordinator.recover(meetingID) }
                                    catch { errorMessage = (error as? MeetingError)?.errorDescription ?? String(localized: "Saved audio could not be transcribed. Check the downloaded model and try again.") }
                                }
                            }.buttonStyle(.bordered).disabled(meeting.summaryState == .generating)
                        }
                        Picker("Meeting content", selection: $selectedTab) {
                            Text("Transcript").tag(0)
                            Text("Summary").tag(1)
                        }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
                        if selectedTab == 0 {
                            MeetingTranscriptView(meeting: meeting)
                        } else {
                            summaryControls(meeting)
                            if let summary = meeting.summary {
                                VStack(alignment: .leading, spacing: 14) {
                                    if let provider = meeting.summaryProvider { Text(provider).font(.caption).foregroundStyle(.secondary) }
                                    summarySection("Overview", items: summary.overview, meeting: meeting, proxy: proxy)
                                    summarySection("Topics", items: summary.topics, meeting: meeting, proxy: proxy)
                                    summarySection("Decisions", items: summary.decisions, meeting: meeting, proxy: proxy)
                                    summarySection("Pending issues", items: summary.pending, meeting: meeting, proxy: proxy)
                                    summarySection("Tasks", items: summary.tasks, meeting: meeting, proxy: proxy)
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .confirmationDialog("Send transcript to OpenAI?", isPresented: $confirmingCloud, titleVisibility: .visible) {
                Button("Send transcript and summarize") {
                    if let cloudProvider, let cloudConsent { generate(provider: cloudProvider, consent: cloudConsent) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Only this meeting's transcript text will leave your Mac. Audio is not uploaded. OpenAI API charges and provider retention policies apply. Provider: \(cloudProvider?.name ?? "OpenAI").")
            }
            .confirmationDialog("Delete meeting and its audio?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete meeting", role: .destructive) {
                    do { try store.deleteMeeting(meetingID); onDeleted() }
                    catch { errorMessage = String(localized: "Meeting files could not be deleted. Check folder access and try again.") }
                }
            } message: { Text("This removes the transcript, summary and saved audio for this meeting from this Mac.") }
            .alert("Meeting", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
            .onDisappear { summaryTask?.cancel() }
        }
    }

    @ViewBuilder
    private func summaryControls(_ meeting: MeetingManifest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if meeting.state.isCapturing || meeting.pendingCount > 0 {
                Label("The summary becomes available after transcription finishes.", systemImage: "clock")
                    .foregroundStyle(.secondary)
            } else if meeting.summaryState == .generating {
                HStack { ProgressView().controlSize(.small); Text("Generating summary…"); Button("Cancel summary") { summaryTask?.cancel() } }
            } else {
                let local = LocalMeetingSummaryProvider()
                Picker("Generate summary with", selection: $useCloudSummary) {
                    Text("On this Mac").tag(false)
                    Text("Cloud · OpenAI").tag(true)
                }.pickerStyle(.segmented).frame(maxWidth: 360)
                Button("Generate summary") {
                    if useCloudSummary {
                        let provider = OpenAISummaryProvider()
                        do {
                            cloudConsent = try MeetingSummaryService.shared.cloudConsent(for: meetingID, provider: provider)
                            cloudProvider = provider
                            confirmingCloud = true
                        } catch { errorMessage = String(localized: "This transcript is not ready for summarization.") }
                    } else { generate(provider: local, consent: nil) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(meeting.speechSegments.isEmpty || (!useCloudSummary && local.unavailability(language: meeting.language) != nil))
                if !useCloudSummary, let reason = local.unavailability(language: meeting.language) { Text(reason).font(.callout).foregroundStyle(.secondary) }
                if useCloudSummary { Text("Only transcript text is sent, after your confirmation.").font(.callout).foregroundStyle(.secondary) }
            }
            if let message = meeting.summaryError {
                Text(message == MeetingError.invalidData.errorDescription ? MeetingError.invalidSummary.localizedDescription : message)
                    .font(.callout).foregroundStyle(.orange)
            }
            if !meeting.issues.isEmpty { Text("The summary uses only the available transcript; capture gaps may omit information.").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func reprocess() {
        selectedTab = 0
        Task {
            do { try await coordinator.recover(meetingID, reprocessAll: true) }
            catch { errorMessage = (error as? MeetingError)?.errorDescription ?? String(localized: "Saved audio could not be transcribed. Check the downloaded model and try again.") }
        }
    }

    private func generate(provider: any MeetingSummaryProvider, consent: MeetingCloudConsent?) {
        summaryTask = Task {
            do { _ = try await MeetingSummaryService.shared.generate(meetingID: meetingID, provider: provider, consent: consent) }
            catch {
                if !(error is CancellationError) {
                    errorMessage = (error as? MeetingError)?.errorDescription ?? String(localized: "Summary could not be generated. Check provider availability and try again.")
                }
            }
            summaryTask = nil
        }
    }

    @ViewBuilder
    private func summarySection(_ title: LocalizedStringKey, items: [MeetingSummaryItem], meeting: MeetingManifest, proxy: ScrollViewProxy) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.text).textSelection(.enabled)
                        if let owner = item.owner, !owner.isEmpty { Text("Owner: \(owner)").font(.caption) }
                        if let deadline = item.deadline, !deadline.isEmpty { Text("Deadline: \(deadline)").font(.caption) }
                        HStack {
                            ForEach(item.segmentIDs, id: \.self) { id in
                                if let segment = meeting.segments.first(where: { $0.id == id }) {
                                    Button(MeetingMarkdownExporter.timestamp(segment.start)) {
                                        selectedTab = 0
                                        Task { await Task.yield(); withAnimation { proxy.scrollTo(id, anchor: .center) } }
                                    }
                                        .font(.caption).buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func export(_ meeting: MeetingManifest) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = meeting.title.replacingOccurrences(of: "/", with: "-") + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try MeetingMarkdownExporter.render(meeting).write(to: url, atomically: true, encoding: .utf8) }
        catch { errorMessage = String(localized: "The meeting could not be exported to this location.") }
    }
}
