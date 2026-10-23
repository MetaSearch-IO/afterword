import AVFoundation
import AfterwordCore
import Darwin
import XCTest
@testable import AfterwordApp

final class ProcessingQueueTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let store: MeetingStore
        let runtime: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("afterword-queue-\(UUID().uuidString)")
            store = MeetingStore(rootURL: directory.appendingPathComponent("meetings"))
            runtime = directory.appendingPathComponent("runtime.json")
            let module = directory.appendingPathComponent("afterword_worker")
            try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
            let script = """
            import json, os, pathlib, signal, subprocess, sys
            def arg(name): return sys.argv[sys.argv.index(name)+1]
            root = pathlib.Path(arg('--meeting'))
            run, revision = arg('--run-id'), arg('--revision-id')
            config = json.loads((root/'fixture.json').read_text())
            def log(kind, **fields):
                with (root.parents[1]/'calls.jsonl').open('a') as out:
                    out.write(json.dumps(dict(kind=kind,meeting=root.name,run=run,**fields))+'\\n')
            def event(kind, **fields):
                print(json.dumps(dict(protocol_version=1,run_id=run,type=kind,**fields)),flush=True)
            event('started')
            log('start', summary_only='--summary-only' in sys.argv)
            if config.get('publish'):
                preview = config['publish'] == 'preview'
                target = run if preview else revision
                folder = root/'revisions'/target
                folder.mkdir(parents=True)
                transcript = dict(schema_version=1,run_id=run,meeting_id=root.name,revision_id=target,
                    speakers=[] if preview else [dict(id='remote-001',source='system',label='Speaker 1')],warnings=[],
                    coverage=[dict(source='system',start_us=0,end_us=1000000)],
                    segments=[dict(id='s1',source='system',start_us=0,end_us=1000000,text='Fixture speech',
                        speaker_id=None if preview else 'remote-001',
                        attribution_reason='speaker_labeling_pending' if preview else 'single_exclusive_turn',overlap=False)])
                (folder/'transcript.json').write_text(json.dumps(transcript))
                (folder/'provenance.json').write_text(json.dumps(dict(schema_version=1,run_id=run,
                    meeting_id=root.name,revision_id=target,input_fingerprint='fixture',
                    committed_audio_fingerprint=config['fingerprint'],preparation_version=1,alignment_version=1)))
                if config['publish'] == 'complete-race':
                    summary = arg('--summary-id')
                    names = json.loads((root/arg('--names')).read_text())
                    (folder/'summaries').mkdir()
                    (folder/'summaries'/f'{summary}.json').write_text(json.dumps(dict(schema_version=1,run_id=run,
                        meeting_id=root.name,revision_id=target,summary_id=summary,name_map_revision=names['name_map_revision'],
                        covered_segment_ids=['s1'],overview=[dict(text='Fixture note',segment_ids=['s1'])],
                        discussion_points=[],decisions=[],action_items=[],open_questions=[])))
                if config['publish'] not in ('complete-race','final-race'):
                    event('stage_completed',stage='transcript' if preview else 'alignment',revision_id=target,
                        transcript_path=f'revisions/{target}/transcript.json',provenance_path=f'revisions/{target}/provenance.json')
            event('stage_started',stage='summary' if config.get('publish') == 'final' else 'asr')
            if config.get('progress'):
                import time
                assert '--progress-events' in sys.argv
                event('stage_progress',stage='asr',completed=0,total=2,progress_unit='audio_windows',progress_phase='windows')
                deadline = time.monotonic() + 5
                while json.loads((root/'meeting.json').read_text()).get('processing_stage') != 'asr':
                    assert time.monotonic() < deadline
                    time.sleep(.01)
                (root/'manifest-before-progress').write_bytes((root/'meeting.json').read_bytes())
                while not (root/'allow-progress').exists():
                    assert time.monotonic() < deadline
                    time.sleep(.01)
                event('stage_progress',stage='asr',completed=1,total=2,progress_unit='audio_windows',progress_phase='windows')
            if not config.get('wait',True):
                event('failed',stage='asr',code='fixture',message='Deliberate fixture failure')
                sys.exit(1)
            child = subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)'],start_new_session=True,
                stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            (root/'child.json').write_text(json.dumps(dict(pid=child.pid)))
            event('stage_started',stage='asr',process_group_id=child.pid)
            log('waiting')
            sys.stdin.readline()
            if not config.get('leak',False):
                child.terminate()
                child.wait()
                log('child-exited')
                event('stage_started',stage='asr',process_group_id=child.pid,process_group_finished=True)
            event('cancelled',stage='asr')
            sys.exit(2)
            """
            try Data(script.utf8).write(to: module.appendingPathComponent("__main__.py"))
            let value: [String: Any] = ["schema_version": 1, "python": "/usr/bin/python3", "worker_root": directory.path,
                "whisper_cli": "/usr/bin/python3", "vad_cli": "/usr/bin/python3", "llama_completion": "/usr/bin/python3",
                "llama_tokenize": "/usr/bin/python3", "asr_model": runtime.path, "summary_model": runtime.path, "vad_model": runtime.path]
            try JSONSerialization.data(withJSONObject: value).write(to: runtime)
        }

        func meeting(_ title: String, publish: String? = nil, wait: Bool = true, leak: Bool = false) throws -> Meeting {
            var meeting = try store.create(title: title)
            meeting.captureState = .stopped
            meeting.intervals = [CaptureInterval(generation: 0, startUS: 0, endUS: 1_000_000)]
            try store.save(meeting)
            let partial = try store.beginChunk(meetingID: meeting.id, chunkID: "audio")
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
            buffer.frameLength = 16_000
            buffer.floatChannelData![0].initialize(repeating: 0.1, count: 16_000)
            do {
                let audio = try AVAudioFile(forWriting: partial.appendingPathComponent("audio.caf"), settings: format.settings)
                try audio.write(from: buffer)
            }
            meeting = try store.commitChunk(meetingID: meeting.id, descriptor: ChunkDescriptor(id: "audio", source: .system,
                generation: 0, startUS: 0, frameCount: 16_000, sampleRate: 16_000, channelCount: 1, relativePath: "audio/audio/audio.caf"))
            try configure(meeting, publish: publish, wait: wait, leak: leak)
            return meeting
        }

        func configure(_ meeting: Meeting, publish: String? = nil, wait: Bool = true, leak: Bool = false) throws {
            var value: [String: Any] = ["wait": wait, "leak": leak, "fingerprint": Artifacts.audioFingerprint(meeting.chunks)]
            if let publish { value["publish"] = publish }
            try JSONSerialization.data(withJSONObject: value).write(to: store.artifactURL(meetingID: meeting.id, relativePath: "fixture.json"), options: .atomic)
        }

        func calls(_ kind: String = "start") throws -> [[String: Any]] {
            let url = directory.appendingPathComponent("calls.jsonl")
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
                try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
            }.filter { $0["kind"] as? String == kind }
        }

        func child(_ meeting: Meeting) throws -> Int32 {
            let data = try Data(contentsOf: store.artifactURL(meetingID: meeting.id, relativePath: "child.json"))
            return (try JSONSerialization.jsonObject(with: data) as! [String: Int32])["pid"]!
        }
    }

    @MainActor
    private func waitFor(_ condition: () throws -> Bool, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while try !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(try condition())
    }

    @MainActor
    func testQueuedProcessingKeepsItsSelectedDestination() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let meeting = try fixture.meeting("Destination")
        var remoteEnabled = true
        let processor = ProcessingController(store: fixture.store, runtimeURL: fixture.runtime,
                                             remoteEnabled: { remoteEnabled })
        processor.pause()
        processor.start(meeting)
        let queued = try fixture.store.load(id: meeting.id)
        XCTAssertEqual(try ProcessingRequest.load(store: fixture.store, meeting: queued)?.remote, true)
        remoteEnabled = false
        XCTAssertEqual(try ProcessingRequest.load(store: fixture.store, meeting: queued)?.remote, true)
    }

    @MainActor
    func testRecordingWaitsForChildExitAndNewRecordingRunsBeforeDeferredWork() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let old = try fixture.meeting("Old")
        let new = try fixture.meeting("New", wait: false)
        let processor = ProcessingController(store: fixture.store, runtimeURL: fixture.runtime)
        processor.start(old)
        try await waitFor { try fixture.calls("waiting").count == 1 }
        let child = try fixture.child(old)
        let permitted = await processor.reserveRecording()
        XCTAssertTrue(permitted)
        XCTAssertEqual(kill(child, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertFalse(processor.isBusy)
        XCTAssertEqual(processor.queuedCount, 1)
        XCTAssertEqual(try fixture.calls("child-exited").count, 1)
        let secondReservation = await processor.reserveRecording()
        XCTAssertFalse(secondReservation)
        try fixture.configure(old, wait: false)
        processor.releaseRecording(preferred: new)
        try await waitFor { !processor.isBusy && processor.queuedCount == 0 }
        XCTAssertEqual(try fixture.calls().compactMap { $0["meeting"] as? String }, [old.id, new.id, old.id])
        XCTAssertEqual(Set(try fixture.calls().compactMap { $0["run"] as? String }).count, 3)
    }

    @MainActor
    func testPausePersistsAcrossRecoveryAndExplicitCancelNeverRequeues() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let meeting = try fixture.meeting("Paused", publish: "preview")
        let first = ProcessingController(store: fixture.store, runtimeURL: fixture.runtime)
        first.start(meeting)
        try await waitFor { try fixture.calls("waiting").count == 1 }
        first.pause()
        try await waitFor { !first.isBusy }
        XCTAssertTrue(first.isPaused)
        XCTAssertEqual(first.queuedCount, 1)
        var stored = try fixture.store.load(id: meeting.id)
        XCTAssertEqual(stored.processingStatus, "paused")
        XCTAssertTrue(try first.loadTranscript(stored).speakerLabelsPending)
        stored = try ArtifactRecovery.recover(stored, store: fixture.store)
        XCTAssertEqual(stored.processingStatus, "paused")
        let restarted = ProcessingController(store: fixture.store, runtimeURL: fixture.runtime)
        restarted.restoreQueue(from: [stored])
        XCTAssertTrue(restarted.isPaused)
        XCTAssertFalse(restarted.isBusy)
        XCTAssertEqual(restarted.queuedCount, 1)
        try fixture.configure(stored)
        restarted.resume()
        try await waitFor { try fixture.calls("waiting").count == 2 }
        restarted.cancel()
        try await waitFor { !restarted.isBusy }
        XCTAssertEqual(restarted.queuedCount, 0)
        XCTAssertEqual(try fixture.store.load(id: meeting.id).processingStatus, "cancelled")
        let cancelled = try ArtifactRecovery.recover(fixture.store.load(id: meeting.id), store: fixture.store)
        let third = ProcessingController(store: fixture.store, runtimeURL: fixture.runtime)
        third.restoreQueue(from: [cancelled])
        XCTAssertFalse(third.isBusy)
        XCTAssertEqual(third.queuedCount, 0)
    }

    @MainActor
    func testOnlyThisRunsAcceptedFinalTranscriptChangesResumeToNotesOnly() async throws {
        for publish in ["preview", "final"] {
            let fixture = try Fixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let meeting = try fixture.meeting(publish, publish: publish)
            let processor = ProcessingController(store: fixture.store, runtimeURL: fixture.runtime)
            processor.start(meeting)
            try await waitFor { try fixture.calls("waiting").count == 1 }
            let reserved = await processor.reserveRecording()
            XCTAssertTrue(reserved)
            try fixture.configure(meeting, wait: false)
            processor.releaseRecording()
            try await waitFor { !processor.isBusy && processor.queuedCount == 0 }
            XCTAssertEqual(try fixture.calls().last?["summary_only"] as? Bool, publish == "final")

            if publish == "final" {
                let current = try fixture.store.load(id: meeting.id)
                try fixture.configure(current)
                processor.start(current)
                try await waitFor { try fixture.calls("waiting").count == 2 }
                let reserved = await processor.reserveRecording()
                XCTAssertTrue(reserved)
                try fixture.configure(current, wait: false)
                processor.releaseRecording()
                try await waitFor { !processor.isBusy && processor.queuedCount == 0 }
                XCTAssertEqual(try fixture.calls().last?["summary_only"] as? Bool, false)
            }
        }
    }

    @MainActor
    func testStaleQueuedRevisionLanguageAndAudioCannotLaunchOrOverwrite() async throws {
        for mutation in ["revision", "language", "audio"] {
            let fixture = try Fixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let meeting = try fixture.meeting(mutation, wait: false)
            let processor = ProcessingController(store: fixture.store, runtimeURL: fixture.runtime)
            processor.pause()
            processor.start(meeting)
            var changed = try fixture.store.load(id: meeting.id)
            switch mutation {
            case "revision": changed.activeRevisionID = "manual-correction"
            case "language": changed.asrLanguage = "zh"
            default: changed.chunks = []
            }
            try fixture.store.save(changed)
            processor.resume()
            XCTAssertFalse(processor.isBusy)
            XCTAssertEqual(processor.queuedCount, 0)
            XCTAssertEqual(try fixture.calls().count, 0)
            let rejected = try fixture.store.load(id: meeting.id)
            XCTAssertEqual(rejected.activeRevisionID, changed.activeRevisionID)
            XCTAssertEqual(rejected.asrLanguage, changed.asrLanguage)
            XCTAssertEqual(rejected.chunks, changed.chunks)
            XCTAssertEqual(rejected.processingStatus, "failed")
        }
    }

    @MainActor
    func testQuitDefersActiveWorkButDoesNotLaunchNextRequest() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let first = try fixture.meeting("First")
        let second = try fixture.meeting("Second", wait: false)
        let processor = ProcessingController(store: fixture.store, runtimeURL: fixture.runtime)
        processor.start(first)
        try await waitFor { try fixture.calls("waiting").count == 1 }
        processor.start(second)
        let ready = await processor.prepareToQuit()
        XCTAssertTrue(ready)
        XCTAssertEqual(try fixture.calls().count, 1)
        XCTAssertFalse(processor.isBusy)
        XCTAssertEqual(processor.queuedCount, 2)
        XCTAssertEqual(try fixture.store.load(id: first.id).processingStatus, "queued")
        try fixture.configure(first, wait: false)
        let restored = ProcessingController(store: fixture.store, runtimeURL: fixture.runtime)
        let meetings = try fixture.store.list().map { try ArtifactRecovery.recover($0, store: fixture.store) }
        restored.restoreQueue(from: meetings)
        try await waitFor { !restored.isBusy && restored.queuedCount == 0 }
        XCTAssertEqual(try fixture.calls().count, 3)
    }

    @MainActor
    func testMicrophonePermissionFailureReleasesReservationAndRestartsDeferredJob() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let meeting = try fixture.meeting("Permission")
        var asked = 0
        let controller = MeetingController(rootURL: fixture.store.rootURL, runtimeURL: fixture.runtime,
            requestMicrophoneAccess: {
                asked += 1
                XCTAssertEqual(try? fixture.calls("child-exited").count, 1)
                return false
            })
        try await waitFor { !controller.isLoading }
        controller.processing.start(meeting)
        try await waitFor { try fixture.calls("waiting").count == 1 }
        XCTAssertTrue(controller.canRecord)
        try fixture.configure(meeting, wait: false)
        controller.record()
        controller.record()
        try await waitFor { controller.activity == .idle && !controller.processing.isBusy }
        XCTAssertEqual(asked, 1)
        XCTAssertTrue(controller.canRecord)
        XCTAssertEqual(try fixture.calls().count, 2)
        XCTAssertTrue(controller.message?.contains("Microphone access") == true)
    }

    @MainActor
    func testUnconfirmedChildCleanupBlocksRecordingAndDequeueUntilRechecked() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let meeting = try fixture.meeting("Cleanup", leak: true)
        let processor = ProcessingController(store: fixture.store, runtimeURL: fixture.runtime)
        processor.start(meeting)
        try await waitFor { try fixture.calls("waiting").count == 1 }
        let child = try fixture.child(meeting)
        defer { kill(child, SIGKILL) }
        let reserved = await processor.reserveRecording()
        XCTAssertFalse(reserved)
        XCTAssertTrue(processor.cleanupBlocked)
        XCTAssertFalse(processor.canReserveRecording)
        processor.releaseRecording()
        XCTAssertEqual(try fixture.calls().count, 1)
        processor.pause()
        kill(child, SIGTERM)
        try await waitFor { kill(-child, 0) == -1 && errno == ESRCH }
        processor.recheckCleanup()
        XCTAssertFalse(processor.cleanupBlocked)
        XCTAssertFalse(processor.isBusy)
        XCTAssertEqual(processor.queuedCount, 1)
        processor.cancelQueued(meetingID: meeting.id)
        XCTAssertEqual(processor.queuedCount, 0)
    }

    @MainActor
    func testCancellationRecoversAtomicPublicationBeforeReplacingPendingIdentity() async throws {
        for publish in ["complete-race", "final-race"] {
            let fixture = try Fixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let meeting = try fixture.meeting(publish, publish: publish)
            let processor = ProcessingController(store: fixture.store, runtimeURL: fixture.runtime)
            processor.start(meeting)
            try await waitFor { try fixture.calls("waiting").count == 1 }
            XCTAssertNil(try fixture.store.load(id: meeting.id).activeRevisionID)
            let reserved = await processor.reserveRecording()
            XCTAssertTrue(reserved)
            let recovered = try fixture.store.load(id: meeting.id)
            XCTAssertNotNil(recovered.activeRevisionID)
            if publish == "complete-race" {
                XCTAssertNotNil(recovered.activeSummaryID)
                XCTAssertEqual(recovered.processingStatus, "completed")
                XCTAssertEqual(processor.queuedCount, 0)
                XCTAssertNil(recovered.processingRunID)
            } else {
                XCTAssertNil(recovered.activeSummaryID)
                XCTAssertEqual(recovered.pendingRevisionID, recovered.activeRevisionID)
                XCTAssertEqual(processor.queuedCount, 1)
            }
            processor.cancelQueued(meetingID: meeting.id)
            processor.releaseRecording()
        }
    }

    @MainActor
    func testProgressAndNativeLifecycleDoNotRewriteMetadataOrResetElapsedStage() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let meeting = try fixture.meeting("Progress")
        let configURL = try fixture.store.artifactURL(meetingID: meeting.id, relativePath: "fixture.json")
        var config = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as! [String: Any]
        config["progress"] = true
        try JSONSerialization.data(withJSONObject: config).write(to: configURL)
        let processor = ProcessingController(store: fixture.store, runtimeURL: fixture.runtime)
        processor.start(meeting)
        try await waitFor { processor.completedUnits == 0 && processor.stageElapsedSeconds > 0 }
        let elapsedBeforeLifecycle = processor.stageElapsedSeconds
        try Data().write(to: fixture.store.artifactURL(meetingID: meeting.id, relativePath: "allow-progress"))
        try await waitFor { try fixture.calls("waiting").count == 1 }
        XCTAssertEqual(processor.completedUnits, 1)
        XCTAssertEqual(processor.totalUnits, 2)
        XCTAssertEqual(processor.progressUnit, "audio_windows")
        XCTAssertGreaterThanOrEqual(processor.stageElapsedSeconds, elapsedBeforeLifecycle)
        let current = try Data(contentsOf: fixture.store.artifactURL(meetingID: meeting.id, relativePath: "meeting.json"))
        let before = try Data(contentsOf: fixture.store.artifactURL(meetingID: meeting.id, relativePath: "manifest-before-progress"))
        XCTAssertEqual(current, before)
        processor.cancel()
        try await waitFor { !processor.isBusy }
        XCTAssertNil(processor.completedUnits)
    }

    @MainActor
    func testMissingDurableRequestBecomesRetryableInsteadOfStayingBusy() throws {
        for missingIDs in [false, true] {
            let fixture = try Fixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let meeting = try fixture.meeting("Missing request")
            let original = ProcessingController(store: fixture.store, runtimeURL: fixture.runtime)
            original.pause()
            original.start(meeting)
            var queued = try fixture.store.load(id: meeting.id)
            if missingIDs {
                ArtifactRecovery.clearPending(&queued)
                try fixture.store.save(queued)
            } else {
                let request = try fixture.store.artifactURL(meetingID: meeting.id, relativePath: "work/\(queued.processingRunID!)/request.json")
                try FileManager.default.removeItem(at: request)
            }
            let restored = ProcessingController(store: fixture.store, runtimeURL: fixture.runtime)
            restored.restoreQueue(from: [queued])
            XCTAssertFalse(restored.isMeetingBusy(meeting.id))
            XCTAssertEqual(restored.queuedCount, 0)
            let failed = try fixture.store.load(id: meeting.id)
            XCTAssertEqual(failed.processingStatus, "failed")
            XCTAssertNil(failed.processingRunID)
            XCTAssertEqual(failed.activeRevisionID, meeting.activeRevisionID)
        }
    }

    @MainActor
    func testExplicitCancelDuringUnconfirmedCleanupCannotRequeueAfterRecheck() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let meeting = try fixture.meeting("Cancel blocked cleanup", leak: true)
        let processor = ProcessingController(store: fixture.store, runtimeURL: fixture.runtime)
        processor.start(meeting)
        try await waitFor { try fixture.calls("waiting").count == 1 }
        let child = try fixture.child(meeting)
        defer { kill(child, SIGKILL) }
        let reserved = await processor.reserveRecording()
        XCTAssertFalse(reserved)
        processor.cancel()
        kill(child, SIGTERM)
        try await waitFor { kill(-child, 0) == -1 && errno == ESRCH }
        processor.recheckCleanup()
        processor.releaseRecording()
        XCTAssertFalse(processor.cleanupBlocked)
        XCTAssertFalse(processor.isBusy)
        XCTAssertEqual(processor.queuedCount, 0)
        XCTAssertEqual(try fixture.calls().count, 1)
        XCTAssertEqual(try fixture.store.load(id: meeting.id).processingStatus, "cancelled")
    }
}
