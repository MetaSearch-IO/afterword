import AfterwordCore
import Darwin
import XCTest
@testable import AfterwordApp

final class SpeakerCorrectionsTests: XCTestCase {
    private func fixture(_ body: (MeetingStore, inout Meeting) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("afterword-speaker-corrections-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(rootURL: root)
        var meeting = try store.create(title: "Speaker correction 测试")
        meeting.captureState = .stopped
        meeting.intervals = [CaptureInterval(generation: 0, startUS: 0, endUS: 6_000_000)]
        meeting.chunks = AudioSource.allSources.map { source in
            ChunkDescriptor(id: source.rawValue, source: source, generation: 0, startUS: 0,
                frameCount: 96_000, sampleRate: 16_000, channelCount: 1, relativePath: "audio/\(source.rawValue)/audio.caf")
        }
        meeting.processingStatus = "completed"
        meeting.activeRevisionID = "parent"
        meeting.activeSummaryID = "notes"
        meeting.speakerNames["parent"] = ["local": "Me", "remote": "Yu Hu"]
        try store.save(meeting)
        let segments: [[String: Any]] = [
            ["id": "local-line", "source": "microphone", "start_us": 0, "end_us": 1_000_000, "text": "Local speech",
             "speaker_id": "local", "attribution_reason": "microphone", "overlap": false],
            ["id": "unknown-1", "source": "system", "start_us": 1_000_000, "end_us": 2_000_000, "text": "我会发送报告。",
             "speaker_id": NSNull(), "attribution_reason": "incomplete_speaker_timing", "overlap": false,
             "future_metadata": ["token": 9_007_199_254_740_991 as Int64, "probability": 0.123456789]],
            ["id": "known", "source": "system", "start_us": 2_000_000, "end_us": 3_000_000, "text": "Already assigned",
             "speaker_id": "remote", "attribution_reason": "exclusive", "overlap": false],
            ["id": "overlap", "source": "system", "start_us": 3_000_000, "end_us": 4_000_000, "text": "Overlapping speech",
             "speaker_id": NSNull(), "attribution_reason": "overlap", "overlap": true],
            ["id": "unknown-2", "source": "system", "start_us": 4_000_000, "end_us": 5_000_000, "text": "Another line",
             "speaker_id": NSNull(), "attribution_reason": "incomplete_speaker_timing", "overlap": false]]
        try write(["schema_version": 1, "run_id": "original-run", "meeting_id": meeting.id, "revision_id": "parent",
            "segments": segments, "speakers": [["id": "local", "source": "microphone", "label": "You"],
                                               ["id": "remote", "source": "system", "label": "Speaker 1"]],
            "coverage": AudioSource.allSources.map { ["source": $0.rawValue, "start_us": 0, "end_us": 6_000_000] as [String: Any] },
            "warnings": ["Original warning"], "future_field": ["preserve": true]],
            path: "revisions/parent/transcript.json", store: store, meeting: meeting)
        try write(["schema_version": 1, "run_id": "original-run", "meeting_id": meeting.id, "revision_id": "parent",
            "input_fingerprint": "original-input", "committed_audio_fingerprint": Artifacts.audioFingerprint(meeting.chunks),
            "preparation_version": 1, "alignment_version": 1, "diarization_mode": "community1",
            "runtime": ["models": ["asr": ["sha256": "pinned-hash"]], "native": ["option": true]],
            "diarization_execution": ["device": "mps"], "future_field": [1, 2, 3]],
            path: "revisions/parent/provenance.json", store: store, meeting: meeting)
        try write(["schema_version": 1, "run_id": "original-run", "meeting_id": meeting.id, "revision_id": "parent",
            "summary_id": "notes", "name_map_revision": try Artifacts.nameMapRevision(meeting.speakerNames["parent"]!),
            "covered_segment_ids": segments.map { $0["id"] as! String }, "overview": [["text": "Meeting notes", "segment_ids": ["unknown-1"]]],
            "discussion_points": [], "decisions": [], "action_items": [], "open_questions": []],
            path: "revisions/parent/summaries/notes.json", store: store, meeting: meeting)
        try body(store, &meeting)
    }

    private func write(_ object: [String: Any], path: String, store: MeetingStore, meeting: Meeting) throws {
        let url = try store.artifactURL(meetingID: meeting.id, relativePath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }

    private func bytes(_ path: String, store: MeetingStore, meeting: Meeting) throws -> Data {
        try Data(contentsOf: store.artifactURL(meetingID: meeting.id, relativePath: path))
    }

    private func object(_ path: String, store: MeetingStore, meeting: Meeting) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: bytes(path, store: store, meeting: meeting)) as! [String: Any]
    }

