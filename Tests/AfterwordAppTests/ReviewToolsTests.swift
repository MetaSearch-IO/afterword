import AfterwordCore
import XCTest
@testable import AfterwordApp

final class ReviewToolsTests: XCTestCase {
    private func fixture() throws -> ReviewExportSnapshot {
        var meeting = Meeting(id: "meeting", title: "讨论 / *release* [计划]")
        meeting.captureState = .stopped
        meeting.activeRevisionID = "revision"
        meeting.activeSummaryID = "summary"
        meeting.speakerNames["revision"] = ["remote": "于虎 & Team"]
        meeting.intervals = [CaptureInterval(generation: 0, startUS: 0, endUS: 2_000_000),
                             CaptureInterval(generation: 1, startUS: 5_000_000, endUS: 6_000_000)]
        meeting.chunks = [ChunkDescriptor(id: "one", source: .system, generation: 0, startUS: 0,
                frameCount: 32_000, sampleRate: 16_000, channelCount: 1, relativePath: "audio/one/audio.caf"),
            ChunkDescriptor(id: "two", source: .system, generation: 1, startUS: 5_000_000,
                frameCount: 16_000, sampleRate: 16_000, channelCount: 1, relativePath: "audio/two/audio.caf")]
        let transcript = Transcript(schema_version: 1, run_id: "run", meeting_id: "meeting", revision_id: "revision",
            segments: [TranscriptSegment(id: "s1", source: .system, start_us: 0, end_us: 1_000_000,
                        text: "我会发送报告。 café RELEASE", speaker_id: "remote", attribution_reason: "manual_assignment", overlap: false),
                TranscriptSegment(id: "s2", source: .system, start_us: 1_000_000, end_us: 2_000_000,
                    text: "Do not render ![link](https://example.invalid) or <img>. Keep &copy; and &#65;.", speaker_id: nil,
                    attribution_reason: "speaker_labeling_pending", overlap: false),
                TranscriptSegment(id: "s3", source: .system, start_us: 5_000_000, end_us: 6_000_000,
                    text: "讨论 release", speaker_id: "remote", attribution_reason: "exclusive", overlap: false)],
            speakers: [TranscriptSpeaker(id: "remote", source: .system, label: "Speaker 1")],
            coverage: [TranscriptCoverage(source: .system, start_us: 0, end_us: 2_000_000),
                       TranscriptCoverage(source: .system, start_us: 5_000_000, end_us: 6_000_000)], warnings: ["Private diagnostic"])
        let summary = MeetingSummary(schema_version: 1, run_id: "summary-run", meeting_id: "meeting", revision_id: "revision",
            summary_id: "summary", name_map_revision: try Artifacts.nameMapRevision([:]), covered_segment_ids: ["s1", "s2", "s3"],
            overview: [SummaryNote(text: "First paragraph.", segment_ids: ["s1"]), SummaryNote(text: "接着讨论。", segment_ids: ["s3"])],
            discussion_points: [SummaryNote(text: "List item with *literal* markers", segment_ids: ["s2"])], decisions: [],
            action_items: [SummaryAction(text: "我会发送报告。", segment_ids: ["s1"], owner_speaker_id: "remote",
                owner_evidence_segment_ids: ["s1"], due_date: nil, due_date_evidence_segment_ids: [])], open_questions: [])
        return ReviewExportSnapshot(meeting: meeting, transcript: transcript, summary: summary)
    }

