import AfterwordCore
import Combine
import Foundation

struct RuntimeConfiguration: Decodable, Sendable {
    let schema_version: Int
    let python: String
    let worker_root: String
    let whisper_cli: String
    let vad_cli: String
    let llama_completion: String
    let llama_tokenize: String
    let asr_model: String
    let summary_model: String
    let vad_model: String

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Afterword/runtime.json")
    }

    static func load(from url: URL = Self.url, summaryOnly: Bool) throws -> RuntimeConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CaptureFailure(message: "Local model setup is missing: \(url.path). Run make model-setup in the development folder, then retry.")
        }
        let config = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try Artifacts.require(config.schema_version == 1, "Unsupported runtime configuration version.")
        let executables = [config.python] + (summaryOnly
            ? [config.llama_completion, config.llama_tokenize] : [config.whisper_cli, config.vad_cli])
        for path in executables {
            try Artifacts.require(path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path), "Missing local executable: \(path)")
        }
        let assets = [config.worker_root] + (summaryOnly ? [config.summary_model] : [config.asr_model, config.vad_model])
        for path in assets {
            try Artifacts.require(path.hasPrefix("/") && FileManager.default.fileExists(atPath: path), "Missing local model or worker: \(path)")
        }
        return config
    }
}

struct ProcessingRequest: Codable {
    var schemaVersion = 1
    let meetingID: String
    let run: String
    let revision: String
    let summary: String
    let summaryOnly: Bool
    let baseRevision: String?
    let baseSummary: String?
    let audioFingerprint: String
    let language: String
    let nameMapRevision: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", meetingID = "meeting_id", run = "run_id"
        case revision = "revision_id", summary = "summary_id", summaryOnly = "summary_only"
        case baseRevision = "base_revision_id", baseSummary = "base_summary_id"
        case audioFingerprint = "audio_fingerprint", language, nameMapRevision = "name_map_revision"
    }

    static func load(store: MeetingStore, meeting: Meeting) throws -> Self? {
        let queuedIntent = ["queued", "paused"].contains(meeting.processingStatus)
        guard let run = meeting.processingRunID else {
            try Artifacts.require(!queuedIntent, "Queued processing has no saved request. Request processing again.")
            return nil
        }
        let url = try store.artifactURL(meetingID: meeting.id, relativePath: "work/\(run)/request.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            try Artifacts.require(!queuedIntent, "The queued processing request is missing. Request processing again.")
            return nil
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        try Artifacts.require(((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 65_536,
                              "Queued request exceeds its size limit.")
        let request = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try request.validate(meeting, allowPublished: true)
        return request
    }

    func validate(_ meeting: Meeting, allowPublished: Bool) throws {
        try Artifacts.require(schemaVersion == 1 && meeting.id == meetingID && meeting.processingRunID == run
                              && meeting.pendingRevisionID == revision && meeting.pendingSummaryID == summary
                              && meeting.pendingBaseRevisionID == baseRevision && meeting.pendingBaseSummaryID == baseSummary
                              && meeting.processingNameMapRevision == nameMapRevision,
                              "The processing request was replaced or has an invalid identity.")
        try Artifacts.require(!meeting.captureState.isActive && Artifacts.audioFingerprint(meeting.chunks) == audioFingerprint
                              && (meeting.asrLanguage ?? "auto") == language,
                              "Audio or transcription language changed. Request processing again.")
        let ownRevision = allowPublished && (meeting.activeRevisionID == revision
                                            || (!summaryOnly && meeting.activeRevisionID == run))
        try Artifacts.require(meeting.activeRevisionID == baseRevision || ownRevision,
                              "The transcript changed. The stale processing request was discarded.")
        if summaryOnly {
            let currentNames = try Artifacts.nameMapRevision(meeting.speakerNames[revision] ?? [:])
            try Artifacts.require(currentNames == nameMapRevision,
                                  "Speaker names changed. Regenerate notes using the current names.")
        }
    }
}

@MainActor
final class ProcessingController: ObservableObject {
    private typealias Request = ProcessingRequest
    private enum CancellationReason { case user, recording, pause, quit }
    @Published private(set) var isBusy = false
    @Published private(set) var isCancelling = false
    @Published private(set) var queuedCount = 0
    @Published private(set) var isPaused = false
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var stageElapsedSeconds: TimeInterval = 0
    @Published private(set) var completedUnits: Int?
    @Published private(set) var totalUnits: Int?
    @Published private(set) var progressUnit: String?
    @Published private(set) var progressPhase: String?
    @Published private(set) var stage: String?
    @Published private(set) var meetingID: String?
    @Published var message: String?
    var changed: (() -> Void)?
    private let store: MeetingStore
    private let runtimeURL: URL
    private var task: Task<Void, Never>?
    private var preparation: Task<String, Error>?
    private var worker: WorkerProcess?
    private var runID: String?
    private var cancelled = false
    private var blocked = false
    private var validationError: String?
    private var cleanupProbe: WorkerProcess?
    private var queue: [Request] = []
    private var activeRequest: Request?
    private var cancellationReason: CancellationReason?
    private var recordingReserved = false
    private var shuttingDown = false
    private var deferredAfterCleanup: Request?
    private var clockTask: Task<Void, Never>?
    private var startedAt: Date?
    private var stageStartedAt: Date?
    var cleanupBlocked: Bool { blocked }
    var canReserveRecording: Bool { !blocked && !shuttingDown && !recordingReserved }

    func isMeetingBusy(_ id: String) -> Bool {
        meetingID == id || queue.contains { $0.meetingID == id } || deferredAfterCleanup?.meetingID == id
    }

    func canProcess(_ meeting: Meeting, summaryOnly: Bool = false) -> Bool {
        !meeting.captureState.isActive && !recordingReserved && !blocked && !shuttingDown && !isMeetingBusy(meeting.id)
            && meeting.audioRemovalStartedAt == nil
            && (meeting.audioRemovedAt == nil || (summaryOnly && meeting.activeRevisionID != nil))
    }

    var stageTitle: String {
        if stage == "cancelling" {
            switch cancellationReason {
            case .recording: return "Preparing to record"
            case .pause: return "Pausing processing"
            case .quit: return "Stopping processing"
            default: return "Cancelling"
            }
        }
        return MeetingStatus.stageTitle(stage)
    }

    init(store: MeetingStore, runtimeURL: URL = RuntimeConfiguration.url) {
        self.store = store
        self.runtimeURL = runtimeURL
    }

    func start(_ original: Meeting, summaryOnly: Bool = false, preferred: Bool = false) {
        guard !original.captureState.isActive, !shuttingDown, !isMeetingBusy(original.id),
              original.audioRemovalStartedAt == nil, summaryOnly || original.audioRemovedAt == nil else { return }
        do {
            let current = try store.load(id: original.id)
            try Artifacts.require(current.activeRevisionID == original.activeRevisionID
                                  && current.asrLanguage == original.asrLanguage
                                  && current.chunks == original.chunks,
                                  "The meeting changed. Reopen it before requesting processing.")
            let request = try makeRequest(current, summaryOnly: summaryOnly)
            if preferred { queue.insert(request, at: 0) } else { queue.append(request) }
            queuedCount = queue.count
            changed?()
            drainQueue()
        } catch { message = error.localizedDescription }
    }

    private func makeRequest(_ meeting: Meeting, summaryOnly: Bool) throws -> Request {
        try Artifacts.require(!meeting.captureState.isActive, "Finish recording before processing.")
        try Artifacts.require(meeting.audioRemovalStartedAt == nil && (summaryOnly || meeting.audioRemovedAt == nil),
                              "Saved audio has been removed from this meeting.")
        let revision = summaryOnly ? meeting.activeRevisionID : UUID().uuidString.lowercased()
        guard let revision else { throw CaptureFailure(message: "No accepted transcript is available for a summary retry.") }
        let names = summaryOnly ? meeting.speakerNames[revision] ?? [:] : [:]
        let request = Request(meetingID: meeting.id, run: UUID().uuidString.lowercased(), revision: revision,
                              summary: UUID().uuidString.lowercased(), summaryOnly: summaryOnly,
                              baseRevision: meeting.activeRevisionID, baseSummary: meeting.activeSummaryID,
                              audioFingerprint: Artifacts.audioFingerprint(meeting.chunks),
                              language: meeting.asrLanguage ?? "auto", nameMapRevision: try Artifacts.nameMapRevision(names))
        let directory = try store.artifactURL(meetingID: meeting.id, relativePath: "work/\(request.run)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(request).write(to: directory.appendingPathComponent("request.json"), options: .atomic)
        let data = try JSONSerialization.data(withJSONObject: ["schema_version": 1, "name_map_revision": request.nameMapRevision, "speaker_names": names])
        try data.write(to: directory.appendingPathComponent("names.json"), options: .atomic)
        var current = meeting
        current.processingStatus = isPaused ? "paused" : "queued"
        current.processingStage = nil
        current.processingError = nil
        current.processingRunID = request.run
        current.pendingRevisionID = request.revision
        current.pendingSummaryID = request.summary
        current.pendingBaseRevisionID = request.baseRevision
        current.pendingBaseSummaryID = request.baseSummary
        current.processingNameMapRevision = request.nameMapRevision
        try store.save(current)
        return request
    }

    private func currentMeeting(_ request: Request, allowPublished: Bool = false) throws -> Meeting {
        let meeting = try store.load(id: request.meetingID)
        try request.validate(meeting, allowPublished: allowPublished)
        return meeting
    }

    private func drainQueue() {
        guard task == nil, !isBusy, !recordingReserved, !isPaused, !shuttingDown, !blocked else { return }
        while !queue.isEmpty {
            let request = queue.removeFirst()
            queuedCount = queue.count
            do {
                _ = try currentMeeting(request)
                launch(request)
                return
            } catch { reject(request, message: error.localizedDescription) }
        }
        changed?()
    }

    private func reject(_ request: Request, message: String) {
        self.message = message
        guard var current = try? store.load(id: request.meetingID), current.processingRunID == request.run else { return }
        current.processingStatus = "failed"
        current.processingStage = nil
        current.processingError = message
        ArtifactRecovery.clearPending(&current)
        try? store.save(current)
    }

    private func launch(_ request: Request) {
        let run = request.run, revision = request.revision, summary = request.summary, summaryOnly = request.summaryOnly
        activeRequest = request
        isBusy = true
        isCancelling = false
        cancelled = false
        blocked = false
        validationError = nil
        cancellationReason = nil
        runID = run
        meetingID = request.meetingID
        message = nil
        setStage("preflight")
        startedAt = Date()
        elapsedSeconds = 0
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                self.elapsedSeconds = self.startedAt.map { Date().timeIntervalSince($0) } ?? 0
                self.stageElapsedSeconds = self.stageStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            }
        }
        task = Task {
            do {
                guard !cancelled else { throw CancellationError() }
                var meeting = try currentMeeting(request)
                if meeting.chunks.isEmpty {
                    meeting.processingStatus = "empty"
                    meeting.processingStage = nil
                    meeting.processingError = "No retained audio is available."
                    try store.save(meeting)
                    message = meeting.processingError
                    throw CaptureFailure(message: "No retained audio is available.")
                }
                let runtime = try RuntimeConfiguration.load(from: runtimeURL, summaryOnly: summaryOnly)
                meeting.processingStatus = "processing"
                meeting.processingStage = "preparing"
                meeting.processingError = nil
                let nameMapRevision = request.nameMapRevision
                try store.save(meeting)
                changed?()
                let namesPath = "work/\(run)/names.json"
                var arguments = ["-m", "afterword_worker", "process", "--meeting", try store.meetingURL(id: meeting.id).path,
                                 "--runtime", runtimeURL.path, "--run-id", run, "--revision-id", revision,
                                 "--summary-id", summary, "--names", namesPath, "--progress-events"]
                if summaryOnly {
                    arguments.append("--summary-only")
                } else {
                    setStage("preparing")
                    let root = store.rootURL
                    let input = meeting
                    let preparation = Task.detached(priority: .background) {
                        try AudioPreparation.prepare(meeting: input, rootURL: root, runID: run)
                    }
                    self.preparation = preparation
                    let preparedPath = try await preparation.value
                    self.preparation = nil
                    arguments += ["--prepared", preparedPath, "--language", meeting.asrLanguage ?? "auto", "--transcript-first"]
                }
                guard !cancelled else { throw CancellationError() }
                let worker = WorkerProcess(runID: run)
                self.worker = worker
                let result = try await worker.run(executable: URL(fileURLWithPath: runtime.python), arguments: arguments,
                                                  directory: URL(fileURLWithPath: runtime.worker_root)) { [weak self] event in
                    await self?.receive(event, request: request)
                }
                self.worker = nil
                guard result.cleanupConfirmed else {
                    blocked = true
                    cleanupProbe = worker
                    throw CaptureFailure(message: "Worker cleanup could not be confirmed. Recording remains blocked until owned processes have exited.")
                }
                if let error = result.error { throw CaptureFailure(message: error) }
                if let validationError { throw CaptureFailure(message: validationError) }
                if cancelled || result.terminal?.type == "cancelled" { throw CancellationError() }
                guard result.exitStatus == 0, let terminal = result.terminal, terminal.type == "completed" else {
                    throw CaptureFailure(message: result.terminal?.message ?? "Worker exited without a valid completion (exit \(result.exitStatus)).")
                }
                try Artifacts.require(terminal.revision_id == revision, "Worker completed a different transcript revision.")
                try acceptTranscript(request: request, revision: revision, run: summaryOnly ? nil : run,
                                     path: terminal.transcript_path, provenancePath: "revisions/\(revision)/provenance.json")
                var accepted = try currentMeeting(request, allowPublished: true)
                let transcript = try loadTranscript(accepted)
                if let summaryID = terminal.summary_id {
                    try Artifacts.require(summaryID == summary && terminal.summary_path == "revisions/\(revision)/summaries/\(summary).json", "Worker published an unexpected summary path.")
                    let notes = try Artifacts.read(MeetingSummary.self, store: store, meetingID: accepted.id, path: terminal.summary_path!)
                    try Artifacts.validate(notes, transcript: transcript, summaryID: summary, runID: run)
                    try Artifacts.require(notes.name_map_revision == nameMapRevision, "Summary was generated with an unexpected name map.")
                    accepted.activeSummaryID = summary
                } else {
                    try Artifacts.require(terminal.summary_path == nil && transcript.segments.isEmpty,
                                          "Worker completed without the required summary artifact.")
                }
                accepted.processingStatus = "completed"
                accepted.processingStage = nil
                accepted.processingError = nil
                ArtifactRecovery.clearPending(&accepted)
                try store.save(accepted)
                message = terminal.summary_id == nil ? "Processing finished with no speech to summarize." : "Transcript and notes are ready."
            } catch {
                preparation = nil
                worker = nil
                let wasCancelled = !blocked && (cancelled || error is CancellationError)
                message = wasCancelled ? "Processing cancelled. Saved audio and accepted artifacts remain available." : error.localizedDescription
                if var meeting = try? store.load(id: request.meetingID), meeting.processingRunID == run {
                    if meeting.activeRevisionID == run, (try? loadTranscript(meeting).speakerLabelsPending) == true {
                        message = wasCancelled
                            ? "Processing cancelled. Your transcript is saved; finish speaker labels later."
                            : "Your transcript is saved. Speaker labeling did not finish. \(error.localizedDescription)"
                    }
                    let deferred = cancellationReason != nil && cancellationReason != .user
                    meeting.processingStatus = deferred ? (isPaused ? "paused" : "queued")
                        : (wasCancelled ? "cancelled" : (meeting.chunks.isEmpty ? "empty" : "failed"))
                    meeting.processingStage = nil
                    meeting.processingError = message
                    try? store.save(meeting)
                    if deferred {
                        if blocked { deferredAfterCleanup = request }
                        else { deferRequest(request) }
                    }
                }
            }
            finishActivity()
        }
    }

    private func requestCancellation(_ reason: CancellationReason) {
        guard isBusy else { return }
        if cancellationReason == .user { return }
        cancellationReason = reason
        if reason == .user { deferredAfterCleanup = nil }
        if let request = activeRequest,
           var meeting = try? store.load(id: request.meetingID), meeting.processingRunID == request.run {
            meeting.processingStatus = reason == .user ? "cancelled" : (isPaused ? "paused" : "queued")
            try? store.save(meeting)
        }
        guard !isCancelling else { return }
        cancelled = true
        isCancelling = true
        setStage("cancelling")
        preparation?.cancel()
        worker?.cancel()
    }

    func cancel() { requestCancellation(.user) }

    func cancelQueued(meetingID: String) {
        if self.meetingID == meetingID { cancel(); return }
        guard let index = queue.firstIndex(where: { $0.meetingID == meetingID }) else { return }
        let request = queue.remove(at: index)
        if var meeting = try? store.load(id: meetingID), meeting.processingRunID == request.run {
            meeting.processingStatus = "cancelled"
            meeting.processingStage = nil
            meeting.processingError = "Queued processing was cancelled."
            ArtifactRecovery.clearPending(&meeting)
            try? store.save(meeting)
        }
        queuedCount = queue.count
        changed?()
    }

    func reserveRecording() async -> Bool {
        guard canReserveRecording else { return false }
        recordingReserved = true
        let operation = task
        requestCancellation(.recording)
        await operation?.value
        return !blocked && !shuttingDown
    }

    func releaseRecording(preferred meeting: Meeting? = nil) {
        if let meeting, !shuttingDown { start(meeting, preferred: true) }
        recordingReserved = false
        drainQueue()
        changed?()
    }

    func pause() {
        guard !isPaused, !shuttingDown else { return }
        isPaused = true
        updateQueuedStatus()
        requestCancellation(.pause)
        changed?()
    }

    func resume() {
        guard isPaused, !shuttingDown else { return }
        isPaused = false
        updateQueuedStatus()
        drainQueue()
        changed?()
    }

    private func updateQueuedStatus() {
        for request in queue {
            guard var meeting = try? store.load(id: request.meetingID), meeting.processingRunID == request.run else { continue }
            meeting.processingStatus = isPaused ? "paused" : "queued"
            try? store.save(meeting)
        }
    }

    private func deferRequest(_ request: Request) {
        do {
            let beforeRecovery = try currentMeeting(request, allowPublished: true)
            let meeting = try ArtifactRecovery.recover(beforeRecovery, store: store)
            if meeting.processingRunID != request.run { return }
            let summaryOnly = try resumesSummaryOnly(request, meeting: meeting)
            let continuation = try makeRequest(meeting, summaryOnly: summaryOnly)
            queue.insert(continuation, at: 0)
            queuedCount = queue.count
            message = isPaused ? "Processing paused. Saved transcripts remain available." : "Processing queued while recording takes priority."
        } catch { reject(request, message: error.localizedDescription) }
    }

    private func resumesSummaryOnly(_ request: Request, meeting: Meeting) throws -> Bool {
        if request.summaryOnly { return true }
        guard meeting.activeRevisionID == request.revision else { return false }
        return try !loadTranscript(meeting).speakerLabelsPending
    }

    func restoreQueue(from meetings: [Meeting]) {
        guard !isBusy, task == nil, queue.isEmpty else { return }
        isPaused = meetings.contains { $0.processingStatus == "paused" }
        let candidates = meetings.filter { ["queued", "paused", "interrupted"].contains($0.processingStatus) }
            .sorted {
                if ($0.activeRevisionID == nil) != ($1.activeRevisionID == nil) { return $0.activeRevisionID == nil }
                return $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt < $1.startedAt
            }
        for candidate in candidates {
            let run = candidate.processingRunID
            do {
                // Older jobs have no queue snapshot and retain the existing manual retry path.
                guard let request = try Request.load(store: store, meeting: candidate) else { continue }
                let current = try currentMeeting(request, allowPublished: true)
                let summaryOnly = try resumesSummaryOnly(request, meeting: current)
                queue.append(try makeRequest(current, summaryOnly: summaryOnly))
            } catch {
                message = error.localizedDescription
                if var current = try? store.load(id: candidate.id), current.processingRunID == run {
                    current.processingStatus = "failed"
                    current.processingError = message
                    current.processingStage = nil
                    ArtifactRecovery.clearPending(&current)
                    try? store.save(current)
                }
            }
        }
        queuedCount = queue.count
        drainQueue()
        changed?()
    }

    func beginShutdown() { shuttingDown = true }

    func prepareToQuit() async -> Bool {
        beginShutdown()
        requestCancellation(.quit)
        await task?.value
        if blocked && cleanupProbe?.cleanupConfirmed() == true { recheckCleanup() }
        if blocked { shuttingDown = false }
        return !blocked
    }

    func recheckCleanup() {
        guard blocked, cleanupProbe?.cleanupConfirmed() == true else {
            message = "Owned process cleanup is still unconfirmed. Try checking again after the processes finish."
            return
        }
        cleanupProbe = nil
        blocked = false
        if let deferred = deferredAfterCleanup {
            deferredAfterCleanup = nil
            deferRequest(deferred)
        }
        message = "Worker cleanup is confirmed. Recording and retries are available."
        finishActivity()
    }

    private func finishActivity() {
        clockTask?.cancel()
        clockTask = nil
        if !blocked {
            isBusy = false; isCancelling = false; setStage(nil); meetingID = nil; runID = nil
            activeRequest = nil
        }
        task = nil
        drainQueue()
        changed?()
    }

    private func setStage(_ value: String?) {
        stage = value
        stageStartedAt = value == nil ? nil : Date()
        stageElapsedSeconds = 0
        completedUnits = nil
        totalUnits = nil
        progressUnit = nil
        progressPhase = nil
    }

    private func receive(_ event: WorkerEvent, request: Request) {
        guard event.run_id == runID, !cancelled, validationError == nil else { return }
        guard event.process_group_id == nil else { return }
        do {
            if event.type == "stage_progress" {
                guard event.stage == stage else { return }
                completedUnits = event.completed
                totalUnits = event.total
                progressUnit = event.progress_unit
                progressPhase = event.progress_phase
                return
            }
            if event.type == "stage_started" {
                setStage(event.stage)
                var current = try currentMeeting(request, allowPublished: true)
                current.processingStage = event.stage
                try store.save(current)
                changed?()
            }
            if event.type == "stage_completed", ["transcript", "alignment"].contains(event.stage ?? ""),
               event.transcript_path != nil, !request.summaryOnly {
                let pendingLabels = event.stage == "transcript"
                let publishedRevision = pendingLabels ? event.run_id : request.revision
                try Artifacts.require(event.revision_id == publishedRevision, "Worker returned a different transcript revision.")
                try acceptTranscript(request: request, revision: publishedRevision, run: event.run_id,
                                     path: event.transcript_path, provenancePath: event.provenance_path, pendingLabels: pendingLabels)
                if pendingLabels {
                    message = "Transcript ready. Speaker labels and notes will follow. You can cancel processing and finish labels later."
                }
                changed?()
            }
        } catch {
            message = error.localizedDescription
            validationError = error.localizedDescription
            worker?.cancel()
        }
    }

    private func acceptTranscript(request: Request, revision: String, run: String?, path: String?, provenancePath: String?,
                                  pendingLabels: Bool = false) throws {
        try Artifacts.require(path == "revisions/\(revision)/transcript.json" && provenancePath == "revisions/\(revision)/provenance.json",
                              "Worker returned an unexpected transcript path.")
        var meeting = try currentMeeting(request, allowPublished: true)
        let transcript = try Artifacts.loadRevision(store: store, meeting: meeting, revision: revision, run: run)
        try Artifacts.require(!pendingLabels || transcript.speakerLabelsPending, "The early transcript is not marked for pending speaker labels.")
        if meeting.activeRevisionID != revision {
            meeting.activeRevisionID = revision
            meeting.activeSummaryID = nil
            meeting.speakerNames[revision] = [:]
            try store.save(meeting)
        }
    }

    func loadTranscript(_ meeting: Meeting) throws -> Transcript {
        guard let revision = meeting.activeRevisionID else { throw CaptureFailure(message: "No transcript is available yet.") }
        return try Artifacts.loadRevision(store: store, meeting: meeting, revision: revision)
    }

    func loadSummary(_ meeting: Meeting, transcript: Transcript) throws -> MeetingSummary? {
        guard let summary = meeting.activeSummaryID else { return nil }
        let notes = try Artifacts.read(MeetingSummary.self, store: store, meetingID: meeting.id,
                                       path: "revisions/\(transcript.revision_id)/summaries/\(summary).json")
        try Artifacts.validate(notes, transcript: transcript, summaryID: summary)
        return notes
    }

    func rename(meeting: Meeting, speakerID: String, name: String) throws {
        var current = try store.load(id: meeting.id)
        try Artifacts.require(current.activeRevisionID == meeting.activeRevisionID,
                              "The transcript changed. Reopen the speaker editor and try again.")
        let transcript = try loadTranscript(current)
        try Artifacts.require(transcript.speakers.contains { $0.id == speakerID }, "Unknown speaker.")
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try Artifacts.require(name.count <= 100, "Speaker names must be at most 100 characters.")
        if name.isEmpty { current.speakerNames[transcript.revision_id]?.removeValue(forKey: speakerID) }
        else { current.speakerNames[transcript.revision_id, default: [:]][speakerID] = name }
        try store.save(current)
        changed?()
    }

    func setTranscriptionLanguage(_ language: String, meeting: Meeting) throws {
        try Artifacts.require(!isMeetingBusy(meeting.id) && !meeting.captureState.isActive,
                              "Finish or cancel this meeting's queued processing before changing transcription language.")
        var current = try store.load(id: meeting.id)
        try Artifacts.require(!current.audioUnavailable, "Saved audio has been removed from this meeting.")
        current.asrLanguage = language
        try store.save(current)
        changed?()
    }
}
