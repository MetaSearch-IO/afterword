import AppKit
import AfterwordCore
import SwiftUI

@main
struct AfterwordApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller = MeetingController()

    var body: some Scene {
        WindowGroup {
            MeetingWindow(controller: controller)
                .onAppear { delegate.controller = controller }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Recording") { controller.showingRecordingSetup = true }
                    .keyboardShortcut("n")
                    .disabled(!controller.canRecord || controller.showingRecordingSetup)
            }
        }
        Settings {
            RemoteProcessingSettings()
        }
    }
}

private struct RemoteProcessingSettings: View {
    @AppStorage(RemoteProcessing.preferenceKey) private var enabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Process meetings on Hyperion", isOn: $enabled)
            Text("Off by default. When enabled, prepared audio and the inputs needed for processing are sent to Hyperion over your tailnet. Raw capture chunks stay on this Mac.")
            Text("An updated Hyperion service is required. If it is not ready, no meeting data is uploaded and processing fails.")
            Text("The choice is saved when a meeting is queued. Changing it affects new processing requests, not a queued or running job.")
            Text("If Hyperion is unavailable, turn this off and retry the meeting locally. Voice IDs may differ because Hyperion cannot see profiles from your earlier meetings.")
        }
        .font(.callout)
        .padding(24)
        .frame(width: 500)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var controller: MeetingController?
    private var terminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating, let controller else { return terminating ? .terminateLater : .terminateNow }
        terminating = true
        Task {
            let ready = await controller.prepareToQuit()
            if !ready { terminating = false }
            controller.finishPermissionSettingsQuit(ready: ready)
            sender.reply(toApplicationShouldTerminate: ready)
        }
        return .terminateLater
    }
}

struct MeetingWindow: View {
    @ObservedObject var controller: MeetingController
    @ObservedObject var processing: ProcessingController
    @ObservedObject var calendar: CalendarController
    @State private var showingCalendarSettings = false
    @State private var deletionPrompt: DeletionPrompt?

    private enum DeletionPrompt {
        case confirm(Meeting), confirmAudio(Meeting), failed(String)

        var title: String {
            switch self {
            case .confirm: "Delete meeting?"
            case .confirmAudio: "Delete saved audio?"
            case .failed: "Unable to delete"
            }
        }

        var message: String {
            switch self {
            case .confirm(let meeting):
                "Permanently delete “\(meeting.title)” and all its local audio, transcripts, notes, calendar details, and working files? Exported copies are kept. This cannot be undone."
            case .confirmAudio(let meeting):
                meeting.activeRevisionID == nil
                    ? "Permanently delete all saved audio for “\(meeting.title)”? No transcript exists, so one cannot be created afterward. Meeting details remain. This cannot be undone."
                    : "Permanently delete all saved audio for “\(meeting.title)”? Existing transcripts and notes remain, but playback and audio reprocessing will be unavailable. This cannot be undone."
            case .failed(let message): message
            }
        }
    }

    init(controller: MeetingController) {
        self.controller = controller
        self.processing = controller.processing
        self.calendar = controller.calendar
    }

