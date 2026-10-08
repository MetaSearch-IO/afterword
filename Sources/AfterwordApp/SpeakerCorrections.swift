import AfterwordCore
import CryptoKit
import Darwin
import Foundation

struct SpeakerCorrection: Codable, Sendable {
    let schema_version: Int
    let revision_id: String
    let run_id: String
    let parent_revision_id: String
    let parent_summary_id: String?
    let parent_input_fingerprint: String
    let parent_transcript_sha256: String
    let parent_provenance_sha256: String
    let segment_ids: [String]
    let speaker_id: String
}

enum SpeakerCorrections {
    static func assign(store: MeetingStore, meetingID: String, expectedRevisionID: String,
                       segmentIDs: [String], speakerID: String) throws -> Meeting {
        try locked(store: store, meetingID: meetingID) {
            var meeting = try editable(store: store, meetingID: meetingID, expectedRevisionID: expectedRevisionID)
            let parent = try snapshot(store: store, meeting: meeting, revision: expectedRevisionID)
            try validateSelection(segmentIDs, speakerID: speakerID, transcript: parent.transcript)
            if let summary = meeting.activeSummaryID {
                try validateSummary(summary, revision: expectedRevisionID, transcript: parent.transcript, store: store, meeting: meeting)
            }
            let revision = UUID().uuidString.lowercased()
            let run = UUID().uuidString.lowercased()
            let selected = Set(segmentIDs)
            let correction = SpeakerCorrection(schema_version: 1, revision_id: revision, run_id: run,
                parent_revision_id: expectedRevisionID, parent_summary_id: meeting.activeSummaryID,
                parent_input_fingerprint: parent.provenance.input_fingerprint,
                parent_transcript_sha256: hash(parent.transcriptBytes), parent_provenance_sha256: hash(parent.provenanceBytes),
                segment_ids: parent.transcript.segments.filter { selected.contains($0.id) }.map(\.id), speaker_id: speakerID)
            let child = try corrected(parent, correction: correction)
            let transcript = try JSONDecoder().decode(Transcript.self, from: child.transcript)
            try Artifacts.validate(transcript, meeting: meeting, revisionID: revision, runID: run)

            let stage = try store.artifactURL(meetingID: meetingID, relativePath: "work/\(run)/revision.partial")
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            try write(child.transcript, to: stage.appendingPathComponent("transcript.json"))
            try write(child.provenance, to: stage.appendingPathComponent("provenance.json"))
            try FileManager.default.createDirectory(at: stage.appendingPathComponent("summaries"), withIntermediateDirectories: false)
            let stagedTranscript = try Data(contentsOf: stage.appendingPathComponent("transcript.json"))
            let stagedProvenance = try Data(contentsOf: stage.appendingPathComponent("provenance.json"))
            try Artifacts.require(stagedTranscript == child.transcript && stagedProvenance == child.provenance,
                "The corrected transcript could not be saved completely.")
            let destination = try store.artifactURL(meetingID: meetingID, relativePath: "revisions/\(revision)")
            try FileManager.default.moveItem(at: stage, to: destination)
            _ = try Artifacts.loadRevision(store: store, meeting: meeting, revision: revision, run: run)

            meeting.speakerNames[revision] = meeting.speakerNames[expectedRevisionID] ?? [:]
            meeting.activeRevisionID = revision
            meeting.activeSummaryID = nil
            ArtifactRecovery.clearPending(&meeting)
            meeting.processingStatus = "transcript_ready"
            meeting.processingStage = nil
            meeting.processingError = "Speaker corrections saved. Regenerate notes to use the corrected speakers."
            try store.save(meeting)
            return meeting
        }
    }