    private func assign(_ store: MeetingStore, _ meeting: Meeting, ids: [String] = ["unknown-1"], speaker: String = "remote") throws -> Meeting {
        try SpeakerCorrections.assign(store: store, meetingID: meeting.id, expectedRevisionID: meeting.activeRevisionID!,
                                      segmentIDs: ids, speakerID: speaker)
    }

    func testImmutableCorrectionPreservesAllUneditedJSONAndSourceBytes() throws {
        try fixture { store, meeting in
            meeting.processingRunID = "stale-run"
            meeting.pendingRevisionID = "stale-revision"
            meeting.pendingSummaryID = "stale-summary"
            meeting.pendingBaseRevisionID = "parent"
            meeting.pendingBaseSummaryID = "notes"
            meeting.processingNameMapRevision = "stale-name-map"
            try store.save(meeting)
            let paths = ["revisions/parent/transcript.json", "revisions/parent/provenance.json", "revisions/parent/summaries/notes.json"]
            let before = try paths.map { try bytes($0, store: store, meeting: meeting) }
            let corrected = try assign(store, meeting, ids: ["unknown-2", "unknown-1"])
            XCTAssertNotEqual(corrected.activeRevisionID, "parent")
            XCTAssertNil(corrected.activeSummaryID)
            XCTAssertNil(corrected.processingRunID)
            XCTAssertNil(corrected.pendingRevisionID)
            XCTAssertNil(corrected.pendingSummaryID)
            XCTAssertNil(corrected.pendingBaseRevisionID)
            XCTAssertNil(corrected.pendingBaseSummaryID)
            XCTAssertNil(corrected.processingNameMapRevision)
            XCTAssertEqual(corrected.processingStatus, "transcript_ready")
            XCTAssertTrue(corrected.processingError!.contains("Regenerate notes"))
            XCTAssertEqual(corrected.speakerNames[corrected.activeRevisionID!], meeting.speakerNames["parent"])
            XCTAssertEqual(corrected, try store.load(id: meeting.id))
            XCTAssertEqual(before, try paths.map { try bytes($0, store: store, meeting: meeting) })
            let revision = corrected.activeRevisionID!
            var actual = try object("revisions/\(revision)/transcript.json", store: store, meeting: meeting)
            var expected = try object(paths[0], store: store, meeting: meeting)
            let originalSegments = expected["segments"] as! [[String: Any]]
            var newSegments = originalSegments
            for index in [1, 4] {
                newSegments[index]["speaker_id"] = "remote"
                newSegments[index]["attribution_reason"] = "manual_assignment"
            }
            expected["segments"] = newSegments
            actual["run_id"] = expected["run_id"]
            actual["revision_id"] = expected["revision_id"]
            XCTAssertEqual(actual as NSDictionary, expected as NSDictionary)
            var actualProvenance = try object("revisions/\(revision)/provenance.json", store: store, meeting: meeting)
            let expectedProvenance = try object(paths[1], store: store, meeting: meeting)
            XCTAssertNotEqual(actualProvenance["input_fingerprint"] as? String, "original-input")
            actualProvenance.removeValue(forKey: "speaker_corrections")
            for key in ["run_id", "revision_id", "input_fingerprint"] { actualProvenance[key] = expectedProvenance[key] }
            XCTAssertEqual(actualProvenance as NSDictionary, expectedProvenance as NSDictionary)
            let metadata = try XCTUnwrap(SpeakerCorrections.correction(store: store, meeting: corrected))
            XCTAssertEqual(metadata.parent_revision_id, "parent")
            XCTAssertEqual(metadata.parent_summary_id, "notes")
            XCTAssertEqual(metadata.segment_ids, ["unknown-1", "unknown-2"])
        }
    }

