import SwiftUI

struct MeetingAISettingsView: View {
    @AppStorage(OpenAISummaryProvider.modelKey) private var model = OpenAISummaryProvider.defaultModel
    @State private var apiKey = ""
    @State private var hasSavedKey = false
    @State private var message: String?

    var body: some View {
        Form {
            Section("Local summaries") {
                Text(LocalMeetingSummaryProvider().unavailability(language: "pt") ?? String(localized: "Local summaries are available with Apple Intelligence."))
                Text("Recording and speech transcription run locally regardless of summary availability.")
                    .foregroundStyle(.secondary)
            }
            Section("Cloud summaries · OpenAI") {
                TextField("Model", text: $model)
                SecureField("OpenAI API key", text: $apiKey)
                HStack {
                    Button("Save API key") {
                        do {
                            try KeychainHelper.shared.saveMeetingAPIKey(apiKey)
                            apiKey = ""
                            hasSavedKey = true
                            message = String(localized: "API key saved in Keychain.")
                        } catch { message = String(localized: "The API key could not be saved in Keychain.") }
                    }.disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Remove API key", role: .destructive) {
                        do {
                            try KeychainHelper.shared.deleteMeetingAPIKey()
                            apiKey = ""
                            hasSavedKey = false
                            message = String(localized: "API key removed.")
                        } catch { message = String(localized: "The API key could not be removed from Keychain.") }
                    }.disabled(!hasSavedKey)
                }
                Text(hasSavedKey ? String(localized: "An API key is saved in Keychain.") : String(localized: "No cloud API key is saved.")).foregroundStyle(.secondary)
                if let message { Text(message).font(.callout) }
                Text("Cloud summaries require confirmation for each meeting. Only transcript text is sent. OpenAI API charges and provider retention policies apply.")
                    .font(.callout).foregroundStyle(.secondary)
                Link("Manage OpenAI API keys", destination: URL(string: "https://platform.openai.com/api-keys")!)
            }
        }
        .formStyle(.grouped)
        .onAppear { hasSavedKey = (try? KeychainHelper.shared.readMeetingAPIKey()) != nil }
        .onDisappear { apiKey = "" }
    }
}