    static func undo(store: MeetingStore, meetingID: String, expectedRevisionID: String) throws -> Meeting {
        try locked(store: store, meetingID: meetingID) {
            var meeting = try editable(store: store, meetingID: meetingID, expectedRevisionID: expectedRevisionID)
            guard let (correction, parent) = try validatedCorrection(store: store, meeting: meeting, revision: expectedRevisionID) else {
                throw CaptureFailure(message: "This transcript has no speaker correction to undo.")
            }
            let names = meeting.speakerNames[expectedRevisionID] ?? [:]
            let parentSpeakers = Set(parent.transcript.speakers.map(\.id))
            meeting.speakerNames[correction.parent_revision_id] = names.filter { parentSpeakers.contains($0.key) }
            meeting.activeRevisionID = correction.parent_revision_id
            meeting.activeSummaryID = correction.parent_summary_id
            ArtifactRecovery.clearPending(&meeting)
            meeting.processingStatus = correction.parent_summary_id == nil ? "transcript_ready" : "completed"
            meeting.processingStage = nil
            meeting.processingError = correction.parent_summary_id == nil ? "Speaker correction undone. Regenerate notes for this transcript." : nil
            try store.save(meeting)
            return meeting
        }
    }

    static func correction(store: MeetingStore, meeting: Meeting) throws -> SpeakerCorrection? {
        guard let revision = meeting.activeRevisionID else { return nil }
        return try locked(store: store, meetingID: meeting.id) {
            let current = try editable(store: store, meetingID: meeting.id, expectedRevisionID: revision)
            return try validatedCorrection(store: store, meeting: current, revision: revision)?.0
        }
    }

    private struct Snapshot {
        let transcript: Transcript
        let provenance: ArtifactProvenance
        let transcriptBytes: Data
        let provenanceBytes: Data
        let rawTranscript: [String: Any]
        let rawProvenance: [String: Any]
    }

    private static func snapshot(store: MeetingStore, meeting: Meeting, revision: String) throws -> Snapshot {
        try Artifacts.require(Artifacts.identifier(revision), "Invalid transcript revision.")
        let transcript = try Artifacts.loadRevision(store: store, meeting: meeting, revision: revision)
        let transcriptBytes = try bytes(store: store, meetingID: meeting.id, path: "revisions/\(revision)/transcript.json")
        let provenanceBytes = try bytes(store: store, meetingID: meeting.id, path: "revisions/\(revision)/provenance.json")
        let provenance = try JSONDecoder().decode(ArtifactProvenance.self, from: provenanceBytes)
        return try Snapshot(transcript: transcript, provenance: provenance, transcriptBytes: transcriptBytes,
                            provenanceBytes: provenanceBytes, rawTranscript: object(transcriptBytes), rawProvenance: object(provenanceBytes))
    }

    private static func validatedCorrection(store: MeetingStore, meeting: Meeting, revision: String) throws -> (SpeakerCorrection, Snapshot)? {
        let child = try snapshot(store: store, meeting: meeting, revision: revision)
        guard let raw = child.rawProvenance["speaker_corrections"] else { return nil }
        guard let history = raw as? [[String: Any]], let latest = history.last else {
            throw CaptureFailure(message: "Speaker correction history is invalid.")
        }
        let correction = try JSONDecoder().decode(SpeakerCorrection.self, from: data(latest))
        try Artifacts.require(correction.schema_version == 1 && correction.revision_id == revision
            && correction.run_id == child.transcript.run_id && correction.parent_revision_id != revision
            && Artifacts.identifier(correction.parent_revision_id)
            && (correction.parent_summary_id.map(Artifacts.identifier) ?? true), "Speaker correction identity does not match this revision.")
        let parent = try snapshot(store: store, meeting: meeting, revision: correction.parent_revision_id)
        try Artifacts.require(correction.parent_input_fingerprint == parent.provenance.input_fingerprint
            && correction.parent_transcript_sha256 == hash(parent.transcriptBytes)
            && correction.parent_provenance_sha256 == hash(parent.provenanceBytes), "The original transcript has changed since this correction.")
        try validateSelection(correction.segment_ids, speakerID: correction.speaker_id, transcript: parent.transcript)
        let expected = try corrected(parent, correction: correction)
        let actualTranscript = try data(child.rawTranscript)
        let actualProvenance = try data(child.rawProvenance)
        try Artifacts.require(actualTranscript == expected.transcript && actualProvenance == expected.provenance,
                              "The speaker correction no longer matches its original transcript.")
        if let summary = correction.parent_summary_id {
            try validateSummary(summary, revision: correction.parent_revision_id, transcript: parent.transcript, store: store, meeting: meeting)
        }
        return (correction, parent)
    }

