import AfterwordCore
import XCTest
@testable import AfterwordApp

final class ArtifactRecoveryTests: XCTestCase {
    func testSupportedAlignmentRevisionsRemainReadableButFutureVersionsDoNot() throws {
        try fixture { store, meeting in
            try publish(store: store, meeting: meeting, summary: nil)
            for version in [1, 2, 3, 4, 0, 5] {
                try write(["schema_version": 1, "run_id": "new-run", "meeting_id": meeting.id, "revision_id": "new-revision",
                           "input_fingerprint": "fixture", "committed_audio_fingerprint": Artifacts.audioFingerprint(meeting.chunks),
                           "preparation_version": 1, "alignment_version": version],
                          path: "revisions/new-revision/provenance.json", store: store, meeting: meeting)
                if (1...4).contains(version) {
                    XCTAssertNoThrow(try Artifacts.loadRevision(store: store, meeting: meeting, revision: "new-revision"))
                } else {
                    XCTAssertThrowsError(try Artifacts.loadRevision(store: store, meeting: meeting, revision: "new-revision"))
                }
            }
        }
    }

    private func fixture(_ body: (MeetingStore, inout Meeting) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("afterword-artifact-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(rootURL: directory)
        var meeting = try store.create(title: "Artifact recovery")
        meeting.captureState = .stopped
        meeting.intervals = [CaptureInterval(generation: 0, startUS: 0, endUS: 1_000_000)]
        meeting.chunks = [ChunkDescriptor(id: "audio", source: .microphone, generation: 0, startUS: 0,
                         frameCount: 16_000, sampleRate: 16_000, channelCount: 1, relativePath: "audio/audio/audio.caf")]
        meeting.chunks.append(ChunkDescriptor(id: "system", source: .system, generation: 0, startUS: 0,
                              frameCount: 16_000, sampleRate: 16_000, channelCount: 1, relativePath: "audio/system/audio.caf"))
        meeting.processingStatus = "processing"
        meeting.processingRunID = "new-run"
        meeting.pendingRevisionID = "new-revision"
        meeting.pendingSummaryID = "new-summary"
        meeting.processingNameMapRevision = try Artifacts.nameMapRevision([:])
        try store.save(meeting)
        try body(store, &meeting)
    }

    private func write(_ value: [String: Any], path: String, store: MeetingStore, meeting: Meeting) throws {
        let url = try store.artifactURL(meetingID: meeting.id, relativePath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value).write(to: url)
    }

    private func publish(store: MeetingStore, meeting: Meeting, revision: String = "new-revision", run: String = "new-run",
                         summary: String? = "new-summary", fingerprint: String? = nil, preview: Bool = false) throws {
        var transcript: [String: Any] = ["schema_version": 1, "run_id": run, "meeting_id": meeting.id, "revision_id": revision,
            "speakers": [["id": "local", "source": "microphone", "label": "You"]], "warnings": [],
            "coverage": [["source": "microphone", "start_us": 0, "end_us": 1_000_000]],
            "segments": [["id": "s1", "source": "microphone", "start_us": 0, "end_us": 1_000_000,
                "text": "We agreed to send the report", "speaker_id": "local", "attribution_reason": "microphone", "overlap": false]]]
        if preview {
            transcript["coverage"] = ["microphone", "system"].map {
                ["source": $0, "start_us": 0, "end_us": 1_000_000] as [String: Any]
            }
            transcript["segments"] = (transcript["segments"] as! [[String: Any]]) + [
                ["id": "s2", "source": "system", "start_us": 0, "end_us": 1_000_000,
                 "text": "Remote evidence", "speaker_id": NSNull(), "attribution_reason": "speaker_labeling_pending", "overlap": false]]
            transcript["warnings"] = ["Speaker labeling is pending."]
        }
        try write(transcript, path: "revisions/\(revision)/transcript.json", store: store, meeting: meeting)
        try write(["schema_version": 1, "run_id": run, "meeting_id": meeting.id, "revision_id": revision,
                   "input_fingerprint": "fixture", "committed_audio_fingerprint": fingerprint ?? Artifacts.audioFingerprint(meeting.chunks),
                   "preparation_version": 1, "alignment_version": 1], path: "revisions/\(revision)/provenance.json", store: store, meeting: meeting)
        if let summary {
            try publishSummary(store: store, meeting: meeting, revision: revision, run: run, summary: summary)
        }
    }

    private func publishSummary(store: MeetingStore, meeting: Meeting, revision: String, run: String, summary: String) throws {
        try write(["schema_version": 1, "run_id": run, "meeting_id": meeting.id, "revision_id": revision, "summary_id": summary,
                   "name_map_revision": try Artifacts.nameMapRevision([:]), "covered_segment_ids": ["s1"],
                   "overview": [["text": "Report discussed", "segment_ids": ["s1"]]],
                   "discussion_points": [], "decisions": [], "action_items": [], "open_questions": []],
                  path: "revisions/\(revision)/summaries/\(summary).json", store: store, meeting: meeting)
    }

    func testPublishedArtifactsSurviveCrashBeforePointerUpdate() throws {
        try fixture { store, meeting in
            meeting.activeRevisionID = "old-revision"
            meeting.activeSummaryID = "old-summary"
            meeting.pendingBaseRevisionID = "old-revision"
            meeting.pendingBaseSummaryID = "old-summary"
            meeting.speakerNames["old-revision"] = ["local": "Alice"]
            try store.save(meeting)
            try publish(store: store, meeting: meeting, revision: "old-revision", run: "old-run", summary: "old-summary")
            try publish(store: store, meeting: meeting)
            let recovered = try ArtifactRecovery.recover(meeting, store: store)
            XCTAssertEqual(recovered.activeRevisionID, "new-revision")
            XCTAssertEqual(recovered.activeSummaryID, "new-summary")
            XCTAssertEqual(recovered.processingStatus, "completed")
            XCTAssertNil(recovered.processingRunID)
            XCTAssertEqual(recovered.speakerNames["new-revision"], [:])
            XCTAssertEqual(recovered.speakerNames["old-revision"], ["local": "Alice"])
            XCTAssertEqual(try ArtifactRecovery.recover(recovered, store: store), recovered)
        }
    }

    func testBadPendingProvenanceCannotReplaceAcceptedRevision() throws {
        try fixture { store, meeting in
            meeting.activeRevisionID = "old-revision"
            meeting.activeSummaryID = "old-summary"
            meeting.pendingBaseRevisionID = "old-revision"
            meeting.pendingBaseSummaryID = "old-summary"
            try store.save(meeting)
            try publish(store: store, meeting: meeting, fingerprint: "wrong-audio")
            XCTAssertThrowsError(try ArtifactRecovery.recover(meeting, store: store))
            let unchanged = try store.load(id: meeting.id)
            XCTAssertEqual(unchanged.activeRevisionID, "old-revision")
            XCTAssertEqual(unchanged.activeSummaryID, "old-summary")
        }
    }

    func testStalePendingTargetCannotOverwriteNewerAcceptedRevision() throws {
        try fixture { store, meeting in
            meeting.pendingBaseRevisionID = "old-revision"
            meeting.activeRevisionID = "newer-revision"
            meeting.activeSummaryID = "newer-summary"
            try store.save(meeting)
            try publish(store: store, meeting: meeting)
            let recovered = try ArtifactRecovery.recover(meeting, store: store)
            XCTAssertEqual(recovered.activeRevisionID, "newer-revision")
            XCTAssertEqual(recovered.activeSummaryID, "newer-summary")
            XCTAssertNil(recovered.pendingRevisionID)
        }
    }

    func testSummaryOnlyRecoveryReusesAcceptedTranscriptAndPreservesCancellation() throws {
        try fixture { store, meeting in
            meeting.activeRevisionID = "new-revision"
            meeting.pendingBaseRevisionID = "new-revision"
            meeting.processingStatus = "cancelled"
            try store.save(meeting)
            try publish(store: store, meeting: meeting, run: "old-run", summary: nil)
            try publishSummary(store: store, meeting: meeting, revision: "new-revision", run: "new-run", summary: "new-summary")
            let recovered = try ArtifactRecovery.recover(meeting, store: store)
            XCTAssertEqual(recovered.activeSummaryID, "new-summary")
            XCTAssertEqual(recovered.processingStatus, "cancelled")
        }
    }

    func testPublishedASRPreviewSurvivesCrashBeforePointerUpdate() throws {
        try fixture { store, meeting in
            meeting.activeRevisionID = "old-revision"
            meeting.activeSummaryID = "old-summary"
            meeting.pendingBaseRevisionID = "old-revision"
            meeting.pendingBaseSummaryID = "old-summary"
            meeting.speakerNames["old-revision"] = ["local": "Alice"]
            try store.save(meeting)
            try publish(store: store, meeting: meeting, revision: "old-revision", run: "old-run", summary: "old-summary")
            try publish(store: store, meeting: meeting, revision: "new-run", summary: nil, preview: true)
            let recovered = try ArtifactRecovery.recover(meeting, store: store)
            XCTAssertEqual(recovered.activeRevisionID, "new-run")
            XCTAssertNil(recovered.activeSummaryID)
            XCTAssertEqual(recovered.pendingRevisionID, "new-revision")
            XCTAssertEqual(recovered.processingStatus, "failed")
            XCTAssertEqual(recovered.speakerNames["new-run"], [:])
            XCTAssertEqual(recovered.speakerNames["old-revision"], ["local": "Alice"])
            _ = try Artifacts.loadRevision(store: store, meeting: recovered, revision: "old-revision")
            XCTAssertEqual(try ArtifactRecovery.recover(recovered, store: store), recovered)
        }
    }

    func testActivePreviewRemainsReadableAfterCancellationOrLabelingFailure() throws {
        for status in ["cancelled", "failed"] {
            try fixture { store, meeting in
                meeting.activeRevisionID = "new-run"
                meeting.speakerNames["new-run"] = ["local": "Me"]
                meeting.processingStatus = status
                meeting.processingError = "Fixture interruption"
                try store.save(meeting)
                try publish(store: store, meeting: meeting, revision: "new-run", summary: nil, preview: true)
                let recovered = try ArtifactRecovery.recover(meeting, store: store)
                XCTAssertEqual(recovered.activeRevisionID, "new-run")
                XCTAssertEqual(recovered.processingStatus, status)
                XCTAssertEqual(recovered.processingRunID, "new-run")
                XCTAssertEqual(recovered.speakerNames["new-run"], ["local": "Me"])
                if status == "cancelled" { XCTAssertEqual(recovered.processingError, "Fixture interruption") }
                _ = try Artifacts.loadRevision(store: store, meeting: recovered, revision: "new-run", run: "new-run")
            }
        }
    }

    func testCompletedFinalRevisionSupersedesExpectedActivePreview() throws {
        try fixture { store, meeting in
            meeting.activeRevisionID = "new-run"
            try store.save(meeting)
            try publish(store: store, meeting: meeting, revision: "new-run", summary: nil, preview: true)
            try publish(store: store, meeting: meeting)
            let recovered = try ArtifactRecovery.recover(meeting, store: store)
            XCTAssertEqual(recovered.activeRevisionID, "new-revision")
            XCTAssertEqual(recovered.activeSummaryID, "new-summary")
            XCTAssertEqual(recovered.processingStatus, "completed")
            XCTAssertNil(recovered.processingRunID)
        }
    }

    func testInvalidPreviewCannotReplaceAcceptedArtifacts() throws {
        for wrongRun in [false, true] {
            try fixture { store, meeting in
                meeting.activeRevisionID = "old-revision"
                meeting.activeSummaryID = "old-summary"
                meeting.pendingBaseRevisionID = "old-revision"
                meeting.pendingBaseSummaryID = "old-summary"
                try store.save(meeting)
                try publish(store: store, meeting: meeting, revision: "new-run", run: wrongRun ? "other-run" : "new-run",
                            summary: nil, fingerprint: wrongRun ? nil : "wrong-audio", preview: true)
                XCTAssertThrowsError(try ArtifactRecovery.recover(meeting, store: store))
                XCTAssertEqual(try store.load(id: meeting.id), meeting)
            }
        }
    }

    func testPreviewCannotOverwriteUnrelatedAcceptedRevision() throws {
        try fixture { store, meeting in
            meeting.pendingBaseRevisionID = "old-revision"
            meeting.activeRevisionID = "newer-revision"
            meeting.activeSummaryID = "newer-summary"
            try store.save(meeting)
            try publish(store: store, meeting: meeting, revision: "new-run", summary: nil, preview: true)
            let recovered = try ArtifactRecovery.recover(meeting, store: store)
            XCTAssertEqual(recovered.activeRevisionID, "newer-revision")
            XCTAssertEqual(recovered.activeSummaryID, "newer-summary")
            XCTAssertNil(recovered.processingRunID)
        }
    }

    func testInvalidFinalRevisionLeavesValidPreviewReadable() throws {
        try fixture { store, meeting in
            try publish(store: store, meeting: meeting, revision: "new-run", summary: nil, preview: true)
            try publish(store: store, meeting: meeting, fingerprint: "wrong-audio")
            let recovered = try ArtifactRecovery.recover(meeting, store: store)
            XCTAssertEqual(recovered.activeRevisionID, "new-run")
            XCTAssertNil(recovered.activeSummaryID)
            XCTAssertEqual(recovered.processingStatus, "failed")
            XCTAssertEqual(recovered.pendingRevisionID, "new-revision")
        }
    }

    func testRunIDRevisionWithoutPendingSpeakerMarkerCannotBecomePreview() throws {
        try fixture { store, meeting in
            meeting.activeRevisionID = "old-revision"
            meeting.activeSummaryID = "old-summary"
            meeting.pendingBaseRevisionID = "old-revision"
            try store.save(meeting)
            try publish(store: store, meeting: meeting, revision: "new-run", summary: nil)
            XCTAssertThrowsError(try ArtifactRecovery.recover(meeting, store: store))
            XCTAssertEqual(try store.load(id: meeting.id), meeting)
        }
    }

    func testSummaryOnlyRecoveryDoesNotAdoptRunIDPreview() throws {
        try fixture { store, meeting in
            meeting.activeRevisionID = "new-revision"
            meeting.activeSummaryID = "old-summary"
            meeting.pendingBaseRevisionID = "new-revision"
            meeting.pendingBaseSummaryID = "old-summary"
            try store.save(meeting)
            try publish(store: store, meeting: meeting, revision: "new-run", summary: nil, preview: true)
            XCTAssertEqual(try ArtifactRecovery.recover(meeting, store: store), meeting)
        }
    }
}