    func testVoiceLabelsFollowOnlyTheirRevisionOrCorrectionLineage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("afterword-voice-labels-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(rootURL: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("meeting"), withIntermediateDirectories: true)
        try store.save(try fixture().meeting)
        func write(_ value: [String: Any], _ path: String) throws {
            let url = try store.artifactURL(meetingID: "meeting", relativePath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: value).write(to: url)
        }
        let original = try fixture().transcript
        try write(["schema_version": 1, "meeting_id": "meeting", "revision_id": "revision", "run_id": "run",
                   "profiles": [["speaker_id": "remote", "voice_id": String(repeating: "a", count: 32)]],
                   "model_fingerprint": String(repeating: "f", count: 64)], "voice_profiles.json")
        XCTAssertEqual(try VoiceProfileLabels.load(store: store, meetingID: "meeting", transcript: original)["remote"], "Voice AAAAAAAA")
        let child = Transcript(schema_version: 1, run_id: "edit", meeting_id: "meeting", revision_id: "child",
                               segments: original.segments, speakers: original.speakers,
                               coverage: original.coverage, warnings: original.warnings)
        try write(["schema_version": 1], "revisions/child/provenance.json")
        XCTAssertEqual(try VoiceProfileLabels.load(store: store, meetingID: "meeting", transcript: child), [:])
        try write(["schema_version": 1, "run_id": "run", "meeting_id": "meeting", "revision_id": "revision",
                   "speakers": [["id": "remote", "source": "system", "label": "Speaker 1"]], "segments": [],
                   "coverage": [], "warnings": []], "revisions/revision/transcript.json")
        try write(["schema_version": 1, "speaker_corrections": [["schema_version": 1,
                   "revision_id": "child", "run_id": "edit", "parent_revision_id": "revision",
                   "parent_summary_id": NSNull(), "parent_input_fingerprint": "fixture",
                   "parent_transcript_sha256": "fixture", "parent_provenance_sha256": "fixture",
                   "segment_ids": ["s2"], "speaker_id": "remote"]]], "revisions/child/provenance.json")
        XCTAssertEqual(try VoiceProfileLabels.load(store: store, meetingID: "meeting", transcript: child)["remote"], "Voice AAAAAAAA")
    }

    func testSearchFindsChineseCaseDiacriticsAndCurrentSpeakerNamesWithoutReordering() throws {
        let snapshot = try fixture()
        XCTAssertEqual(TranscriptSearch.matches(" RELEASE ", transcript: snapshot.transcript, names: snapshot.names), ["s1", "s3"])
        XCTAssertEqual(TranscriptSearch.matches("发送", transcript: snapshot.transcript, names: snapshot.names), ["s1"])
        XCTAssertEqual(TranscriptSearch.matches("cafe", transcript: snapshot.transcript, names: snapshot.names), ["s1"])
        XCTAssertEqual(TranscriptSearch.matches("于虎", transcript: snapshot.transcript, names: snapshot.names), ["s1", "s3"])
        XCTAssertEqual(TranscriptSearch.matches("unknown", transcript: snapshot.transcript, names: snapshot.names), ["s2"])
        XCTAssertEqual(TranscriptSearch.matches("Speaker 1", transcript: snapshot.transcript, names: snapshot.names), [])
        XCTAssertEqual(TranscriptSearch.matches(" \n ", transcript: snapshot.transcript, names: snapshot.names), [])
        XCTAssertEqual(snapshot.transcript.segments.map(\.id), ["s1", "s2", "s3"])
    }

    func testSearchNavigationWrapsAndHandlesEvidenceSelectionOutsideMatches() {
        let matches = ["one", "two", "three"]
        XCTAssertEqual(TranscriptSearch.next(in: matches, after: nil), "one")
        XCTAssertEqual(TranscriptSearch.next(in: matches, after: "one"), "two")
        XCTAssertEqual(TranscriptSearch.next(in: matches, after: "three"), "one")
        XCTAssertEqual(TranscriptSearch.next(in: matches, after: "one", backwards: true), "three")
        XCTAssertEqual(TranscriptSearch.next(in: matches, after: "evidence", backwards: true), "three")
        XCTAssertEqual(TranscriptSearch.next(in: ["one"], after: "one"), "one")
        XCTAssertNil(TranscriptSearch.next(in: [], after: "one"))
    }

    func testPlainExportUsesCurrentNamesParagraphsAndPendingStaleNotices() throws {
        let snapshot = try fixture()
        let output = ReviewExport.render(snapshot, scope: .all, format: .plainText)
        XCTAssertTrue(output.contains("First paragraph. 接着讨论。"))
        XCTAssertTrue(output.contains("Owner: 于虎 & Team · Due: Unspecified"))
        XCTAssertTrue(output.contains("[00:05] 于虎 & Team: 讨论 release"))
        XCTAssertTrue(output.contains("[00:01] Unknown: Do not render ![link](https://example.invalid) or <img>."))
        XCTAssertTrue(output.contains("Speaker labels are pending"))
        XCTAssertTrue(output.contains("Speaker names changed"))
        XCTAssertTrue(output.contains("Recording paused: 00:02–00:05"))
        XCTAssertFalse(output.contains("Private diagnostic"))
        XCTAssertFalse(output.contains("manual_assignment"))
        XCTAssertFalse(output.contains("segment_ids"))
        XCTAssertTrue(output.hasSuffix("\n"))
    }