    var body: some View {
        VStack(spacing: 0) {
            if controller.activity != .idle {
                captureControls.padding(20)
                Divider()
            }
            meetingBrowser
        }
        .frame(minWidth: 820, minHeight: 560)
        .alert(deletionPrompt?.title ?? "Delete meeting?", isPresented: Binding(
            get: { deletionPrompt != nil }, set: { if !$0 { deletionPrompt = nil } }), presenting: deletionPrompt) { prompt in
            switch prompt {
            case .confirm(let meeting):
                Button("Delete Meeting", role: .destructive) {
                    Task {
                        do { try await controller.deleteMeeting(id: meeting.id) }
                        catch { deletionPrompt = .failed(error.localizedDescription) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            case .confirmAudio(let meeting):
                Button("Delete Audio", role: .destructive) {
                    Task {
                        do { try await controller.deleteMeetingAudio(id: meeting.id) }
                        catch { deletionPrompt = .failed(error.localizedDescription) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            case .failed:
                Button("OK", role: .cancel) {}
            }
        } message: { prompt in
            Text(prompt.message)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showingCalendarSettings = true } label: { Label("Calendar", systemImage: "calendar") }
                    .labelStyle(.titleAndIcon)
                    .help("Google Calendar connection and event selection")
                Button { controller.showingRecordingSetup = true } label: {
                    Label("New Recording", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .labelStyle(.titleAndIcon)
                .help("Set up a new recording (⌘N)")
                .disabled(!controller.canRecord || controller.showingRecordingSetup)
            }
        }
        .sheet(isPresented: $controller.showingRecordingSetup) {
            NewRecordingSetupView(controller: controller, calendar: calendar)
                .interactiveDismissDisabled(controller.activity == .starting)
        }
        .sheet(isPresented: $showingCalendarSettings) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Google Calendar").font(.title2.bold())
                CalendarRecordingPicker(calendar: calendar, canChoose: controller.activity == .idle)
                HStack {
                    Spacer()
                    Button("Done") { showingCalendarSettings = false }.keyboardShortcut(.cancelAction)
                }
            }.padding(24).frame(width: 610)
        }
        .onChange(of: controller.showingRecordingSetup) { _, showing in
            if showing && controller.permissionIssue == nil { controller.message = nil }
        }
        .onChange(of: controller.activity) { _, activity in
            if activity == .recording { controller.showingRecordingSetup = false }
        }
        .task {
            await calendar.restore()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) }
                catch { break }
                calendar.refreshIfNeeded()
            }
        }
    }

    private var meetingBrowser: some View {
        NavigationSplitView {
            List(controller.meetings, selection: $controller.selectedID) { meeting in
                MeetingListRow(meeting: meeting, isSelected: controller.selectedID == meeting.id,
                               processingStage: processing.meetingID == meeting.id ? processing.stage : nil)
                    .contextMenu {
                        Button(role: .destructive) { deletionPrompt = .confirm(meeting) } label: {
                            Label("Delete Meeting…", systemImage: "trash")
                        }
                        .disabled(!controller.canDeleteMeeting(meeting))
                        .help("Finish recording or cancel this meeting's queued processing before deleting it.")
                    }
                    .tag(meeting.id)
            }
            .navigationTitle("Meetings")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            VStack(alignment: .leading, spacing: 20) {
                if controller.deletingMeetingID != nil {
                    ProgressView("Deleting local files…").controlSize(.small)
                }
                if controller.recoveryBlocked { Button("Check Previous Job Cleanup") { controller.recheckRecovery() } }
                else if controller.isLoading { ProgressView("Checking saved meetings…") }
                if processing.isBusy || processing.queuedCount > 0 || processing.isPaused { processingControls }
                if let message = processing.message {
                    Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !controller.showingRecordingSetup && controller.permissionIssue == nil, let message = controller.message {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let meeting = controller.selectedMeeting {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            meetingDetail(meeting)
                            ReviewPane(meeting: meeting, controller: controller, processing: processing)
                        }
                        .disabled(controller.deletingMeetingID == meeting.id)
                    }
                } else {
                    ContentUnavailableView("Record a meeting", systemImage: "waveform",
                                           description: Text("Capture microphone and system output locally. Wear headphones to keep the two sources separate."))
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .navigationTitle("Afterword")
        }
    }

    private var processingControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if processing.isBusy {
                    ProgressView().controlSize(.small)
                    Text(processing.stageTitle)
                    Text(processing.processingRemotely ? "Hyperion" : "This Mac")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(processing.isPaused ? "Processing paused" : "Processing queued")
                }
                Spacer()
                Button(processing.isPaused ? "Resume Processing" : "Pause Processing") {
                    if processing.isPaused { processing.resume() } else { processing.pause() }
                }.disabled(processing.cleanupBlocked)
                if processing.isBusy {
                    Button("Cancel Processing") { processing.cancel() }
                        .disabled(processing.isCancelling && !processing.cleanupBlocked)
                }
                if processing.cleanupBlocked { Button("Check Cleanup") { processing.recheckCleanup() } }
            }
            if processing.isBusy {
                HStack {
                    if let title = controller.meetings.first(where: { $0.id == processing.meetingID })?.title { Text(title) }
                    Spacer()
                    Text("Elapsed \(elapsed(processing.elapsedSeconds)) · This stage \(elapsed(processing.stageElapsedSeconds))")
                        .monospacedDigit()
                }.font(.caption).foregroundStyle(.secondary)
                if let completed = processing.completedUnits, let total = processing.totalUnits, let unit = processing.progressUnit {
                    Text("\(progressLabel(unit)): \(completed) of \(total)").font(.caption).foregroundStyle(.secondary)
                    if total > 0 { ProgressView(value: Double(completed), total: Double(total)) }
                }
            }
            if processing.queuedCount > 0 {
                Text("\(processing.queuedCount) meeting\(processing.queuedCount == 1 ? "" : "s") waiting")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("New recordings take priority. Pausing processing releases model resources; unfinished stages may restart when resumed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func elapsed(_ seconds: TimeInterval) -> String {
        let seconds = max(0, Int(seconds))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func progressLabel(_ unit: String) -> String {
        switch unit {
        case "audio_windows": "Audio sections"
        case "speech_clips": "Speech segments in this section"
        case "segmentation_chunks": "Finding speech"
        case "embedding_batches": "Comparing speakers"
        case "note_groups": "Drafting notes"
        case "reduction_groups": "Combining notes"
        default: "Completed units"
        }
    }

    private var captureControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(controller.activity == .recording ? Color.red : Color.secondary)
                    .frame(width: 9, height: 9)
                Text("Current recording").font(.headline)
                Text(controller.activity.rawValue).foregroundStyle(.secondary)
                Spacer()
                if controller.activity != .starting {
                    Text("Elapsed \(duration(controller.elapsedUS)) · Retained \(duration(controller.retainedUS))")
                        .monospacedDigit().font(.caption)
                }
            }
            if let recording = controller.meetings.first(where: { $0.captureState.isActive }) {
                Text(recording.title).font(.callout).textSelection(.enabled)
            }
            HStack {
                Button(controller.activity == .paused ? "Resume" : "Pause") { controller.togglePause() }
                    .disabled(controller.activity != .recording && controller.activity != .paused)
                Button("Stop") { controller.stop() }
                    .disabled(controller.activity != .recording && controller.activity != .paused)
            }
            HStack(spacing: 24) {
                meter("Microphone", value: controller.microphoneLevel)
                meter("System output", value: controller.systemLevel)
            }
            if controller.activity == .recording {
                ForEach(AudioSource.allSources.filter { !controller.receivedSources.contains($0) }, id: \.rawValue) { source in
                    Text("Waiting for \(source == .microphone ? "microphone" : "system output") audio…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func meter(_ name: String, value: Float) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.caption)
            ProgressView(value: Double(value)).tint(.green)
        }
    }

    private func meetingDetail(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            MeetingTitleEditor(meeting: meeting, controller: controller).id(meeting.id)
            CalendarMeetingDetails(meeting: meeting, controller: controller, calendar: calendar)
            Text(MeetingStatus.date(meeting.startedAt)).foregroundStyle(.secondary)
                .help("Times are shown in \(TimeZone.autoupdatingCurrent.identifier).")
            LabeledContent("Recording", value: MeetingStatus.recording(meeting).title)
                .help(MeetingStatus.recording(meeting).explanation)
            LabeledContent("Saved audio", value: meeting.audioUnavailable
                           ? (meeting.audioRemovedAt == nil ? "Removal incomplete" : "Removed")
                           : duration(meeting.retainedDurationUS))
            ForEach(AudioSource.allSources, id: \.rawValue) { source in
                let chunks = meeting.chunks.filter { $0.source == source }
                LabeledContent(source == .microphone ? "Microphone" : "System output",
                               value: chunks.isEmpty ? "No audio saved"
                                   : (meeting.audioUnavailable ? "Removed" : duration(chunks.reduce(0) { $0 + $1.durationUS })))
            }
            let status = MeetingStatus.processing(meeting, stage: processing.meetingID == meeting.id ? processing.stage : nil)
            LabeledContent("Processing", value: status.title).help(status.explanation)
            if let available = MeetingStatus.savedResults(meeting) {
                Text(available).font(.caption).foregroundStyle(.secondary)
            }
            if processing.isMeetingBusy(meeting.id) && processing.meetingID != meeting.id {
                Button("Cancel Queued Processing") { processing.cancelQueued(meetingID: meeting.id) }
            }
            if let error = meeting.captureError {
                Text(error).foregroundStyle(.orange).textSelection(.enabled)
            }
            Button("Show Saved Files") { controller.revealMeeting(meeting) }
            if meeting.audioRemovedAt == nil && (!meeting.chunks.isEmpty || meeting.audioRemovalStartedAt != nil) {
                Button(meeting.audioRemovalStartedAt == nil ? "Delete Saved Audio…" : "Finish Removing Audio") {
                    deletionPrompt = .confirmAudio(meeting)
                }.disabled(!controller.canDeleteMeetingAudio(meeting))
            }
            if let error = meeting.processingError { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
        }
    }

    private func duration(_ microseconds: Int64) -> String {
        let seconds = max(0, microseconds / 1_000_000)
        return String(format: "%02lld:%02lld", seconds / 60, seconds % 60)
    }
}

struct NewRecordingSetupView: View {
    @ObservedObject var controller: MeetingController
    @ObservedObject var calendar: CalendarController

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Recording").font(.title2.bold())
            Text("Create a new meeting recording. Choose its language and optional calendar event before you start.")
                .fixedSize(horizontal: false, vertical: true)
            TranscriptionLanguagePicker(title: "Transcription language", selection: $controller.recordingLanguage)
                .disabled(controller.activity == .starting)
            CalendarRecordingPicker(calendar: calendar, canChoose: controller.activity == .idle)
                .disabled(controller.activity == .starting)
            Text("Starting requests microphone and screen/system-audio access. Wear headphones to keep microphone and system audio separate.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if controller.activity == .starting {
                ProgressView("Starting recording…").controlSize(.small)
            }
            if let message = controller.message {
                Text(message).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if controller.permissionIssue != nil {
                Button("Quit & Open Privacy Settings") { controller.openPermissionSettingsAfterQuit() }
                    .disabled(controller.activity != .idle)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    controller.showingRecordingSetup = false
                    if controller.permissionIssue == nil { controller.message = nil }
                }
                .keyboardShortcut(.cancelAction)
                .disabled(controller.activity == .starting)
                Button("Start Recording") { controller.record() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!controller.canRecord)
            }
        }
        .padding(24)
        .frame(width: 610)
    }
}
