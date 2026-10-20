import Foundation

nonisolated enum MeetingMarkdownExporter {
    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? Int(max(0, min(Double(Int32.max), seconds))) : 0
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    static func render(_ meeting: MeetingManifest) -> String {
        var lines = ["# " + escape(meeting.title), "", meeting.startedAt.formatted(), "", meeting.state.title, ""]
        for issue in meeting.issues { lines.append("> " + escape(issue.message)) }
        if let summary = meeting.summary {
            for (title, items) in [(String(localized: "Overview"), summary.overview), (String(localized: "Topics"), summary.topics),
                (String(localized: "Decisions"), summary.decisions), (String(localized: "Pending issues"), summary.pending), (String(localized: "Tasks"), summary.tasks)] where !items.isEmpty {
                lines += ["", "## " + title, ""]
                for item in items {
                    let references = item.segmentIDs.compactMap { id in meeting.segments.first(where: { $0.id == id }) }
                        .map { timestamp($0.start) + " · " + $0.source.title }.joined(separator: "; ")
                    lines.append("- " + escape(item.text) + " [" + references + "]")
                    if let owner = item.owner, !owner.isEmpty { lines.append("  - " + String(localized: "Owner") + ": " + escape(owner)) }
                    if let deadline = item.deadline, !deadline.isEmpty { lines.append("  - " + String(localized: "Deadline") + ": " + escape(deadline)) }
                }
            }
        }
        lines += ["", "## " + String(localized: "Transcript"), ""]
        for segment in meeting.orderedSegments {
            lines += ["### " + timestamp(segment.start) + " · " + segment.source.title, "",
                      escape(segment.recognizedText ?? segment.error ?? (segment.state == .completed ? String(localized: "No speech detected") : String(localized: "Transcription pending"))), ""]
        }
        return lines.joined(separator: "\n")
    }

    private static func escape(_ text: String) -> String {
        text.reduce(into: "") { result, character in
            if "\\`*_{}[]<>()#!".contains(character) { result.append("\\") }
            result.append(character)
        }
    }
}
