import SwiftUI

/// Enhanced detail view for history items with audio playback
struct HistoryDetailView: View {
    let item: HistoryItem
    
    @StateObject private var audioPlayer = AudioPlayerService.shared
    @State private var showCopyAlert = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header with date and duration
                HStack(alignment: .top) {
                    Text(item.date.formatted(date: .abbreviated, time: .shortened))
                        .font(Typography.caption)
                        .foregroundStyle(Color.textMuted)
                    
                    Spacer()
                    
                    Text(formatDuration(item.duration))
                        .font(Typography.labelMedium)
                        .foregroundStyle(Color.brandAccent)
                }
                
                // Badges and copy button
                HStack {
                    // Original badge
                    Text("Original")
                        .font(Typography.badge)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.brandAccent)
                        .foregroundStyle(Color.white)
                        .cornerRadius(12)
                    
                    Spacer()
                    
                    // Copy button
                    Button(action: {
                        copyToClipboard(text: item.transcript)
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11))
                            Text("Copy")
                                .font(Typography.labelMedium)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.brandAccent)
                        .foregroundStyle(Color.white)
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                }
                
                Divider()
                
                // Transcript
                Text(item.transcript)
                    .font(Typography.bodyMedium)
                    .textSelection(.enabled)
                    .padding(.vertical, 8)
                
                Divider()
                
                // Audio playback section
                if let audioURL = item.audioFileURL {
                    VStack(spacing: 16) {
                        // Recording label with duration
                        HStack {
                            HStack(spacing: 6) {
                                Image(systemName: "waveform")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.textMuted)
                                Text("Recording")
                                    .font(Typography.caption)
                                    .foregroundStyle(Color.textMuted)
                            }
                            
                            Spacer()
                            
                            Text(formatTime(audioPlayer.currentTime))
                                .font(Typography.caption)
                                .foregroundStyle(Color.textMuted)
                                .monospacedDigit()
                        }
                        
                        // Waveform visualization
                        WaveformView(
                            audioURL: audioURL,
                            currentTime: $audioPlayer.currentTime,
                            duration: $audioPlayer.duration
                        )
                        
                        // Playback controls
                        HStack(spacing: 20) {
                            // Folder/file icon
                            Button(action: {
                                NSWorkspace.shared.activateFileViewerSelecting([audioURL])
                            }) {
                                Image(systemName: "folder")
                                    .font(.title3)
                                    .foregroundStyle(Color.brandAccent)
                            }
                            .buttonStyle(.plain)
                            .help("Show in Finder")
                            
                            Spacer()
                            
                            // Play/Pause button
                            Button(action: togglePlayback) {
                                Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.title2)
                                    .foregroundStyle(Color.brandAccent)
                            }
                            .buttonStyle(.plain)
                            
                            Spacer()
                            
                            // Refresh/restart button
                            Button(action: {
                                audioPlayer.seek(to: 0)
                            }) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.title3)
                                    .foregroundStyle(Color.accentSuccess)
                            }
                            .buttonStyle(.plain)
                            .help("Restart")
                        }
                        .padding(.vertical, 8)
                    }
                    .padding()
                    .background(Color.bgHover)
                    .cornerRadius(12)
                }
                
                Divider()
                
                // Metrics section
                VStack(alignment: .leading, spacing: 12) {
                    // Audio Duration
                    HStack {
                        Image(systemName: "waveform.circle")
                            .foregroundStyle(Color.textMuted)
                        Text("Audio Duration")
                            .font(Typography.bodySmall)
                            .foregroundStyle(Color.textMuted)
                        Spacer()
                        Text(formatDuration(item.duration))
                            .font(Typography.bodySmall)
                            .foregroundStyle(Color.textPrimary)
                    }
                    
                    // Transcription Model
                    if let model = item.modelUsed {
                        HStack {
                            Image(systemName: "cpu")
                                .foregroundStyle(Color.textMuted)
                            Text("Transcription Model")
                                .font(Typography.bodySmall)
                                .foregroundStyle(Color.textMuted)
                            Spacer()
                            Text(model)
                                .font(Typography.bodySmall)
                                .foregroundStyle(Color.textPrimary)
                                .lineLimit(1)
                        }
                    }
                    
                    // Transcription Time
                    if let transcriptionTime = item.transcriptionTime {
                        HStack {
                            Image(systemName: "clock")
                                .foregroundStyle(Color.textMuted)
                            Text("Transcription Time")
                                .font(Typography.bodySmall)
                                .foregroundStyle(Color.textMuted)
                            Spacer()
                            Text(formatDuration(transcriptionTime))
                                .font(Typography.bodySmall)
                                .foregroundStyle(Color.textPrimary)
                        }
                    }
                }
            }
            .padding()
        }
        .background(Color.contentBackground)
        .navigationTitle("Transcript Details")
        .onAppear {
            if let audioURL = item.audioFileURL {
                audioPlayer.loadAudio(from: audioURL)
            }
        }
        .onDisappear {
            audioPlayer.stop()
        }
        .alert("Copied", isPresented: $showCopyAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Transcript copied to clipboard.")
        }
    }
    
    // MARK: - Helper Methods
    
    private func togglePlayback() {
        if audioPlayer.isPlaying {
            audioPlayer.pause()
        } else {
            audioPlayer.play()
        }
    }
    
    private func copyToClipboard(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        showCopyAlert = true
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: duration) ?? "0s"
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

#Preview {
    HistoryDetailView(
        item: HistoryItem(
            id: UUID(),
            date: Date(),
            transcript: "Hello, hello, hello, hello, hello.",
            duration: 3.4,
            audioFileURL: nil,
            modelUsed: "Large v3 Turbo (Quantized)",
            transcriptionTime: 1.3
        )
    )
}
