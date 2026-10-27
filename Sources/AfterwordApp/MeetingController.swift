import AppKit
import AVFoundation
import AfterwordCore
import Combine
import ScreenCaptureKit

@MainActor
final class MeetingController: ObservableObject {
    enum Activity: String {
        case idle = "Ready to record", starting = "Starting", recording = "Recording", pausing = "Pausing"
        case paused = "Paused", resuming = "Resuming", finalizing = "Finalizing"
    }

    @Published var meetings: [Meeting] = []
    @Published var selectedID: String?
    @Published var activity: Activity = .idle
    @Published var message: String?
    @Published private(set) var permissionIssue: RecordingPermissionIssue?
    @Published var microphoneLevel: Float = 0
    @Published var systemLevel: Float = 0
    @Published var receivedSources: Set<AudioSource> = []
    @Published var elapsedUS: Int64 = 0
    @Published var retainedUS: Int64 = 0
    @Published var playbackInfo: String?
    @Published var recordingLanguage = "auto"
    @Published var showingRecordingSetup = false
    @Published private(set) var deletingMeetingID: String?
    @Published private(set) var isLoading = true
    @Published private(set) var recoveryBlocked = false
    let store: MeetingStore
    let processing: ProcessingController
    let calendar: CalendarController
    private var engine: CaptureEngine?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lastSampleAt: [AudioSource: Date] = [:]
    private var transition: Task<Void, Never>?
    private var pendingInterruption: String?
    private var sessionToken: UUID?
    private var quitting = false
    private var playback: EvidencePlayback?
    private var playbackMeetingID: String?
    private var localControl: LocalControlServer?
    private var deletionTask: Task<Void, Error>?
    private var recoveryInFlight = false
    private let requestMicrophoneAccess: @MainActor () async -> Bool
    private let requestAppQuit: @MainActor () -> Void
    private let openPrivacySettings: @MainActor (URL) -> Void
    private var pendingPrivacySettingsURL: URL?
    var onCaptureFinished: ((Meeting) -> Void)?
    var canRecord: Bool { activity == .idle && processing.canReserveRecording && !isLoading && !quitting && deletingMeetingID == nil }
    func canProcess(_ meeting: Meeting, summaryOnly: Bool = false) -> Bool {
        activity == .idle && !isLoading && !quitting && deletingMeetingID != meeting.id
            && processing.canProcess(meeting, summaryOnly: summaryOnly)
    }
    var selectedMeeting: Meeting? { meetings.first { $0.id == selectedID } }

