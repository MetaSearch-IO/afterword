import AfterwordCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CalendarRecordingPicker: View {
    @ObservedObject var calendar: CalendarController
    let canChoose: Bool
    @State private var showSetup = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if calendar.connectionBusy {
                HStack {
                    ProgressView("Connecting Google Calendar…").controlSize(.small)
                    Button("Cancel") { Task { await calendar.cancelConnection() } }
                }
                Text("Recording remains available.").font(.caption).foregroundStyle(.secondary)
            } else if calendar.isConnected {
                DisclosureGroup("Google Calendar", isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            calendarPicker(calendar)
                            Button("Refresh") { calendar.refresh() }.disabled(calendar.isRefreshing)
                            Button("Disconnect") { Task { await calendar.disconnect() } }
                        }
                        Picker("New recording", selection: $calendar.choice) {
                            Text("Automatic (current meeting)").tag(RecordingCalendarChoice.automatic)
                            Text("No calendar event").tag(RecordingCalendarChoice.none)
                            ForEach(calendar.events) { event in
                                Text("\(CalendarPresentation.time(event)) · \(event.displayTitle)")
                                    .tag(RecordingCalendarChoice.event(event.id))
                            }
                        }.disabled(!canChoose)
                        if calendar.isRefreshing { ProgressView("Refreshing calendar…").controlSize(.small) }
                        Button("Calendar setup…") { showSetup = true }.font(.caption)
                    }.padding(.top, 6)
                }
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(calendar.selectionDescription).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack {
                    Button(calendar.authStatus == .disconnected ? "Reconnect Google Calendar" : "Connect Google Calendar") { connect() }
                    Text("Optional · Recording works without a calendar")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if calendar.authStatus == .keychainLocked {
                    Text("Unlock your Mac, then connect to allow access to the saved calendar sign-in.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let message = calendar.message {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .sheet(isPresented: $showSetup) { CalendarSetupSheet(calendar: calendar) }
    }

    private func connect() {
        if calendar.authStatus == .unconfigured { showSetup = true }
        else { Task { await calendar.connect(openBrowser: CalendarPresentation.openBrowser) } }
    }
}

@MainActor
private func calendarPicker(_ calendar: CalendarController) -> some View {
    Picker("Calendar", selection: Binding(get: { calendar.selectedCalendarID ?? "" },
                                          set: { calendar.selectCalendar($0) })) {
        ForEach(calendar.calendars) { item in Text(item.title).tag(item.id) }
    }
}

struct CalendarSetupSheet: View {
    @ObservedObject var calendar: CalendarController
    @Environment(\.dismiss) private var dismiss
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect Google Calendar").font(.title2.bold())
            Text("Afterword needs its own Google sign-in. A Google connection in ChatGPT or Codex is separate.")
                .fixedSize(horizontal: false, vertical: true)
            Text("For this development build, create a one-time Google setup file:")
            VStack(alignment: .leading, spacing: 8) {
                Text("1. In Google Cloud, create or select a project and enable the Google Calendar API.")
                Text("2. Configure the Google Auth consent screen. If the app is in Testing, add your Google account as a test user under Audience.")
                Text("3. Create an OAuth client with application type Desktop app, download its JSON file, and import it below.")
            }.fixedSize(horizontal: false, vertical: true)
            Link("Open Google's desktop app setup guide", destination: URL(string: "https://developers.google.com/workspace/calendar/api/quickstart/python#authorize_credentials_for_a_desktop_application")!)
            Text("The file is imported locally. After sign-in, credentials are stored in macOS Keychain. Afterword requests read-only access to calendar events and your calendar list; it never starts a recording automatically.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = importError ?? calendar.message { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Button("Import Google Setup File…") { importFile() }
                    .buttonStyle(.borderedProminent).disabled(calendar.connectionBusy)
                if calendar.authStatus != .unconfigured && !calendar.isConnected {
                    Button("Sign In to Google") { Task { await calendar.connect(openBrowser: CalendarPresentation.openBrowser) } }
                        .disabled(calendar.connectionBusy)
                }
                if calendar.connectionBusy {
                    ProgressView().controlSize(.small)
                    Button("Cancel Sign-In") { Task { await calendar.cancelConnection() } }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 610)
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                guard size <= 131_072 else { throw GoogleCalendarAuthError.invalidConfiguration }
                let data = try Data(contentsOf: url)
                guard data.count <= 131_072 else { throw GoogleCalendarAuthError.invalidConfiguration }
                importError = nil
                Task { await calendar.importConfiguration(data) }
            } catch { importError = error.localizedDescription }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
}

struct CalendarMeetingDetails: View {
    let meeting: Meeting
    @ObservedObject var controller: MeetingController
    @ObservedObject var calendar: CalendarController
    @State private var snapshot: CalendarEventSnapshot?
    @State private var error: String?
    @State private var showLink = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let snapshot { Label(snapshot.event.displayTitle, systemImage: "calendar") }
                Button(snapshot == nil ? "Find Calendar Event…" : "Change Calendar Event…") { showLink = true }
                    .disabled(meeting.captureState.isActive || controller.isLoading)
                if snapshot != nil {
                    Button("Unlink") {
                        do { try calendar.unlink(meetingID: meeting.id); error = nil }
                        catch { self.error = error.localizedDescription }
                    }.disabled(meeting.captureState.isActive)
                }
            }
            if let snapshot {
                Text(CalendarPresentation.time(snapshot.event, includeDate: true)).font(.caption).foregroundStyle(.secondary)
                if let organizer = snapshot.event.organizer {
                    Text("Organizer: \(organizer.displayLabel)").font(.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let location = snapshot.event.location, !location.isEmpty {
                    Text("Location: \(location)").font(.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if let url = snapshot.event.joinURL, CalendarEvent.safeLink(url) { Link("Join Meeting", destination: url) }
                    if let url = snapshot.event.htmlLink, CalendarEvent.safeLink(url) { Link("Open in Google Calendar", destination: url) }
                }
                if let description = snapshot.event.description, !description.isEmpty {
                    DisclosureGroup("Event description") {
                        Text(description).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                DisclosureGroup("Calendar invitees (\(snapshot.event.attendees.count))") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Invited people are not verified attendees or identified speakers.")
                            .font(.caption).foregroundStyle(.secondary)
                        if snapshot.event.inviteeListMayBeIncomplete {
                            Text("Google did not provide a complete guest list.").font(.caption).foregroundStyle(.secondary)
                        }
                        if snapshot.event.attendees.isEmpty { Text("No invitee details are available.").font(.caption) }
                        ForEach(Array(snapshot.event.attendees.enumerated()), id: \.offset) { _, person in
                            HStack {
                                Text(person.displayLabel).textSelection(.enabled)
                                if person.isResource { Text("Resource").foregroundStyle(.secondary) }
                                if let status = person.responseStatus { Text(status).foregroundStyle(.secondary) }
                            }.font(.callout)
                        }
                    }.padding(.top, 4)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }
        .task(id: "\(meeting.id)/\(calendar.snapshotVersion)") {
            do { snapshot = try calendar.snapshot(meetingID: meeting.id); error = nil }
            catch { snapshot = nil; self.error = error.localizedDescription }
        }
        .sheet(isPresented: $showLink) { CalendarLinkSheet(meeting: meeting, controller: controller, calendar: calendar) }
    }
}

private struct CalendarLinkSheet: View {
    let meeting: Meeting
    @ObservedObject var controller: MeetingController
    @ObservedObject var calendar: CalendarController
    @Environment(\.dismiss) private var dismiss
    @State private var selectedEventID: String?
    @State private var useEventTitle = false
    @State private var explicitTitleChoice = false
    @State private var saving = false
    @State private var error: String?
    private var recordedAt: Date? { ISO8601DateFormatter().date(from: meeting.startedAt) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Link a calendar event").font(.title2.bold())
            Text(meeting.title).font(.headline)
            if let recordedAt { Text("Recorded \(recordedAt.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary) }
            if calendar.isConnected {
                HStack {
                    calendarPicker(calendar)
                    Button("Refresh") { fetch() }.disabled(calendar.historyLoading)
                }
                if calendar.historyLoading { ProgressView("Finding events on the recording date…") }
                List(selection: $selectedEventID) {
                    ForEach(calendar.historyWindow?.events ?? []) { event in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.displayTitle)
                            Text(CalendarPresentation.time(event)).font(.caption).foregroundStyle(.secondary)
                        }.tag(event.id)
                    }
                }.frame(height: 210)
                if calendar.historyWindow?.events.isEmpty == true { Text("No events found on this date in this calendar.").foregroundStyle(.secondary) }
                Toggle("Use event title as meeting name", isOn: Binding(get: { useEventTitle }, set: {
                    useEventTitle = $0
                    explicitTitleChoice = true
                }))
                Text("Only this meeting's calendar context is saved. Google Calendar is not changed.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                CalendarRecordingPicker(calendar: calendar, canChoose: false)
            }
            if let message = error ?? calendar.historyMessage { Text(message).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Link Event") { link() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedEventID == nil || saving || calendar.historyLoading)
            }
        }
        .padding(24).frame(width: 600)
        .onAppear { useEventTitle = meeting.title == "Meeting"; fetch() }
        .onChange(of: calendar.selectedCalendarID) { _, _ in fetch() }
        .onDisappear { calendar.cancelHistory() }
    }

    private func fetch() {
        selectedEventID = nil
        guard let recordedAt else { error = "The saved recording date is invalid."; return }
        calendar.findEvents(on: recordedAt)
    }

    private func link() {
        guard let window = calendar.historyWindow,
              let event = window.events.first(where: { $0.id == selectedEventID }) else { return }
        saving = true
        Task {
            do {
                try await controller.linkCalendarEvent(RecordingCalendarSelection(event: event, fetchedAt: window.fetchedAt),
                    meetingID: meeting.id, useEventTitle: useEventTitle, explicitlyReplaceTitle: explicitTitleChoice && useEventTitle)
                dismiss()
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}

enum CalendarPresentation {
    @MainActor
    static func openBrowser(_ url: URL) async -> Bool { NSWorkspace.shared.open(url) }

    static func time(_ event: CalendarEvent, includeDate: Bool = false) -> String {
        switch event.time {
        case .timed(let start, let end):
            let first = start.formatted(date: includeDate ? .abbreviated : .omitted, time: .shortened)
            return "\(first)–\(end.formatted(date: .omitted, time: .shortened))"
        case .allDay(let start, _): return includeDate ? "\(start) · All day" : "All day"
        }
    }
}