    func testSelectionAndTargetGuardsLeaveMeetingAndRevisionsUnchanged() throws {
        try fixture { store, meeting in
            let before = try bytes("meeting.json", store: store, meeting: meeting)
            for ids in [[], ["unknown-1", "unknown-1"], ["missing"], ["local-line"], ["known"], ["overlap"], ["unknown-1", "known"], ["../bad"]] {
                XCTAssertThrowsError(try assign(store, meeting, ids: ids))
            }
            for target in ["local", "missing", "../bad"] {
                XCTAssertThrowsError(try assign(store, meeting, speaker: target))
            }
            XCTAssertThrowsError(try SpeakerCorrections.assign(store: store, meetingID: meeting.id, expectedRevisionID: "stale",
                                                              segmentIDs: ["unknown-1"], speakerID: "remote"))
            XCTAssertEqual(before, try bytes("meeting.json", store: store, meeting: meeting))
            let directory = try store.artifactURL(meetingID: meeting.id, relativePath: "revisions")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["parent"])
        }
    }

    func testCaptureAndAllBusyProcessingStatesRejectCorrectionAndUndo() throws {
        try fixture { store, meeting in
            let child = try assign(store, meeting)
            for state in [CaptureState.starting, .recording, .paused, .finalizing] {
                var busy = child
                busy.captureState = state
                try store.save(busy)
                XCTAssertThrowsError(try assign(store, busy, ids: ["unknown-2"]))
                XCTAssertThrowsError(try SpeakerCorrections.undo(store: store, meetingID: meeting.id, expectedRevisionID: child.activeRevisionID!))
            }
            for status in ["running", "processing", "cancelling", "queued", "deferred", "paused"] {
                var busy = child
                busy.processingStatus = status
                try store.save(busy)
                XCTAssertThrowsError(try assign(store, busy, ids: ["unknown-2"]))
                XCTAssertThrowsError(try SpeakerCorrections.undo(store: store, meetingID: meeting.id, expectedRevisionID: child.activeRevisionID!))
                XCTAssertThrowsError(try SpeakerCorrections.correction(store: store, meeting: busy))
                XCTAssertEqual(busy, try store.load(id: meeting.id))
            }
        }
    }

    func testExclusiveLockBlocksReadCorrectionApplyAndUndo() throws {
        try fixture { store, meeting in
            let child = try assign(store, meeting)
            let lock = try store.artifactURL(meetingID: meeting.id, relativePath: ".processing.lock")
            let descriptor = open(lock.path, O_RDWR)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            defer { close(descriptor) }
            XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
            defer { flock(descriptor, LOCK_UN) }
            XCTAssertThrowsError(try assign(store, child, ids: ["unknown-2"]))
            XCTAssertThrowsError(try SpeakerCorrections.correction(store: store, meeting: child))
            XCTAssertThrowsError(try SpeakerCorrections.undo(store: store, meetingID: meeting.id, expectedRevisionID: child.activeRevisionID!))
            XCTAssertEqual(child, try store.load(id: meeting.id))
        }
    }

    func testUndoAfterReloadRestoresValidatedParentAndNotesButKeepsCurrentNames() throws {
        try fixture { store, meeting in
            let child = try assign(store, meeting)
            var renamed = child
            renamed.speakerNames[child.activeRevisionID!] = ["local": "Current me", "remote": "Current remote"]
            try store.save(renamed)
            let restarted = MeetingStore(rootURL: store.rootURL)
            let loaded = try restarted.load(id: meeting.id)
            XCTAssertNotNil(try SpeakerCorrections.correction(store: restarted, meeting: loaded))
            let restored = try SpeakerCorrections.undo(store: restarted, meetingID: meeting.id, expectedRevisionID: child.activeRevisionID!)
            XCTAssertEqual(restored.activeRevisionID, "parent")
            XCTAssertEqual(restored.activeSummaryID, "notes")
            XCTAssertEqual(restored.processingStatus, "completed")
            XCTAssertEqual(restored.speakerNames["parent"], renamed.speakerNames[child.activeRevisionID!])
            XCTAssertNil(try SpeakerCorrections.correction(store: restarted, meeting: restored))
            let parent = try Artifacts.loadRevision(store: restarted, meeting: restored, revision: "parent")
            XCTAssertNil(parent.segments[1].speaker_id)
            let summary = try Artifacts.read(MeetingSummary.self, store: restarted, meetingID: meeting.id, path: "revisions/parent/summaries/notes.json")
            XCTAssertNotEqual(summary.name_map_revision, try Artifacts.nameMapRevision(restored.speakerNames["parent"]!))
            _ = try Artifacts.loadRevision(store: restarted, meeting: restored, revision: child.activeRevisionID!)
            XCTAssertThrowsError(try SpeakerCorrections.undo(store: restarted, meetingID: meeting.id, expectedRevisionID: child.activeRevisionID!))
        }
    }

    func testRepeatedCorrectionsPreserveHistoryAndUndoOneRevisionAtATime() throws {
        try fixture { store, meeting in
            let first = try assign(store, meeting)
            let firstProvenance = try object("revisions/\(first.activeRevisionID!)/provenance.json", store: store, meeting: meeting)
            let second = try assign(store, first, ids: ["unknown-2"])
            let secondProvenance = try object("revisions/\(second.activeRevisionID!)/provenance.json", store: store, meeting: meeting)
            let history = secondProvenance["speaker_corrections"] as! [[String: Any]]
            XCTAssertEqual(history.count, 2)
            XCTAssertEqual(history[0] as NSDictionary, (firstProvenance["speaker_corrections"] as! [[String: Any]])[0] as NSDictionary)
            XCTAssertThrowsError(try SpeakerCorrections.undo(store: store, meetingID: meeting.id, expectedRevisionID: first.activeRevisionID!))
            let firstAgain = try SpeakerCorrections.undo(store: store, meetingID: meeting.id, expectedRevisionID: second.activeRevisionID!)
            XCTAssertEqual(firstAgain.activeRevisionID, first.activeRevisionID)
            XCTAssertNil(firstAgain.activeSummaryID)
            XCTAssertEqual(firstAgain.processingStatus, "transcript_ready")
            XCTAssertNotNil(try SpeakerCorrections.correction(store: store, meeting: firstAgain))
            let original = try SpeakerCorrections.undo(store: store, meetingID: meeting.id, expectedRevisionID: first.activeRevisionID!)
            XCTAssertEqual(original.activeRevisionID, "parent")
            XCTAssertEqual(original.activeSummaryID, "notes")
        }
    }

    func testChangedParentOrChildAndInvalidParentSummaryPreventUndo() throws {
        for kind in ["parent-transcript", "parent-provenance", "child-transcript", "summary"] {
            try fixture { store, meeting in
                let child = try assign(store, meeting)
                let revision = child.activeRevisionID!
                let path: String
                switch kind {
                case "parent-transcript": path = "revisions/parent/transcript.json"
                case "parent-provenance": path = "revisions/parent/provenance.json"
                case "child-transcript": path = "revisions/\(revision)/transcript.json"
                default: path = "revisions/parent/summaries/notes.json"
                }
                var altered = try object(path, store: store, meeting: meeting)
                if kind == "summary" { altered["revision_id"] = "wrong" }
                else { altered["future_field"] = "changed" }
                try write(altered, path: path, store: store, meeting: meeting)
                XCTAssertThrowsError(try SpeakerCorrections.undo(store: store, meetingID: meeting.id, expectedRevisionID: revision), kind)
                XCTAssertEqual(child, try store.load(id: meeting.id))
            }
        }
    }

    func testInvalidParentAndStagingFailureCannotPublishCorrection() throws {
        for failure in ["provenance", "summary", "staging"] {
            try fixture { store, meeting in
                if failure == "staging" {
                    try Data("not a directory".utf8).write(to: store.artifactURL(meetingID: meeting.id, relativePath: "work"))
                } else {
                    let path = failure == "provenance" ? "revisions/parent/provenance.json" : "revisions/parent/summaries/notes.json"
                    var raw = try object(path, store: store, meeting: meeting)
                    raw["meeting_id"] = "wrong"
                    try write(raw, path: path, store: store, meeting: meeting)
                }
                XCTAssertThrowsError(try assign(store, meeting))
                XCTAssertEqual(meeting, try store.load(id: meeting.id))
                let directory = try store.artifactURL(meetingID: meeting.id, relativePath: "revisions")
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["parent"])
            }
        }
    }

    func testCorrectedArtifactSupportsActualSummaryOnlyWorkerContract() throws {
        try fixture { store, meeting in
            let child = try assign(store, meeting)
            let revision = child.activeRevisionID!
            let transcriptPath = "revisions/\(revision)/transcript.json"
            let sourceBytes = try bytes(transcriptPath, store: store, meeting: meeting)
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let python = repo.appendingPathComponent("worker/.venv/bin/python")
            guard FileManager.default.isExecutableFile(atPath: python.path) else { throw XCTSkip("Local worker Python environment is unavailable.") }
            let script = """
            import argparse, contextlib, io, json, pathlib, sys
            from unittest.mock import patch
            from afterword_worker.artifacts import NOTE_FIELDS, digest
            from afterword_worker.pipeline import process
            from afterword_worker.protocol import Control
            root, revision = pathlib.Path(sys.argv[1]), sys.argv[2]
            meeting = json.loads((root / 'meeting.json').read_text())
            names = meeting['speaker_names'][revision]
            (root / 'fixture-model').write_bytes(b'fixture')
            runtime = {'schema_version': 1, 'python': sys.executable,
                       'llama_completion': sys.executable, 'llama_tokenize': sys.executable,
                       'summary_model': str(root / 'fixture-model')}
            (root / 'runtime.json').write_text(json.dumps(runtime))
            (root / 'names.json').write_text(json.dumps({'schema_version': 1, 'speaker_names': names, 'name_map_revision': digest(names)}))
            args = argparse.Namespace(meeting=str(root), runtime=str(root / 'runtime.json'),
                run_id='regenerate-run', revision_id=revision, summary_id='regenerated',
                summary_only=True, prepared=None, names='names.json')
            def notes(engine, transcript, name_map, **options):
                assert name_map == names
                evidence = next(segment for segment in transcript['segments'] if segment['id'] == 'unknown-1')
                assert evidence['speaker_id'] == 'remote'
                assert evidence['attribution_reason'] == 'manual_assignment'
                result = {field: [] for field in (*NOTE_FIELDS, 'action_items')}
                result['overview'] = [{'text': 'Regenerated notes', 'segment_ids': ['unknown-1']}]
                result['action_items'] = [{'text': evidence['text'], 'segment_ids': ['unknown-1'],
                    'owner_speaker_id': 'remote', 'owner_evidence_segment_ids': ['unknown-1'],
                    'due_date': None, 'due_date_evidence_segment_ids': []}]
                return result
            with contextlib.redirect_stdout(io.StringIO()), patch('afterword_worker.pipeline.summarize', side_effect=notes), \\
                 patch('afterword_worker.pipeline.transcribe') as asr, patch('afterword_worker.pipeline.diarize') as diarization:
                process(args, Control(args.run_id, watch_stdin=False))
                asr.assert_not_called()
                diarization.assert_not_called()
            """
            let process = Process()
            process.executableURL = python
            process.currentDirectoryURL = repo.appendingPathComponent("worker")
            process.arguments = ["-c", script, try store.meetingURL(id: meeting.id).path, revision]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let result = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, String(decoding: result, as: UTF8.self))
            let transcript = try Artifacts.loadRevision(store: store, meeting: child, revision: revision)
            let summary = try Artifacts.read(MeetingSummary.self, store: store, meetingID: meeting.id,
                                             path: "revisions/\(revision)/summaries/regenerated.json")
            try Artifacts.validate(summary, transcript: transcript, summaryID: "regenerated", runID: "regenerate-run")
            XCTAssertEqual(summary.action_items.first?.owner_speaker_id, "remote")
            XCTAssertEqual(sourceBytes, try bytes(transcriptPath, store: store, meeting: meeting))
            XCTAssertEqual(child, try store.load(id: meeting.id))
        }
    }
}
