import AfterwordCore
import CryptoKit
import Foundation

struct Transcript: Decodable, Sendable {
    let schema_version: Int
    let run_id: String
    let meeting_id: String
    let revision_id: String
    let segments: [TranscriptSegment]
    let speakers: [TranscriptSpeaker]
    let coverage: [TranscriptCoverage]
    let warnings: [String]

    var speakerLabelsPending: Bool {
        segments.contains { $0.source == .system && $0.attribution_reason == "speaker_labeling_pending" }
    }
}

struct TranscriptSegment: Decodable, Identifiable, Sendable {
    let id: String
    let source: AudioSource
    let start_us: Int64
    let end_us: Int64
    let text: String
    let speaker_id: String?
    let attribution_reason: String
    let overlap: Bool
}

struct TranscriptSpeaker: Decodable, Identifiable, Sendable {
    let id: String
    let source: AudioSource
    let label: String
}

struct TranscriptCoverage: Decodable, Sendable {
    let source: AudioSource
    let start_us: Int64
    let end_us: Int64
}

struct MeetingSummary: Decodable, Sendable {
    let schema_version: Int
    let run_id: String
    let meeting_id: String
    let revision_id: String
    let summary_id: String
    let name_map_revision: String
    let covered_segment_ids: [String]
    let overview: [SummaryNote]
    let discussion_points: [SummaryNote]
    let decisions: [SummaryNote]
    let action_items: [SummaryAction]
    let open_questions: [SummaryNote]
}

struct SummaryNote: Decodable, Sendable {
    let text: String
    let segment_ids: [String]
}

struct SummaryAction: Decodable, Sendable {
    let text: String
    let segment_ids: [String]
    let owner_speaker_id: String?
    let owner_evidence_segment_ids: [String]
    let due_date: String?
    let due_date_evidence_segment_ids: [String]
}

struct ArtifactProvenance: Decodable, Sendable {
    let schema_version: Int
    let run_id: String
    let meeting_id: String
    let revision_id: String
    let input_fingerprint: String
    let committed_audio_fingerprint: String
    let preparation_version: Int
    let alignment_version: Int
}