    init(rootURL: URL? = nil, runtimeURL: URL = RuntimeConfiguration.url, calendarController: CalendarController? = nil,
         requestMicrophoneAccess: @escaping @MainActor () async -> Bool = {
             let status = AVCaptureDevice.authorizationStatus(for: .audio)
             if status == .notDetermined { return await AVCaptureDevice.requestAccess(for: .audio) }
             return status == .authorized
         }, requestAppQuit: @escaping @MainActor () -> Void = { NSApp.terminate(nil) },
         openPrivacySettings: @escaping @MainActor (URL) -> Void = { _ = NSWorkspace.shared.open($0) }) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        store = MeetingStore(rootURL: rootURL ?? support.appendingPathComponent("Afterword/meetings", isDirectory: true))
        processing = ProcessingController(store: store, runtimeURL: runtimeURL)
        calendar = calendarController ?? CalendarController(store: store)
        self.requestMicrophoneAccess = requestMicrophoneAccess
        self.requestAppQuit = requestAppQuit
        self.openPrivacySettings = openPrivacySettings
        playback = EvidencePlayback { [weak self] error in
            self?.playbackInfo = nil
            self?.playbackMeetingID = nil
            if let error { self?.message = error }
        }
        recoverMeetings()
        processing.changed = { [weak self] in self?.reload(); self?.objectWillChange.send() }
        onCaptureFinished = { [weak self] meeting in self?.processing.start(meeting, preferred: true) }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.interrupt("The Mac is going to sleep. Retained audio has been saved.") }
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] notification in
                guard let device = notification.object as? AVCaptureDevice, device.hasMediaType(.audio) else { return }
                Task { @MainActor in self?.interrupt("An audio capture device disconnected.") }
            })
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if rootURL == nil {
            do {
                localControl = try LocalControlServer { [weak self] id in
                    self?.processFromCLI(id: id) ?? .rejected("Afterword is closing.")
                }
            } catch { message = "Local CLI unavailable: \(error.localizedDescription)" }
        }
    }

    func processFromCLI(id: String) -> LocalControlReply {
        do {
            let meeting = try store.load(id: id)
            if processing.isMeetingBusy(id) {
                return .accepted(status: meeting.processingStatus, runID: meeting.processingRunID)
            }
            if isLoading { return .rejected("Afterword is still loading.") }
            if meeting.activeRevisionID != nil,
               (try? processing.loadTranscript(meeting).speakerLabelsPending) != true {
                return .rejected("This meeting already has a saved transcript. Use the app to confirm reprocessing.")
            }
            guard canProcess(meeting) else {
                return .rejected("This recording cannot be processed while recording, loading, or cleaning up.")
            }
            processing.start(meeting)
            let updated = try store.load(id: id)
            guard updated.processingRunID != meeting.processingRunID else {
                return .rejected(processing.message ?? "Afterword did not queue this recording.")
            }
            return .accepted(status: updated.processingStatus, runID: updated.processingRunID)
        } catch { return .rejected(error.localizedDescription) }
    }

    private func recoverMeetings() {
        guard !recoveryInFlight else { return }
        recoveryInFlight = true
        recoveryBlocked = false
        isLoading = true
        let root = store.rootURL
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let recoveryStore = MeetingStore(rootURL: root)
                    var recovered = try recoveryStore.recover()
                    var issues = recoveryStore.recoveryIssues
                    var busy = recoveryStore.busyMeetingIDs
                    for index in recovered.indices where recovered[index].audioRemovalStartedAt != nil {
                        let id = recovered[index].id
                        do {
                            try MeetingDeletion.removeAudio(id: id, rootURL: root)
                            recovered[index] = try recoveryStore.load(id: id)
                        } catch { issues.append("\(id): Audio removal is incomplete. \(error.localizedDescription)") }
                    }
                    let meetings = recovered.map { meeting in
                        if busy.contains(meeting.id) { return meeting }
                        do { return try ArtifactRecovery.recover(meeting, store: recoveryStore) }
                        catch let error as ProcessingCleanupPending {
                            busy.append(error.meetingID)
                            return meeting
                        }
                        catch {
                            issues.append("\(meeting.title): \(error.localizedDescription)")
                            return (try? recoveryStore.load(id: meeting.id)) ?? meeting
                        }
                    }
                    return (meetings, issues, busy)
                }.value
                meetings = result.0
                selectedID = meetings.first?.id
                recoveryBlocked = !result.2.isEmpty
                message = recoveryBlocked ? "A previous processing job is still exiting. Recording and processing remain blocked until cleanup is confirmed." : nil
                if !result.1.isEmpty { message = [message, result.1.joined(separator: "\n")].compactMap { $0 }.joined(separator: "\n") }
            } catch {
                recoveryBlocked = true
                message = error.localizedDescription
            }
            isLoading = recoveryBlocked
            recoveryInFlight = false
            if !recoveryBlocked { processing.restoreQueue(from: meetings) }
        }
    }

    func recheckRecovery() {
        guard activity == .idle && !processing.isBusy else { return }
        recoverMeetings()
    }

    func reload() {
        do {
            meetings = try store.list()
            if selectedID == nil { selectedID = meetings.first?.id }
        } catch { message = error.localizedDescription }
    }

    func record() {
        guard canRecord else { return }
        let language = recordingLanguage
        let calendarSelection = calendar.recordingSelection()
        stopPlayback()
        activity = .starting
        message = nil
        permissionIssue = nil
        processing.message = nil
        pendingInterruption = nil
        let token = UUID()
        sessionToken = token
        transition = Task {
            do {
                guard await processing.reserveRecording() else {
                    throw CaptureFailure(message: "Recording must wait until processing cleanup is confirmed.")
                }
                guard !quitting, pendingInterruption == nil else { throw CancellationError() }
                let granted = await requestMicrophoneAccess()
                guard granted else {
                    throw RecordingPermissionIssue.microphone
                }
                guard !quitting, pendingInterruption == nil else { throw CancellationError() }
                guard let device = AVCaptureDevice.default(for: .audio) else {
                    throw CaptureFailure(message: "No microphone is available. Connect one before recording.")
                }
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard !quitting, pendingInterruption == nil else { throw CancellationError() }
                guard let display = content.displays.first else {
                    throw CaptureFailure(message: "No display is available for system audio capture. Restore an available display, then try Record again. No recording has started.")
                }
                let capture = try CaptureEngine(store: store, asrLanguage: language,
                                                title: calendarSelection?.event.suggestedMeetingTitle ?? "Meeting") { [weak self] event in
                    Task { @MainActor in
                        guard self?.sessionToken == token else { return }
                        self?.handle(event)
                    }
                }
                engine = capture
                selectedID = capture.meetingID
                try await capture.start(display: display, microphoneID: device.uniqueID)
                calendar.recordingStarted(meetingID: capture.meetingID, selection: calendarSelection)
                receivedSources = []
                activity = .recording
                reload()
                if let pendingInterruption { await finish(reason: pendingInterruption) }
            } catch {
                let detail = CaptureFailure.describe(error)
                permissionIssue = RecordingPermissionIssue.identify(error)
                if let engine { _ = try? await engine.stop(reason: detail) }
                engine = nil
                sessionToken = nil
                activity = .idle
                message = detail
                reload()
                processing.releaseRecording()
            }
            transition = nil
        }
    }

    func togglePause() {
        guard let engine, activity == .recording || activity == .paused else { return }
        let pausing = activity == .recording
        activity = pausing ? .pausing : .resuming
        transition = Task {
            do {
                if pausing { try await engine.pause() } else { try await engine.resume() }
                microphoneLevel = 0
                systemLevel = 0
                activity = pausing ? .paused : .recording
                reload()
                if let pendingInterruption { await finish(reason: pendingInterruption) }
            } catch { await finish(reason: error.localizedDescription) }
            transition = nil
        }
    }

    func stop() {
        guard activity == .recording || activity == .paused else { return }
        activity = .finalizing
        transition = Task { await finish(); transition = nil }
    }

    private func interrupt(_ reason: String) {
        guard activity != .idle, activity != .finalizing else { return }
        if transition != nil {
            pendingInterruption = pendingInterruption ?? reason
            return
        }
        activity = .finalizing
        transition = Task {
            await finish(reason: reason)
            transition = nil
        }
    }

    private func finish(reason: String? = nil) async {
        guard let engine else { activity = .idle; processing.releaseRecording(); return }
        activity = .finalizing
        do {
            let meeting = try await engine.stop(reason: reason)
            message = meeting.captureError ?? "Audio saved."
            let missing = AudioSource.allSources.filter { source in !meeting.chunks.contains { $0.source == source } }
            if !missing.isEmpty {
                message = (message ?? "") + " No audio was saved for: " + missing.map(\.rawValue).joined(separator: ", ") + ". Source capture has not been verified."
            }
            self.engine = nil
            sessionToken = nil
            pendingInterruption = nil
            activity = .idle
            microphoneLevel = 0
            systemLevel = 0
            reload()
            if meeting.captureState == .stopped && !quitting { onCaptureFinished?(meeting) }
            processing.releaseRecording()
        } catch {
            self.engine = nil
            sessionToken = nil
            pendingInterruption = nil
            activity = .idle
            message = "Recording interrupted: \(error.localizedDescription). Committed audio remains available."
            reload()
            processing.releaseRecording()
        }
    }

    func prepareToQuit() async -> Bool {
        quitting = true
        processing.beginShutdown()
        _ = try? await deletionTask?.value
        await transition?.value
        if engine != nil { await finish() }
        let ready = await processing.prepareToQuit()
        if !ready { quitting = false }
        if ready { localControl?.stop() }
        return ready
    }

    func openPermissionSettingsAfterQuit() {
        guard activity == .idle, !quitting, let permissionIssue else { return }
        pendingPrivacySettingsURL = permissionIssue.settingsURL
        requestAppQuit()
    }

    func finishPermissionSettingsQuit(ready: Bool) {
        let settingsURL = pendingPrivacySettingsURL
        pendingPrivacySettingsURL = nil
        if ready, let settingsURL { openPrivacySettings(settingsURL) }
    }

    func revealMeeting(_ meeting: Meeting) {
        do { NSWorkspace.shared.activateFileViewerSelecting([try store.meetingURL(id: meeting.id)]) }
        catch { message = error.localizedDescription }
    }

    func canRenameMeeting(_ meeting: Meeting) -> Bool {
        guard !isLoading, deletingMeetingID != meeting.id else { return false }
        if engine?.meetingID == meeting.id { return activity == .recording || activity == .paused }
        return !meeting.captureState.isActive
    }

    func canDeleteMeeting(_ meeting: Meeting) -> Bool {
        activity == .idle && !isLoading && !quitting && deletingMeetingID == nil
            && !MeetingDeletion.isActive(meeting) && !processing.isMeetingBusy(meeting.id)
    }

    func canDeleteMeetingAudio(_ meeting: Meeting) -> Bool {
        canDeleteMeeting(meeting) && meeting.audioRemovedAt == nil
            && (!meeting.chunks.isEmpty || meeting.audioRemovalStartedAt != nil)
    }

    func deleteMeeting(id: String) async throws {
        let meeting = try store.load(id: id)
        guard canDeleteMeeting(meeting) else {
            throw CaptureFailure(message: "Finish recording or cancel this meeting's processing before deleting it.")
        }
        deletingMeetingID = id
        if playbackMeetingID == id { stopPlayback() }
        let rootURL = store.rootURL
        let task = Task.detached(priority: .utility) { try MeetingDeletion.remove(id: id, rootURL: rootURL) }
        deletionTask = task
        defer { deletingMeetingID = nil; deletionTask = nil }
        do {
            try await task.value
            reload()
            if selectedID == id { selectedID = meetings.first?.id }
        } catch {
            reload()
            throw error
        }
    }

    func deleteMeetingAudio(id: String) async throws {
        let meeting = try store.load(id: id)
        guard canDeleteMeetingAudio(meeting) else {
            throw CaptureFailure(message: "Finish recording or cancel this meeting's processing before removing its audio.")
        }
        deletingMeetingID = id
        if playbackMeetingID == id { stopPlayback() }
        let rootURL = store.rootURL
        let task = Task.detached(priority: .utility) { try MeetingDeletion.removeAudio(id: id, rootURL: rootURL) }
        deletionTask = task
        defer { deletingMeetingID = nil; deletionTask = nil }
        do { try await task.value; reload() }
        catch { reload(); throw error }
    }

    func renameMeeting(id: String, title: String) async throws {
        let current = try store.load(id: id)
        guard canRenameMeeting(current) else {
            throw CaptureFailure(message: "Wait for the current capture transition before renaming this meeting.")
        }
        if let engine, engine.meetingID == id {
            try await engine.rename(to: title)
        } else {
            _ = try MeetingStore(rootURL: store.rootURL).rename(id: id, title: title)
        }
        reload()
    }

    func linkCalendarEvent(_ selection: RecordingCalendarSelection, meetingID: String,
                           useEventTitle: Bool, explicitlyReplaceTitle: Bool = false) async throws {
        let meeting = try store.load(id: meetingID)
        guard canRenameMeeting(meeting), !meeting.captureState.isActive else {
            throw CaptureFailure(message: "Finish this recording before linking a calendar event.")
        }
        try calendar.save(selection, meetingID: meetingID)
        if useEventTitle, (meeting.title == "Meeting" || explicitlyReplaceTitle),
           let title = selection.event.suggestedMeetingTitle {
            try await renameMeeting(id: meetingID, title: title)
        }
    }

    func play(_ segment: TranscriptSegment, in meeting: Meeting) {
        play(source: segment.source, startUS: segment.start_us, endUS: segment.end_us, in: meeting)
    }

    func play(source: AudioSource, startUS: Int64, endUS: Int64, in meeting: Meeting) {
        guard activity == .idle, deletingMeetingID != meeting.id else { return }
        guard !meeting.audioUnavailable else { message = "Saved audio was removed from this meeting."; return }
        do {
            let chunks = meeting.chunks.filter { $0.source == source && $0.startUS < endUS && $0.endUS > startUS }
                .sorted { $0.startUS < $1.startUS }
            guard let first = chunks.first else {
                throw CaptureFailure(message: "The evidence audio chunk is unavailable.")
            }
            stopPlayback()
            let parts = try chunks.map { chunk in
                let start = max(startUS, chunk.startUS)
                let end = min(endUS, chunk.endUS)
                return EvidencePlayback.Part(url: try store.artifactURL(meetingID: meeting.id, relativePath: chunk.relativePath),
                    offset: Double(start - chunk.startUS) / 1_000_000, duration: Double(end - start) / 1_000_000)
            }
            try playback?.play(parts)
            playbackMeetingID = meeting.id
            let offset = Double(startUS - first.startUS) / 1_000_000
            playbackInfo = "\(source.rawValue) · \(String(format: "%.3f", Double(startUS) / 1_000_000))–\(String(format: "%.3f", Double(endUS) / 1_000_000)) s · file offset \(String(format: "%.3f", offset)) s"
        } catch { message = error.localizedDescription }
    }

    func stopPlayback() { playback?.stop(); playbackInfo = nil; playbackMeetingID = nil }

    private func handle(_ event: CaptureEngine.Event) {
        switch event {
        case .level(let source, let value):
            lastSampleAt[source] = Date()
            receivedSources.insert(source)
            if activity == .recording {
                if source == .microphone { microphoneLevel = value } else { systemLevel = value }
            }
        case .warning(let detail): message = detail
        case .failed(let reason): interrupt(reason)
        }
    }

    private func tick() {
        guard let engine else { return }
        elapsedUS = engine.elapsedUS()
        retainedUS = engine.retainedUS()
        for source in AudioSource.allSources where Date().timeIntervalSince(lastSampleAt[source] ?? .distantPast) > 2 {
            receivedSources.remove(source)
            if source == .microphone { microphoneLevel = 0 } else { systemLevel = 0 }
        }
    }
}
