import AfterwordCore
import Darwin
import Foundation

struct ProcessingCleanupPending: LocalizedError {
    let meetingID: String
    var errorDescription: String? { "Previous processing cleanup is not confirmed for meeting \(meetingID)." }
}

enum ArtifactRecovery {
    static func clearPending(_ meeting: inout Meeting) {
        meeting.processingRunID = nil
        meeting.pendingRevisionID = nil
        meeting.pendingSummaryID = nil
        meeting.pendingBaseRevisionID = nil
        meeting.pendingBaseSummaryID = nil
        meeting.processingNameMapRevision = nil
    }

    static func recover(_ original: Meeting, store: MeetingStore) throws -> Meeting {
        guard let run = original.processingRunID, let revision = original.pendingRevisionID,
              let summaryID = original.pendingSummaryID else { return original }
        let lockURL = try store.artifactURL(meetingID: original.id, relativePath: ".processing.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ProcessingCleanupPending(meetingID: original.id) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw ProcessingCleanupPending(meetingID: original.id)
        }
        defer { flock(descriptor, LOCK_UN) }
        var meeting = try store.load(id: original.id)
        guard meeting.processingRunID == run, meeting.pendingRevisionID == revision, meeting.pendingSummaryID == summaryID else { return meeting }
        let queuedIntent: Bool
        do {
            let snapshot = try ProcessingRequest.load(store: store, meeting: meeting)
            queuedIntent = snapshot != nil && ["queued", "paused", "interrupted"].contains(meeting.processingStatus)
        } catch {
            clearPending(&meeting)
            meeting.processingStatus = "failed"
            meeting.processingStage = nil
            meeting.processingError = error.localizedDescription
            try store.save(meeting)
            throw error
        }
        let summaryOnly = meeting.pendingBaseRevisionID == revision
        let preview = !summaryOnly && run != revision ? run : nil
        guard meeting.activeRevisionID == meeting.pendingBaseRevisionID || meeting.activeRevisionID == revision
                || (preview != nil && meeting.activeRevisionID == preview) else {
            clearPending(&meeting)
            if queuedIntent {
                meeting.processingStatus = "failed"
                meeting.processingStage = nil
                meeting.processingError = "The transcript changed. The stale processing request was discarded."
            }
            try store.save(meeting)
            return meeting
        }
        var recovered: (revision: String, transcript: Transcript)?
        var validationFailure: Error?
        for candidate in [revision, preview].compactMap({ $0 }) {
            do {
                let url = try store.artifactURL(meetingID: meeting.id, relativePath: "revisions/\(candidate)/transcript.json")
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let transcript = try Artifacts.loadRevision(store: store, meeting: meeting, revision: candidate, run: summaryOnly ? nil : run)
                if candidate == preview {
                    try Artifacts.require(transcript.speakerLabelsPending, "The pending ASR revision is not a speaker-labeling preview.")
                }
                recovered = (candidate, transcript)
                break
            } catch { validationFailure = error }
        }
        guard let recovered else {
            if let validationFailure { throw validationFailure }
            return meeting
        }
        let transcript = recovered.transcript
        if meeting.activeRevisionID != recovered.revision {
            meeting.activeRevisionID = recovered.revision
            meeting.activeSummaryID = nil
            meeting.speakerNames[recovered.revision] = [:]
            try store.save(meeting)
        }
        if recovered.revision == preview {
            if meeting.processingStatus != "cancelled" && !queuedIntent {
                meeting.processingStatus = "failed"
                meeting.processingError = "The transcript was recovered. Speaker labeling and notes did not finish; retry processing to continue."
            }
            meeting.processingStage = nil
            try store.save(meeting)
            return meeting
        }
        let summaryPath = "revisions/\(revision)/summaries/\(summaryID).json"
        let summaryURL = try store.artifactURL(meetingID: meeting.id, relativePath: summaryPath)
        let pointerUnchanged = meeting.activeSummaryID == nil || meeting.activeSummaryID == meeting.pendingBaseSummaryID || meeting.activeSummaryID == summaryID
        var recoveredSummary = false
        if pointerUnchanged && FileManager.default.fileExists(atPath: summaryURL.path) {
            let summary = try Artifacts.read(MeetingSummary.self, store: store, meetingID: meeting.id, path: summaryPath)
            try Artifacts.validate(summary, transcript: transcript, summaryID: summaryID, runID: run)
            try Artifacts.require(meeting.processingNameMapRevision == summary.name_map_revision,
                                  "Pending notes use an unexpected speaker name map.")
            meeting.activeSummaryID = summaryID
            recoveredSummary = true
        }
        if recoveredSummary || transcript.segments.isEmpty || !pointerUnchanged {
            clearPending(&meeting)
            if meeting.processingStatus != "cancelled" {
                meeting.processingStatus = "completed"
                meeting.processingError = nil
            }
        } else if meeting.processingStatus != "cancelled" && !queuedIntent {
            meeting.processingStatus = "failed"
            meeting.processingError = "The transcript was recovered. Notes are incomplete; regenerate notes to continue."
        }
        meeting.processingStage = nil
        try store.save(meeting)
        return meeting
    }
}
