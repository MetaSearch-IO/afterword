import AVFoundation
import AfterwordCore
import XCTest
@testable import AfterwordApp

final class ProcessingControllerTests: XCTestCase {
    @MainActor
    func testRemovedAudioBlocksFullProcessingButAllowsNotesFromSavedTranscript() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("afterword-processing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(rootURL: directory.appendingPathComponent("meetings"))
        var meeting = try store.create(title: "Audio removed")
        meeting.captureState = .stopped
        meeting.activeRevisionID = "revision"
        meeting.audioRemovedAt = "2026-10-16T00:00:00Z"
        try store.save(meeting)
        let processor = ProcessingController(store: store)
        XCTAssertFalse(processor.canProcess(meeting))
        XCTAssertTrue(processor.canProcess(meeting, summaryOnly: true))
        processor.start(meeting)
        XCTAssertEqual(try store.load(id: meeting.id).processingStatus, "idle")
        meeting.audioRemovedAt = nil
        meeting.audioRemovalStartedAt = "2026-10-16T00:00:00Z"
        XCTAssertFalse(processor.canProcess(meeting, summaryOnly: true))
    }

    @MainActor
    func testFastTranscriptPublicationSurvivesImmediateSummaryFailure() async throws {
        try await runFixture(terminal: "failure")
    }

    @MainActor
    func testNonemptyTranscriptCannotCompleteWithoutSummary() async throws {
        try await runFixture(terminal: "missing-summary")
    }

    @MainActor
    func testExitZeroWithoutTerminalCannotComplete() async throws {
        try await runFixture(terminal: "missing-terminal")
    }

    @MainActor
    func testSelectedChineseLanguageReachesWorkerWithoutReplacingAcceptedTranscriptOnPreferenceChange() async throws {
        try await runFixture(terminal: "failure", language: "zh")
    }

    @MainActor
    func testProcessingStatusUpdatesKeepRenamedMeetingTitle() async throws {
        try await runFixture(terminal: "failure", renameDuringProcessing: true)
    }

    @MainActor
    func testEarlyTranscriptSurvivesSpeakerLabelingFailure() async throws {
        try await runFixture(terminal: "labeling-failure", earlyTranscript: true)
    }

    @MainActor
    func testRemoteOptInUsesClientProtocolWithoutLocalModels() async throws {
        try await runFixture(terminal: "failure", deferredModelsMissing: true, remote: true)
    }