    func testMarkdownEscapesContentAndExportScopesDoNotLeakHiddenSections() throws {
        let snapshot = try fixture()
        let notes = ReviewExport.render(snapshot, scope: .notes, format: .markdown)
        XCTAssertTrue(notes.hasPrefix("# 讨论 / \\*release\\* \\[计划\\]"))
        XCTAssertTrue(notes.contains("- List item with \\*literal\\* markers"))
        XCTAssertFalse(notes.contains("## Transcript"))
        XCTAssertFalse(notes.contains("https://example"))
        let transcript = ReviewExport.render(snapshot, scope: .transcript, format: .markdown)
        XCTAssertTrue(transcript.contains("\\!\\[link\\]\\(https://example\\.invalid\\) or \\<img\\>\\."))
        XCTAssertTrue(transcript.contains("&amp;copy; and &amp;\\#65;"))
        XCTAssertTrue(transcript.contains("于虎 &amp; Team"))
        XCTAssertFalse(transcript.contains("First paragraph"))
        XCTAssertFalse(transcript.contains("## Notes"))
        let noNotes = ReviewExportSnapshot(meeting: snapshot.meeting, transcript: snapshot.transcript, summary: nil)
        XCTAssertTrue(ReviewExport.render(noNotes, scope: .notes, format: .plainText).contains("Notes are not available"))
    }

    func testExportFilenameIsBoundedAndRemovesPathAndControlCharacters() {
        let filename = ReviewExport.filename(title: "../秘密/计划:\n\\notes", scope: .transcript, format: .markdown)
        XCTAssertFalse(filename.contains("/"))
        XCTAssertFalse(filename.contains("\\"))
        XCTAssertFalse(filename.contains(":"))
        XCTAssertFalse(filename.contains("\n"))
        XCTAssertFalse(filename.hasPrefix("."))
        XCTAssertTrue(filename.hasSuffix(" - Transcript.md"))
        XCTAssertEqual(ReviewExport.filename(title: "...", scope: .notes, format: .plainText), "Meeting - Notes.txt")
        XCTAssertLessThan(ReviewExport.filename(title: String(repeating: "长", count: 500), scope: .all, format: .plainText).count, 160)
        for title in [String(repeating: "长", count: 500), String(repeating: "👩🏽‍💻", count: 100)] {
            let filename = ReviewExport.filename(title: title, scope: .all, format: .markdown)
            XCTAssertLessThanOrEqual(filename.utf8.count, 255)
            let stem = String(filename.dropLast(" - Notes and Transcript.md".count))
            XCTAssertTrue(title.hasPrefix(stem))
        }
    }

