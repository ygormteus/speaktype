import Foundation

struct OpenAISummaryProvider: MeetingSummaryProvider {
    static let modelKey = "meetingCloudModel"
    static let defaultModel = "gpt-4.1-mini"
    let model: String
    var id: String { "openai:" + model }
    var name: String { "OpenAI · " + model }
    let isCloud = true
    let inputLimit = 20_000
    private let session: URLSession
    private let readKey: () throws -> String

    init(model: String? = nil, session: URLSession? = nil, readKey: @escaping () throws -> String = { try KeychainHelper.shared.readMeetingAPIKey() }) {
        let configured = model ?? UserDefaults.standard.string(forKey: Self.modelKey) ?? Self.defaultModel
        self.model = configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.defaultModel : configured
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 180
        self.session = session ?? URLSession(configuration: configuration, delegate: MeetingCloudSessionDelegate(), delegateQueue: nil)
        self.readKey = readKey
    }

    func makeRequest(_ input: MeetingSummaryRequest) throws -> URLRequest {
        let key: String
        do { key = try readKey() }
        catch { throw MeetingError.unavailable(String(localized: "Add your OpenAI API key in Settings → Meeting AI to use cloud summaries.")) }
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MeetingError.unavailable(String(localized: "Add your OpenAI API key in Settings → Meeting AI to use cloud summaries."))
        }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "store": false, "max_output_tokens": 2500,
            "instructions": MeetingSummaryService.instructions,
            "input": try input.encodedPrompt(),
            "text": ["format": ["type": "json_schema", "name": "meeting_summary", "strict": true, "schema": Self.schema]]
        ])
        return request
    }

    func summarize(_ request: MeetingSummaryRequest) async throws -> MeetingSummary {
        let (data, response) = try await session.data(for: makeRequest(request))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MeetingError.unavailable(String(localized: "Cloud summary request failed. Check the API key, model and usage limits in Meeting AI settings."))
        }
        return try Self.decodeResponse(data)
    }

    static func decodeResponse(_ data: Data) throws -> MeetingSummary {
        guard data.count <= 2_000_000 else { throw MeetingError.invalidData }
        let result = try JSONDecoder().decode(Response.self, from: data)
        guard result.status == "completed", let text = result.output.flatMap({ $0.content ?? [] }).first(where: { $0.type == "output_text" })?.text else {
            throw MeetingError.invalidData
        }
        return try JSONDecoder().decode(MeetingSummary.self, from: Data(text.utf8))
    }

    private struct Response: Decodable {
        let status: String
        let output: [Output]
        struct Output: Decodable {
            let content: [Content]?
            struct Content: Decodable { let type: String; let text: String? }
        }
    }

    private static var schema: [String: Any] {
        let item: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "properties": ["text": ["type": "string"], "segmentIDs": ["type": "array", "items": ["type": "string"]],
                "owner": ["type": ["string", "null"]], "deadline": ["type": ["string", "null"]]],
            "required": ["text", "segmentIDs", "owner", "deadline"]
        ]
        let fields = ["overview", "topics", "decisions", "pending", "tasks"]
        return ["type": "object", "additionalProperties": false,
            "properties": Dictionary(uniqueKeysWithValues: fields.map { ($0, ["type": "array", "items": item] as [String: Any]) }), "required": fields]
    }
}

private final class MeetingCloudSessionDelegate: NSObject, URLSessionTaskDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                               newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