    @MainActor
    func testRemoteIsDefaultUnlessThisMacWasExplicitlySelected() {
        let previous = UserDefaults.standard.object(forKey: RemoteProcessing.preferenceKey)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: RemoteProcessing.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: RemoteProcessing.preferenceKey) }
        }
        UserDefaults.standard.removeObject(forKey: RemoteProcessing.preferenceKey)
        XCTAssertTrue(RemoteProcessing.enabled)
        UserDefaults.standard.set(false, forKey: RemoteProcessing.preferenceKey)
        XCTAssertFalse(RemoteProcessing.enabled)
    }

    @MainActor
    func testUnconfirmedRemoteCleanupDisablesFutureRemoteProcessing() async throws {
        UserDefaults.standard.set(true, forKey: RemoteProcessing.preferenceKey)
        defer { UserDefaults.standard.removeObject(forKey: RemoteProcessing.preferenceKey) }
        try await runFixture(terminal: "cleanup-failure", remote: true)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: RemoteProcessing.preferenceKey))
    }

    @MainActor
    func testUncertainRemoteSubmissionDisablesFurtherRemoteProcessing() async throws {
        UserDefaults.standard.set(true, forKey: RemoteProcessing.preferenceKey)
        defer { UserDefaults.standard.removeObject(forKey: RemoteProcessing.preferenceKey) }
        try await runFixture(terminal: "submission-unknown", remote: true)
        XCTAssertFalse(RemoteProcessing.enabled)
    }

    @MainActor
    func testLiveRemoteSyntheticSilencePublishesValidatedTranscript() async throws {
        guard ProcessInfo.processInfo.environment["AFTERWORD_REMOTE_LIVE_TEST"] == "1" else {
            throw XCTSkip("Enable only for a synthetic run against the live Hyperion service.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("afterword-remote-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(rootURL: directory.appendingPathComponent("meetings"))
        var meeting = try store.create(title: "Synthetic silence")
        meeting.captureState = .stopped
        meeting.intervals = [CaptureInterval(generation: 0, startUS: 0, endUS: 2_000_000)]
        try store.save(meeting)
        let partial = try store.beginChunk(meetingID: meeting.id, chunkID: "synthetic")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000)!
        buffer.frameLength = 32_000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 32_000)
        do {
            let audio = try AVAudioFile(forWriting: partial.appendingPathComponent("audio.caf"), settings: format.settings)
            try audio.write(from: buffer)
        }
        meeting = try store.commitChunk(meetingID: meeting.id, descriptor: ChunkDescriptor(
            id: "synthetic", source: .microphone, generation: 0, startUS: 0, frameCount: 32_000,
            sampleRate: 16_000, channelCount: 1, relativePath: "audio/synthetic/audio.caf"))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let client = root.appendingPathComponent("worker/afterword_remote_client.py")
        let processor = ProcessingController(store: store, remoteEnabled: { true }, remoteClientURL: client)
        processor.start(meeting)
        let deadline = Date().addingTimeInterval(120)
        while processor.isBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(processor.isBusy)
        let accepted = try store.load(id: meeting.id)
        XCTAssertEqual(accepted.processingStatus, "completed", accepted.processingError ?? "")
        XCTAssertNil(accepted.activeSummaryID)
        XCTAssertTrue(try processor.loadTranscript(accepted).segments.isEmpty)
    }

    @MainActor
    func testEarlyTranscriptSurvivesSpeakerLabelingCancellation() async throws {
        try await runFixture(terminal: "labeling-cancelled", earlyTranscript: true)
    }

    @MainActor
    func testLabeledRevisionReplacesEarlyTranscriptWithoutRewritingIt() async throws {
        try await runFixture(terminal: "final-after-preview", earlyTranscript: true)
    }

    @MainActor
    func testMissingLaterStageModelsDoNotBlockEarlyTranscript() async throws {
        try await runFixture(terminal: "labeling-failure", earlyTranscript: true, deferredModelsMissing: true)
    }

    @MainActor
    private func runFixture(terminal: String, language: String? = nil, renameDuringProcessing: Bool = false,
                            earlyTranscript: Bool = false, deferredModelsMissing: Bool = false,
                            remote: Bool = false) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("afterword-processing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(rootURL: directory.appendingPathComponent("meetings"))
        var meeting = try store.create(title: "Publication")
        meeting.captureState = .stopped
        meeting.asrLanguage = language
        meeting.intervals = [CaptureInterval(generation: 0, startUS: 0, endUS: 1_000_000)]
        try store.save(meeting)
        let partial = try store.beginChunk(meetingID: meeting.id, chunkID: "audio")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        buffer.floatChannelData![0].initialize(repeating: 0.25, count: 16_000)
        do {
            let file = try AVAudioFile(forWriting: partial.appendingPathComponent("audio.caf"), settings: format.settings)
            try file.write(from: buffer)
        }
        let source: AudioSource = earlyTranscript ? .system : .microphone
        meeting = try store.commitChunk(meetingID: meeting.id, descriptor: ChunkDescriptor(id: "audio", source: source,
                 generation: 0, startUS: 0, frameCount: 16_000, sampleRate: 16_000, channelCount: 1, relativePath: "audio/audio/audio.caf"))
        let module = directory.appendingPathComponent("afterword_worker")
        try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        let script = """
        import json, os, pathlib, sys
        assert os.environ.get('AFTERWORD_REMOTE') == \(remote ? "'\(RemoteProcessing.endpoint)'" : "None")
        assert pathlib.Path(__file__).name == '\(remote ? "remote_client.py" : "__main__.py")'
        def arg(name): return sys.argv[sys.argv.index(name)+1]
        assert arg('--language') == '\(language ?? "auto")'
        assert '--transcript-first' in sys.argv
        root = pathlib.Path(arg('--meeting'))
        run, final_revision = arg('--run-id'), arg('--revision-id')
        early = \(earlyTranscript ? "True" : "False")
        revision = run if early else final_revision
        def event(kind, **fields):
            print(json.dumps(dict(protocol_version=1,run_id=run,type=kind,**fields)),flush=True)
        event('started')
        folder = root / 'revisions' / revision
        folder.mkdir(parents=True)
        transcript = dict(schema_version=1,run_id=run,meeting_id=root.name,revision_id=revision,
            speakers=[] if early else [dict(id='local',source='microphone',label='You')],warnings=[],
            coverage=[dict(source='\(source.rawValue)',start_us=0,end_us=1000000)],
            segments=[dict(id='s1',source='\(source.rawValue)',start_us=0,end_us=1000000,text='Hello',
                speaker_id=None if early else 'local',attribution_reason='speaker_labeling_pending' if early else 'microphone',overlap=False)])
        (folder/'transcript.json').write_text(json.dumps(transcript))
        provenance=dict(schema_version=1,run_id=run,meeting_id=root.name,revision_id=revision,
            input_fingerprint='fixture',committed_audio_fingerprint='\(Artifacts.audioFingerprint(meeting.chunks))',preparation_version=1,alignment_version=1)
        (folder/'provenance.json').write_text(json.dumps(provenance))
        event('stage_completed',stage='transcript' if early else 'alignment',revision_id=revision,
            transcript_path=f'revisions/{revision}/transcript.json',provenance_path=f'revisions/{revision}/provenance.json')
        if early:
            event('stage_started',stage='diarization')
            if '\(terminal)' == 'labeling-failure':
                event('failed',stage='diarization',code='fixture',message='Deliberate labeling failure')
                sys.exit(1)
            if '\(terminal)' == 'labeling-cancelled':
                event('cancelled',stage='diarization')
                sys.exit(2)
            preview = (folder/'transcript.json').read_bytes()
            revision = final_revision
            folder = root / 'revisions' / revision
            folder.mkdir()
            transcript['revision_id'] = revision
            transcript['speakers'] = [dict(id='remote-001',source='system',label='Speaker 1')]
            transcript['segments'][0].update(speaker_id='remote-001',attribution_reason='single_exclusive_turn')
            provenance['revision_id'] = revision
            (folder/'transcript.json').write_text(json.dumps(transcript))
            (folder/'provenance.json').write_text(json.dumps(provenance))
            event('stage_completed',stage='alignment',revision_id=revision,
                transcript_path=f'revisions/{revision}/transcript.json',provenance_path=f'revisions/{revision}/provenance.json')
            assert (root/'revisions'/run/'transcript.json').read_bytes() == preview
        if '\(terminal)' in ('failure', 'final-after-preview'):
            event('failed',stage='summary',code='fixture',message='Deliberate summary failure')
            sys.exit(1)
        if '\(terminal)' == 'cleanup-failure':
            event('failed',stage='summary',code='remote_cleanup',message='Delete failed')
            sys.exit(1)
        if '\(terminal)' == 'submission-unknown':
            event('failed',stage='summary',code='remote_submission_unknown',message='Upload response lost')
            sys.exit(1)
        if '\(terminal)' == 'missing-summary':
            event('completed',revision_id=revision,transcript_path=f'revisions/{revision}/transcript.json',summary_id=None,summary_path=None)
        sys.exit(0)
        """
        try Data(script.utf8).write(to: module.appendingPathComponent("__main__.py"))
        let remoteClientURL = directory.appendingPathComponent("remote_client.py")
        if remote { try Data(script.utf8).write(to: remoteClientURL) }
        let runtimeURL = directory.appendingPathComponent("runtime.json")
        var runtime: [String: Any] = ["schema_version": 1, "python": "/usr/bin/python3", "worker_root": directory.path,
            "whisper_cli": "/usr/bin/python3", "vad_cli": "/usr/bin/python3", "llama_completion": "/usr/bin/python3", "llama_tokenize": "/usr/bin/python3",
            "asr_model": runtimeURL.path, "summary_model": runtimeURL.path, "vad_model": runtimeURL.path]
        if deferredModelsMissing {
            runtime["diarization_model"] = directory.appendingPathComponent("missing-community-1").path
            runtime["summary_model"] = directory.appendingPathComponent("missing-summary.gguf").path
            runtime["llama_completion"] = directory.appendingPathComponent("missing-completion").path
            runtime["llama_tokenize"] = directory.appendingPathComponent("missing-tokenizer").path
        }
        try JSONSerialization.data(withJSONObject: runtime).write(to: runtimeURL)
        let processor = ProcessingController(store: store, runtimeURL: runtimeURL,
                                             remoteEnabled: { remote }, remoteAvailability: { .ready },
                                             remoteClientURL: remoteClientURL)
        var didRename = false
        var renameError: Error?
        processor.changed = { [weak processor] in
            guard renameDuringProcessing, !didRename, processor?.isBusy == true else { return }
            didRename = true
            do { _ = try store.rename(id: meeting.id, title: "Renamed during processing") }
            catch { renameError = error }
        }
        processor.start(meeting)
        let deadline = Date().addingTimeInterval(10)
        while processor.isBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(processor.isBusy)
        let accepted = try store.load(id: meeting.id)
        let savedRequest = try JSONDecoder().decode(ProcessingRequest.self, from: Data(contentsOf:
            store.artifactURL(meetingID: meeting.id, relativePath: "work/\(accepted.processingRunID!)/request.json")))
        XCTAssertEqual(savedRequest.remote, remote)
        XCTAssertNotNil(accepted.activeRevisionID)
        XCTAssertNil(accepted.activeSummaryID)
        XCTAssertEqual(accepted.processingStatus, terminal == "labeling-cancelled" ? "cancelled" : "failed")
        XCTAssertNil(renameError)
        if renameDuringProcessing { XCTAssertEqual(accepted.title, "Renamed during processing") }
        XCTAssertEqual(try processor.loadTranscript(accepted).segments.first?.text, "Hello")
        if earlyTranscript {
            let pending = terminal != "final-after-preview"
            XCTAssertEqual(try processor.loadTranscript(accepted).speakerLabelsPending, pending)
            XCTAssertEqual(accepted.activeRevisionID, pending ? accepted.processingRunID : accepted.pendingRevisionID)
            let preview = try Artifacts.loadRevision(store: store, meeting: accepted, revision: accepted.processingRunID!)
            XCTAssertTrue(preview.speakerLabelsPending)
            XCTAssertNil(preview.segments.first?.speaker_id)
        }
        try processor.setTranscriptionLanguage("en", meeting: accepted)
        let changed = try store.load(id: meeting.id)
        XCTAssertEqual(changed.asrLanguage, "en")
        XCTAssertEqual(changed.activeRevisionID, accepted.activeRevisionID)
        XCTAssertEqual(changed.activeSummaryID, accepted.activeSummaryID)
        XCTAssertFalse(processor.isBusy)
    }
}