    private static func validateSelection(_ ids: [String], speakerID: String, transcript: Transcript) throws {
        try Artifacts.require(!ids.isEmpty && Set(ids).count == ids.count && ids.allSatisfy(Artifacts.identifier),
                              "Select at least one distinct Unknown transcript line.")
        try Artifacts.require(transcript.speakers.contains { $0.id == speakerID && $0.source == .system },
                              "Choose an existing remote speaker.")
        let selected = Set(ids)
        let segments = transcript.segments.filter { selected.contains($0.id) }
        try Artifacts.require(segments.count == ids.count && segments.allSatisfy {
            $0.source == .system && $0.speaker_id == nil && !$0.overlap
        }, "Only Unknown remote speech without overlap can be assigned manually.")
    }

    private static func corrected(_ parent: Snapshot, correction: SpeakerCorrection) throws -> (transcript: Data, provenance: Data) {
        var transcript = parent.rawTranscript
        let ids = Set(correction.segment_ids)
        guard let segments = transcript["segments"] as? [[String: Any]] else {
            throw CaptureFailure(message: "Transcript segments are invalid.")
        }
        transcript["segments"] = segments.map { segment in
            var result = segment
            if let id = result["id"] as? String, ids.contains(id) {
                result["speaker_id"] = correction.speaker_id
                result["attribution_reason"] = "manual_assignment"
            }
            return result
        }
        transcript["run_id"] = correction.run_id
        transcript["revision_id"] = correction.revision_id
        var provenance = parent.rawProvenance
        var history: [[String: Any]] = []
        if let prior = provenance["speaker_corrections"] {
            guard let priorHistory = prior as? [[String: Any]] else {
                throw CaptureFailure(message: "Speaker correction history is invalid.")
            }
            history = priorHistory
        }
        let record = try object(JSONEncoder().encode(correction))
        history.append(record)
        provenance["speaker_corrections"] = history
        provenance["run_id"] = correction.run_id
        provenance["revision_id"] = correction.revision_id
        provenance["input_fingerprint"] = try hash(data(record))
        return try (data(transcript), data(provenance))
    }

    private static func validateSummary(_ id: String, revision: String, transcript: Transcript, store: MeetingStore, meeting: Meeting) throws {
        let summary = try Artifacts.read(MeetingSummary.self, store: store, meetingID: meeting.id,
                                         path: "revisions/\(revision)/summaries/\(id).json")
        try Artifacts.validate(summary, transcript: transcript, summaryID: id)
    }

    private static func editable(store: MeetingStore, meetingID: String, expectedRevisionID: String) throws -> Meeting {
        let meeting = try store.load(id: meetingID)
        try Artifacts.require(!meeting.captureState.isActive
            && !["running", "processing", "cancelling", "queued", "deferred", "paused"].contains(meeting.processingStatus),
            "Wait for recording or processing to finish before correcting speakers.")
        try Artifacts.require(meeting.activeRevisionID == expectedRevisionID, "The transcript changed. Reload it before correcting speakers.")
        return meeting
    }

    private static func locked<T>(store: MeetingStore, meetingID: String, body: () throws -> T) throws -> T {
        let url = try store.artifactURL(meetingID: meetingID, relativePath: ".processing.lock")
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ProcessingCleanupPending(meetingID: meetingID) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw ProcessingCleanupPending(meetingID: meetingID) }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private static func bytes(store: MeetingStore, meetingID: String, path: String) throws -> Data {
        let url = try store.artifactURL(meetingID: meetingID, relativePath: path)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try Artifacts.require(size <= 16 * 1_024 * 1_024, "A transcript artifact exceeds the size limit.")
        return try Data(contentsOf: url)
    }

    private static func object(_ bytes: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw CaptureFailure(message: "A transcript artifact is not a JSON object.")
        }
        return value
    }

    private static func data(_ value: [String: Any]) throws -> Data {
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        try Artifacts.require(bytes.count <= 16 * 1_024 * 1_024, "A transcript artifact exceeds the size limit.")
        return bytes
    }

    private static func hash(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func write(_ bytes: Data, to url: URL) throws {
        try bytes.write(to: url, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}
