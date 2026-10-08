import AfterwordCore
import XCTest
@testable import AfterwordApp

final class SpeakerRenameTests: XCTestCase {
    @MainActor
    private func fixture(_ body: (MeetingStore, Meeting, ProcessingController) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("afterword-speaker-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(rootURL: directory)
        var meeting = try store.create(title: "Speaker names")
        meeting.captureState = .stopped
        meeting.intervals = [CaptureInterval(generation: 0, startUS: 0, endUS: 2_000_000)]
        meeting.chunks = [ChunkDescriptor(id: "system-audio", source: .system, generation: 0, startUS: 0,
                         frameCount: 32_000, sampleRate: 16_000, channelCount: 1, relativePath: "audio/system-audio/audio.caf")]
        meeting.activeRevisionID = "revision-one"
        meeting.activeSummaryID = "summary-one"
        meeting.speakerNames["archived-revision"] = ["remote-001": "Earlier name"]
        try store.save(meeting)
        try publishRevision("revision-one", store: store, meeting: meeting)
        try body(store, meeting, ProcessingController(store: store))
    }

    private func publishRevision(_ revision: String, store: MeetingStore, meeting: Meeting) throws {
        let transcript: [String: Any] = ["schema_version": 1, "run_id": "run-\(revision)", "meeting_id": meeting.id,
            "revision_id": revision, "warnings": [],
            "speakers": [["id": "remote-001", "source": "system", "label": "Speaker 1"]],
            "coverage": [["source": "system", "start_us": 0, "end_us": 2_000_000]],
            "segments": [
                ["id": "assigned", "source": "system", "start_us": 0, "end_us": 1_000_000,
                 "text": "Assigned speech", "speaker_id": "remote-001", "attribution_reason": "single_exclusive_turn", "overlap": false],
                ["id": "unknown", "source": "system", "start_us": 1_000_000, "end_us": 2_000_000,
                 "text": "Unassigned speech", "speaker_id": NSNull(), "attribution_reason": "incomplete_timing_coverage", "overlap": false]]]
        let provenance: [String: Any] = ["schema_version": 1, "run_id": "run-\(revision)", "meeting_id": meeting.id,
            "revision_id": revision, "input_fingerprint": "fixture", "committed_audio_fingerprint": Artifacts.audioFingerprint(meeting.chunks),
            "preparation_version": 1, "alignment_version": 1]
        for (name, value) in [("transcript", transcript), ("provenance", provenance)] {
            let path = try store.artifactURL(meetingID: meeting.id, relativePath: "revisions/\(revision)/\(name).json")
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: value, options: .sortedKeys).write(to: path)
        }
    }

    @MainActor
    func testRenamePersistsWithoutChangingTranscriptOrUnknownAssignments() throws {
        try fixture { store, meeting, processor in
            let path = try store.artifactURL(meetingID: meeting.id, relativePath: "revisions/revision-one/transcript.json")
            let original = try Data(contentsOf: path)
            var notifications = 0
            processor.changed = { notifications += 1 }
            try processor.rename(meeting: meeting, speakerID: "remote-001", name: "  Yu Hu\n")
            let reloaded = try MeetingStore(rootURL: store.rootURL).load(id: meeting.id)
            XCTAssertEqual(reloaded.speakerNames["revision-one"], ["remote-001": "Yu Hu"])
            XCTAssertEqual(reloaded.speakerNames["archived-revision"], ["remote-001": "Earlier name"])
            XCTAssertEqual(reloaded.activeRevisionID, "revision-one")
            XCTAssertEqual(reloaded.activeSummaryID, "summary-one")
            XCTAssertEqual(notifications, 1)
            XCTAssertEqual(try Data(contentsOf: path), original)
            let transcript = try processor.loadTranscript(reloaded)
            XCTAssertEqual(transcript.segments.first?.speaker_id, "remote-001")
            let unknown = try XCTUnwrap(transcript.segments.first { $0.id == "unknown" })
            XCTAssertNil(unknown.speaker_id)
            XCTAssertEqual(unknown.attribution_reason, "incomplete_timing_coverage")
            XCTAssertEqual(transcript.speakers.first?.label, "Speaker 1")
        }
    }

    @MainActor
    func testStaleEditorCannotRenameReusedClusterIDInNewRevision() throws {
        try fixture { store, editorMeeting, processor in
            var current = editorMeeting
            current.activeRevisionID = "revision-two"
            current.activeSummaryID = nil
            current.speakerNames["revision-two"] = ["remote-001": "Different person"]
            try publishRevision("revision-two", store: store, meeting: current)
            try store.save(current)
            let path = try store.meetingURL(id: current.id).appendingPathComponent("meeting.json")
            let original = try Data(contentsOf: path)
            var notifications = 0
            processor.changed = { notifications += 1 }
            XCTAssertThrowsError(try processor.rename(meeting: editorMeeting, speakerID: "remote-001", name: "Stale name"))
            XCTAssertEqual(try Data(contentsOf: path), original)
            XCTAssertEqual(try store.load(id: current.id).speakerNames["revision-two"], ["remote-001": "Different person"])
            XCTAssertEqual(notifications, 0)
        }
    }
}