    func testSnapshotLoadsValidatedArtifactsRejectsStaleUIAndSavePanelChanges() throws {
        let initial = try fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("afterword-review-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(rootURL: root)
        let folder = try store.artifactURL(meetingID: initial.meeting.id, relativePath: "revisions/revision/summaries")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try store.save(initial.meeting)
        func write(_ value: [String: Any], _ path: String) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: store.artifactURL(meetingID: initial.meeting.id, relativePath: path))
        }
        try write(["schema_version": 1, "run_id": "run", "meeting_id": "meeting", "revision_id": "revision",
            "speakers": [["id": "remote", "source": "system", "label": "Speaker 1"]], "warnings": [],
            "future_private_field": "PRIVATE_TRANSCRIPT_METADATA",
            "coverage": [["source": "system", "start_us": 0, "end_us": 2_000_000]],
            "segments": [["id": "s1", "source": "system", "start_us": 0, "end_us": 1_000_000,
                "text": "Export evidence", "speaker_id": "remote", "attribution_reason": "manual_assignment", "overlap": false]]],
            "revisions/revision/transcript.json")
        try write(["schema_version": 1, "run_id": "run", "meeting_id": "meeting", "revision_id": "revision",
            "input_fingerprint": "fixture", "committed_audio_fingerprint": Artifacts.audioFingerprint(initial.meeting.chunks),
            "preparation_version": 1, "alignment_version": 1,
            "runtime": ["native": ["private_path": "PRIVATE_RUNTIME_METADATA"]]], "revisions/revision/provenance.json")
        try write(["schema_version": 1, "run_id": "summary-run", "meeting_id": "meeting", "revision_id": "revision",
            "summary_id": "summary", "name_map_revision": try Artifacts.nameMapRevision(initial.names),
            "covered_segment_ids": ["s1"], "overview": [["text": "Validated note", "segment_ids": ["s1"]]],
            "discussion_points": [], "decisions": [], "action_items": [], "open_questions": []],
            "revisions/revision/summaries/summary.json")
        let saved = try ReviewExport.snapshot(store: store, meetingID: "meeting", expectedRevisionID: "revision", expectedSummaryID: "summary")
        let summaryURL = try store.artifactURL(meetingID: "meeting", relativePath: "revisions/revision/summaries/summary.json")
        let originalSummary = try Data(contentsOf: summaryURL)
        XCTAssertEqual(saved.names["remote"], "于虎 & Team")
        for format in ReviewExportFormat.allCases {
            for scope in ReviewExportScope.allCases {
                let output = ReviewExport.render(saved, scope: scope, format: format)
                XCTAssertFalse(output.contains("PRIVATE_TRANSCRIPT_METADATA"))
                XCTAssertFalse(output.contains("PRIVATE_RUNTIME_METADATA"))
                XCTAssertFalse(output.contains("input_fingerprint"))
            }
        }
        XCTAssertThrowsError(try ReviewExport.snapshot(store: store, meetingID: "meeting", expectedRevisionID: "stale", expectedSummaryID: "summary"))
        XCTAssertThrowsError(try ReviewExport.snapshot(store: store, meetingID: "meeting", expectedRevisionID: "revision", expectedSummaryID: nil))
        var progressOnly = initial.meeting
        progressOnly.processingStage = "summary"
        progressOnly.processingStatus = "processing"
        try store.save(progressOnly)
        XCTAssertNoThrow(try ReviewExport.validateCurrent(saved, store: store))
        for mutation in ["revision", "summary", "names", "title", "audio", "interval"] {
            var changed = initial.meeting
            switch mutation {
            case "revision": changed.activeRevisionID = "new-revision"
            case "summary": changed.activeSummaryID = nil
            case "names": changed.speakerNames["revision"]?["remote"] = "New name"
            case "title": changed.title = "Renamed"
            case "audio": changed.chunks.removeLast()
            default: changed.intervals[1].endUS = 7_000_000
            }
            try store.save(changed)
            XCTAssertThrowsError(try ReviewExport.validateCurrent(saved, store: store), mutation)
        }
        try store.save(initial.meeting)
        try write(["schema_version": 1, "meeting_id": "meeting", "revision_id": "revision", "run_id": "run",
                   "model_fingerprint": String(repeating: "f", count: 64),
                   "profiles": [["speaker_id": "remote", "voice_id": String(repeating: "a", count: 32),
                                 "vector": [1.0, 0.0]]]], "voice_profiles.json")
        XCTAssertThrowsError(try ReviewExport.validateCurrent(saved, store: store))
        var unnamed = initial.meeting
        unnamed.speakerNames["revision"] = [:]
        try store.save(unnamed)
        let voiced = try ReviewExport.snapshot(store: store, meetingID: "meeting", expectedRevisionID: "revision", expectedSummaryID: "summary")
        XCTAssertEqual(voiced.speakerName("remote"), "Voice AAAAAAAA")
        try store.save(initial.meeting)
        try Data("{}".utf8).write(to: summaryURL)
        XCTAssertThrowsError(try ReviewExport.snapshot(store: store, meetingID: "meeting", expectedRevisionID: "revision", expectedSummaryID: "summary"))
        try originalSummary.write(to: summaryURL)
        try MeetingDeletion.removeAudio(id: "meeting", rootURL: store.rootURL)
        XCTAssertEqual(try store.recover().first?.activeRevisionID, "revision")
        XCTAssertTrue(store.recoveryIssues.isEmpty)
        let kept = try ReviewExport.snapshot(store: store, meetingID: "meeting", expectedRevisionID: "revision", expectedSummaryID: "summary")
        XCTAssertEqual(ReviewExport.render(kept, scope: .all, format: .plainText),
                       ReviewExport.render(saved, scope: .all, format: .plainText))
    }
}
