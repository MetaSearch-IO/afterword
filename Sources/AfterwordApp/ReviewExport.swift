import AfterwordCore
import Foundation

enum ReviewExportFormat: String, CaseIterable {
    case markdown = "Markdown", plainText = "Plain Text"
    var fileExtension: String { self == .markdown ? "md" : "txt" }
}

enum ReviewExportScope: String, CaseIterable {
    case all = "Notes and Transcript", notes = "Notes", transcript = "Transcript"
}

struct ReviewExportSnapshot {
    let meeting: Meeting
    let transcript: Transcript
    let summary: MeetingSummary?
    var voiceLabels: [String: String] = [:]
    var names: [String: String] { meeting.speakerNames[transcript.revision_id] ?? [:] }

    func speakerName(_ id: String?) -> String {
        guard let id else { return "Unknown" }
        return names[id] ?? voiceLabels[id] ?? transcript.speakers.first { $0.id == id }?.label ?? "Unknown"
    }
}

enum ReviewExport {
    static func snapshot(store: MeetingStore, meetingID: String, expectedRevisionID: String,
                         expectedSummaryID: String?) throws -> ReviewExportSnapshot {
        let meeting = try store.load(id: meetingID)
        try Artifacts.require(meeting.activeRevisionID == expectedRevisionID && meeting.activeSummaryID == expectedSummaryID,
                              "The transcript or notes changed. Reload before exporting.")
        let transcript = try Artifacts.loadRevision(store: store, meeting: meeting, revision: expectedRevisionID)
        var summary: MeetingSummary?
        if let id = expectedSummaryID {
            let loaded = try Artifacts.read(MeetingSummary.self, store: store, meetingID: meetingID,
                                            path: "revisions/\(expectedRevisionID)/summaries/\(id).json")
            try Artifacts.validate(loaded, transcript: transcript, summaryID: id)
            summary = loaded
        }
        let voiceLabels = (try? VoiceProfileLabels.load(store: store, meetingID: meetingID, transcript: transcript)) ?? [:]
        let result = ReviewExportSnapshot(meeting: meeting, transcript: transcript, summary: summary, voiceLabels: voiceLabels)
        try validateCurrent(result, store: store)
        return result
    }

    static func validateCurrent(_ snapshot: ReviewExportSnapshot, store: MeetingStore) throws {
        let before = snapshot.meeting
        let now = try store.load(id: before.id)
        let voiceLabels = (try? VoiceProfileLabels.load(store: store, meetingID: before.id, transcript: snapshot.transcript)) ?? [:]
        try Artifacts.require(now.activeRevisionID == before.activeRevisionID && now.activeSummaryID == before.activeSummaryID
            && now.title == before.title && now.startedAt == before.startedAt && now.intervals == before.intervals
            && now.speakerNames[snapshot.transcript.revision_id] == before.speakerNames[snapshot.transcript.revision_id]
            && Artifacts.audioFingerprint(now.chunks) == Artifacts.audioFingerprint(before.chunks)
            && voiceLabels == snapshot.voiceLabels,
            "The meeting changed while choosing an export file. Export again to use the current transcript, notes and names.")
    }

    static func filename(title: String, scope: ReviewExportScope, format: ReviewExportFormat) -> String {
        let sanitized = title.unicodeScalars.map { scalar in
            scalar.value < 32 || (127...159).contains(scalar.value) || "/\\:".unicodeScalars.contains(scalar) ? "-" : String(scalar)
        }.joined()
        let clean = sanitized.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let suffix = " - \(scope.rawValue).\(format.fileExtension)"
        let budget = 255 - suffix.utf8.count
        var stem = ""
        for character in clean {
            guard stem.utf8.count + String(character).utf8.count <= budget else { break }
            stem.append(character)
        }
        return (stem.isEmpty ? "Meeting" : stem) + suffix
    }

    static func render(_ snapshot: ReviewExportSnapshot, scope: ReviewExportScope, format: ReviewExportFormat) -> String {
        let markdown = format == .markdown
        func text(_ value: String) -> String { markdown ? escape(value) : value }
        func heading(_ title: String, level: Int = 2) -> String {
            markdown ? String(repeating: "#", count: level) + " " + text(title) : title
        }
        var blocks = [heading(snapshot.meeting.title, level: 1), "Recorded: " + text(snapshot.meeting.startedAt)]
        if snapshot.transcript.speakerLabelsPending {
            blocks.append("Speaker labels are pending. Unknown speakers have not been assigned.")
        }
        let pauses = zip(snapshot.meeting.intervals, snapshot.meeting.intervals.dropFirst()).compactMap { previous, next -> String? in
            guard let end = previous.endUS, next.startUS > end else { return nil }
            return "\(timestamp(end))–\(timestamp(next.startUS))"
        }
        if !pauses.isEmpty { blocks.append("Recording paused: " + pauses.joined(separator: ", ")) }
        if scope != .transcript {
            blocks.append(heading("Notes"))
            if let summary = snapshot.summary {
                if summary.name_map_revision != (try? Artifacts.nameMapRevision(snapshot.names)) {
                    blocks.append("Speaker names changed after these notes were generated. Owners below use current names; note text may use earlier names.")
                }
                func section(_ title: String, _ items: [SummaryNote], paragraph: Bool = false) {
                    guard !items.isEmpty else { return }
                    blocks.append(heading(title, level: 3))
                    blocks.append(paragraph ? items.map { text($0.text) }.joined(separator: " ")
                        : items.map { "- " + text($0.text).replacingOccurrences(of: "\n", with: "\n  ") }.joined(separator: "\n"))
                }
                section("Overview", summary.overview, paragraph: true)
                section("Discussion", summary.discussion_points)
                section("Decisions", summary.decisions)
                if !summary.action_items.isEmpty {
                    blocks.append(heading("Action items", level: 3))
                    blocks.append(summary.action_items.map { action in
                        "- " + text(action.text).replacingOccurrences(of: "\n", with: "\n  ")
                            + "\n  Owner: " + text(snapshot.speakerName(action.owner_speaker_id))
                            + " · Due: " + text(action.due_date ?? "Unspecified")
                    }.joined(separator: "\n"))
                }
                section("Open questions", summary.open_questions)
            } else {
                blocks.append("Notes are not available for this transcript. Generate or regenerate notes in Afterword.")
            }
        }
        if scope != .notes {
            blocks.append(heading("Transcript"))
            if snapshot.transcript.segments.isEmpty { blocks.append("No speech was found in the retained audio.") }
            else {
                blocks.append(snapshot.transcript.segments.map { segment in
                    "[\(timestamp(segment.start_us))] " + text(snapshot.speakerName(segment.speaker_id)) + ": " + text(segment.text)
                }.joined(separator: markdown ? "\n\n" : "\n"))
            }
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    private static func escape(_ value: String) -> String {
        value.reduce(into: "") { result, character in
            if character == "&" { result += "&amp;"; return }
            if "\\`*_{}[]()#+-.!|><".contains(character) { result.append("\\") }
            result.append(character)
        }
    }

    private static func timestamp(_ microseconds: Int64) -> String {
        let seconds = microseconds / 1_000_000
        return String(format: "%02lld:%02lld", seconds / 60, seconds % 60)
    }
}