enum Artifacts {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CaptureFailure(message: message) }
    }

    static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    static func read<T: Decodable>(_ type: T.Type, store: MeetingStore, meetingID: String, path: String) throws -> T {
        let url = try store.artifactURL(meetingID: meetingID, relativePath: path)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try require(size <= 16 * 1_024 * 1_024, "A processing artifact exceeds the size limit.")
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    static func validate(_ transcript: Transcript, meeting: Meeting, revisionID: String, runID: String? = nil) throws {
        try require(transcript.schema_version == 1 && transcript.meeting_id == meeting.id && transcript.revision_id == revisionID,
                    "Transcript identity does not match this meeting revision.")
        try require(identifier(transcript.run_id) && (runID == nil || transcript.run_id == runID), "Transcript run does not match.")
        var speakers: [String: AudioSource] = [:]
        for speaker in transcript.speakers {
            try require(identifier(speaker.id) && speakers[speaker.id] == nil && !speaker.label.isEmpty, "Invalid transcript speaker.")
            speakers[speaker.id] = speaker.source
        }
        for coverage in transcript.coverage {
            try require(covers(start: coverage.start_us, end: coverage.end_us, source: coverage.source, chunks: meeting.chunks),
                        "Transcript coverage includes audio that was not retained.")
        }
        var ids = Set<String>()
        var previous: Int64 = -1
        for segment in transcript.segments {
            try require(identifier(segment.id) && ids.insert(segment.id).inserted && segment.start_us >= previous
                        && segment.end_us > segment.start_us && !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && segment.text.count <= 32_000, "Invalid transcript segment.")
            if let speakerID = segment.speaker_id {
                try require(speakers[speakerID] == segment.source && (!segment.overlap || segment.source == .microphone),
                            "Transcript attribution references an incompatible speaker.")
            }
            try require(transcript.coverage.contains { $0.source == segment.source && $0.start_us <= segment.start_us && $0.end_us >= segment.end_us },
                        "A transcript segment crosses missing audio or a pause.")
            previous = segment.start_us
        }
    }

    static func validate(_ summary: MeetingSummary, transcript: Transcript, summaryID: String, runID: String? = nil) throws {
        try require(summary.schema_version == 1 && summary.meeting_id == transcript.meeting_id
                    && summary.revision_id == transcript.revision_id && summary.summary_id == summaryID
                    && identifier(summary.run_id) && (runID == nil || summary.run_id == runID), "Summary identity does not match.")
        try require(Set(transcript.segments.map(\.id)).count == transcript.segments.count, "Transcript contains duplicate segment IDs.")
        let segments = Dictionary(uniqueKeysWithValues: transcript.segments.map { ($0.id, $0) })
        try require(Set(summary.covered_segment_ids) == Set(segments.keys)
                    && Set(summary.covered_segment_ids).count == summary.covered_segment_ids.count, "Summary omits transcript coverage.")
        func note(_ text: String, _ refs: [String]) throws {
            try require(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= 8_000 && !refs.isEmpty
                        && Set(refs).count == refs.count && refs.allSatisfy { segments[$0] != nil }, "Summary contains invalid evidence references.")
        }
        for group in [summary.overview, summary.discussion_points, summary.decisions, summary.open_questions] {
            try require(group.count <= 512, "Summary has too many notes.")
            for item in group { try note(item.text, item.segment_ids) }
        }
        try require(summary.action_items.count <= 512, "Summary has too many actions.")
        for item in summary.action_items {
            try note(item.text, item.segment_ids)
            try require(item.segment_ids.count == 1 && segments[item.segment_ids[0]]?.text.contains(item.text) == true,
                        "Action items must quote one supporting transcript segment exactly.")
            try require(item.owner_evidence_segment_ids.allSatisfy { item.segment_ids.contains($0) }
                        && item.due_date_evidence_segment_ids.allSatisfy { item.segment_ids.contains($0) }, "Action evidence is outside its supporting notes.")
            if let owner = item.owner_speaker_id {
                try require(item.owner_evidence_segment_ids.contains { segments[$0]?.speaker_id == owner }, "Action owner lacks attributed evidence.")
                let commitment = "^(?:I (?:will|shall|am going to|am responsible for)\\b|I['’]ll\\b|我(?:会|来|将|负责|承担)|由我(?:来|负责|承担))"
                try require(item.text.range(of: commitment, options: [.regularExpression, .caseInsensitive]) != nil,
                            "Structured action owners require an explicit self-commitment.")
            } else { try require(item.owner_evidence_segment_ids.isEmpty, "Unknown owner cannot have owner evidence.") }
            if let due = item.due_date {
                try require(!due.isEmpty && item.due_date_evidence_segment_ids.contains { segments[$0]?.text.localizedCaseInsensitiveContains(due) == true },
                            "Action due date is not explicit in its evidence.")
            } else { try require(item.due_date_evidence_segment_ids.isEmpty, "Unknown due date cannot have date evidence.") }
        }
    }

    static func nameMapRevision(_ names: [String: String]) throws -> String {
        let bytes = try JSONSerialization.data(withJSONObject: names, options: [.sortedKeys, .withoutEscapingSlashes])
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func audioFingerprint(_ chunks: [ChunkDescriptor]) -> String {
        let rows = chunks.sorted { $0.id < $1.id }.map { chunk in
            let rate = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), chunk.sampleRate)
            return "\(chunk.id)|\(chunk.source.rawValue)|\(chunk.generation)|\(chunk.startUS)|\(chunk.frameCount)|\(rate)|\(chunk.channelCount)|\(chunk.relativePath)\n"
        }.joined()
        return SHA256.hash(data: Data(rows.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func covers(start: Int64, end: Int64, source: AudioSource, chunks: [ChunkDescriptor]) -> Bool {
        guard start >= 0, end > start else { return false }
        var cursor = start
        var generation: Int?
        for chunk in chunks.filter({ $0.source == source }).sorted(by: { $0.startUS < $1.startUS }) {
            if chunk.endUS <= cursor { continue }
            if chunk.startUS > cursor && chunk.startUS - cursor > 2 { return false }
            if let generation, chunk.generation != generation { return false }
            generation = chunk.generation
            cursor = max(cursor, chunk.endUS)
            if cursor >= end { return true }
        }
        return false
    }

    static func loadRevision(store: MeetingStore, meeting: Meeting, revision: String, run: String? = nil) throws -> Transcript {
        let transcript = try read(Transcript.self, store: store, meetingID: meeting.id, path: "revisions/\(revision)/transcript.json")
        try validate(transcript, meeting: meeting, revisionID: revision, runID: run)
        let provenance = try read(ArtifactProvenance.self, store: store, meetingID: meeting.id, path: "revisions/\(revision)/provenance.json")
        try require(provenance.schema_version == 1 && provenance.meeting_id == meeting.id
                    && provenance.revision_id == revision && provenance.run_id == transcript.run_id
                    && provenance.committed_audio_fingerprint == audioFingerprint(meeting.chunks)
                    && provenance.preparation_version == 1 && [1, 2].contains(provenance.alignment_version),
                    "Transcript provenance is incompatible with the retained audio.")
        return transcript
    }
}
