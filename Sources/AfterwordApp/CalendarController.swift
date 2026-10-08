import AfterwordCore
import Combine
import Foundation

protocol CalendarAuthenticating: CalendarAccessTokenProviding {
    func restore() async throws -> GoogleCalendarAuthStatus
    func importClientConfiguration(_ data: Data) async throws
    func connect(openBrowser: @escaping @MainActor @Sendable (URL) async -> Bool) async throws
    func cancelConnect() async
    func disconnect() async throws
}

extension GoogleCalendarAuth: CalendarAuthenticating {}

enum RecordingCalendarChoice: Hashable {
    case automatic, none, event(String)
}

struct RecordingCalendarSelection: Equatable {
    let event: CalendarEvent
    let fetchedAt: Date
}

@MainActor
final class CalendarController: ObservableObject {
    @Published private(set) var authStatus: GoogleCalendarAuthStatus = .unconfigured
    @Published private(set) var connectionBusy = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var calendars: [CalendarInfo] = []
    @Published private(set) var selectedCalendarID: String?
    @Published private(set) var window: CalendarEventWindow?
    @Published var choice: RecordingCalendarChoice = .automatic
    @Published private(set) var message: String?
    @Published private(set) var snapshotVersion = 0
    @Published private(set) var historyWindow: CalendarEventWindow?
    @Published private(set) var historyLoading = false
    @Published private(set) var historyMessage: String?
    private let auth: any CalendarAuthenticating
    private let reader: any CalendarReading
    private let eventStore: CalendarEventStore
    private let now: () -> Date
    private var restored = false
    private var connectionGeneration = 0
    private var refreshID = UUID()
    private var historyID = UUID()
    private var refreshTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var connectionUnavailable = false
    private var lastRefreshAttempt: Date?

    init(store: MeetingStore, auth: any CalendarAuthenticating = GoogleCalendarAuth(),
         reader: (any CalendarReading)? = nil, now: @escaping () -> Date = { Date() }) {
        self.auth = auth
        self.reader = reader ?? GoogleCalendarClient(tokenProvider: auth)
        eventStore = CalendarEventStore(store: store)
        self.now = now
    }

    var isConnected: Bool { authStatus == .connected && !connectionUnavailable }
    var events: [CalendarEvent] { window?.events ?? [] }
    var selectedCalendar: CalendarInfo? { calendars.first { $0.id == selectedCalendarID } }

    func restore() async {
        guard !restored else { return }
        restored = true
        let generation = resetConnectionView()
        do {
            let status = try await auth.restore()
            guard generation == connectionGeneration else { return }
            authStatus = status
            connectionUnavailable = false
            connectionBusy = false
            if status == .connected { refresh() }
        } catch { await finishConnection(error, generation: generation, restoreExisting: false) }
    }

    func importConfiguration(_ data: Data) async {
        guard !connectionBusy else { return }
        let generation = resetConnectionView()
        do {
            try await auth.importClientConfiguration(data)
            let status = try await auth.restore()
            guard generation == connectionGeneration else { return }
            authStatus = status
            connectionUnavailable = false
            connectionBusy = false
            message = "Setup imported. Sign in to Google Calendar to continue."
        } catch { await finishConnection(error, generation: generation, restoreExisting: true) }
    }

    func connect(openBrowser: @escaping @MainActor @Sendable (URL) async -> Bool) async {
        guard !connectionBusy else { return }
        let generation = resetConnectionView()
        do {
            try await auth.connect(openBrowser: openBrowser)
            guard generation == connectionGeneration else { return }
            authStatus = .connected
            connectionUnavailable = false
            connectionBusy = false
            refresh()
        } catch { await finishConnection(error, generation: generation, restoreExisting: true) }
    }

    func cancelConnection() async {
        let generation = resetConnectionView()
        await auth.cancelConnect()
        guard generation == connectionGeneration else { return }
        await restoreConnection(generation: generation, explanation: "Sign-in cancelled. Recording is still available.")
    }

    func disconnect() async {
        let generation = resetConnectionView()
        connectionUnavailable = true
        await auth.cancelConnect()
        do {
            try await auth.disconnect()
            guard generation == connectionGeneration else { return }
            authStatus = .disconnected
            connectionBusy = false
            message = "Disconnected on this Mac. Saved meeting context is retained."
        } catch { await finishConnection(error, generation: generation, restoreExisting: false) }
    }

    func refresh() {
        guard isConnected, !connectionBusy else { return }
        lastRefreshAttempt = now()
        refreshTask?.cancel()
        let request = UUID()
        refreshID = request
        let generation = connectionGeneration
        isRefreshing = true
        message = nil
        refreshTask = Task {
            do {
                let available = try await reader.calendars()
                try Task.checkCancellation()
                guard generation == connectionGeneration, request == refreshID else { return }
                calendars = available
                if !available.contains(where: { $0.id == selectedCalendarID }) {
                    selectedCalendarID = available.first(where: { $0.isPrimary == true })?.id ?? available.first?.id
                    if case .event = choice { choice = .automatic }
                }
                guard let calendar = selectedCalendar else {
                    window = nil
                    isRefreshing = false
                    message = "No readable calendars were found. Recording is still available."
                    return
                }
                let bounds = Self.day(containing: now())
                let fetched = try await reader.events(calendar: calendar, from: bounds.start, to: bounds.end)
                try fetched.validate()
                try Task.checkCancellation()
                guard generation == connectionGeneration, request == refreshID,
                      selectedCalendarID == calendar.id else { return }
                window = fetched
                isRefreshing = false
            } catch {
                guard generation == connectionGeneration, request == refreshID else { return }
                isRefreshing = false
                if !(error is CancellationError) { readFailed(error, historical: false) }
            }
        }
    }

    func refreshIfNeeded() {
        guard isConnected, !connectionBusy, !isRefreshing else { return }
        let date = now()
        if let lastRefreshAttempt, date.timeIntervalSince(lastRefreshAttempt) >= 0,
           date.timeIntervalSince(lastRefreshAttempt) < 60 { return }
        if let window {
            let age = date.timeIntervalSince(window.fetchedAt)
            guard age < 0 || age >= 240 || date < window.queryStart || date >= window.queryEnd else { return }
        }
        refresh()
    }

    func selectCalendar(_ id: String) {
        guard calendars.contains(where: { $0.id == id }), id != selectedCalendarID else { return }
        selectedCalendarID = id
        window = nil
        if case .event = choice { choice = .automatic }
        cancelHistory()
        refresh()
    }

    func recordingSelection() -> RecordingCalendarSelection? {
        guard isConnected, !connectionBusy, let window else { return nil }
        let event: CalendarEvent?
        switch choice {
        case .none: event = nil
        case .automatic:
            if case .unique(let match) = CalendarEventMatcher.match(window: window, at: now()) { event = match }
            else { event = nil }
        case .event(let id): event = window.events.first { $0.id == id }
        }
        return event.map { RecordingCalendarSelection(event: $0, fetchedAt: window.fetchedAt) }
    }

    var selectionDescription: String {
        if let selection = recordingSelection() {
            let title = "New recording: \(selection.event.displayTitle)"
            if case .event = choice, case .stale = CalendarEventMatcher.match(window: window, at: now()) {
                return title + ". Using saved calendar details; refresh to check for changes."
            }
            return title
        }
        switch choice {
        case .none: return "This recording will have no calendar event."
        case .event: return "The selected event is unavailable. Choose an event or record without one."
        case .automatic:
            switch CalendarEventMatcher.match(window: window, at: now()) {
            case .ambiguous: return "More than one meeting is in progress. Choose an event to link it."
            case .stale: return "Refresh to match the current meeting, or record without calendar context."
            default: return "No current meeting matched. You can still start a new recording."
            }
        }
    }

    func recordingStarted(meetingID: String, selection: RecordingCalendarSelection?) {
        if case .event = choice { choice = .automatic }
        guard let selection else { return }
        do {
            try save(selection, meetingID: meetingID)
        } catch { message = "Recording started, but calendar context could not be saved: \(error.localizedDescription)" }
    }

    func snapshot(meetingID: String) throws -> CalendarEventSnapshot? { try eventStore.read(meetingID: meetingID) }

    func save(_ selection: RecordingCalendarSelection, meetingID: String) throws {
        try eventStore.save(CalendarEventSnapshot(meetingID: meetingID, event: selection.event,
                                                  fetchedAt: selection.fetchedAt, linkedAt: now()))
        snapshotVersion += 1
    }

    func unlink(meetingID: String) throws {
        try eventStore.unlink(meetingID: meetingID)
        snapshotVersion += 1
    }

    func findEvents(on date: Date) {
        cancelHistory()
        guard isConnected, let calendar = selectedCalendar else {
            historyMessage = "Connect Google Calendar and select a calendar first."
            return
        }
        let request = historyID
        let generation = connectionGeneration
        historyLoading = true
        historyTask = Task {
            do {
                let bounds = Self.day(containing: date)
                let result = try await reader.events(calendar: calendar, from: bounds.start, to: bounds.end)
                try result.validate()
                try Task.checkCancellation()
                guard request == historyID, generation == connectionGeneration, selectedCalendarID == calendar.id else { return }
                historyWindow = result
                historyLoading = false
            } catch {
                guard request == historyID, generation == connectionGeneration else { return }
                historyLoading = false
                if !(error is CancellationError) { readFailed(error, historical: true) }
            }
        }
    }

    func cancelHistory() {
        historyTask?.cancel()
        historyTask = nil
        historyID = UUID()
        historyWindow = nil
        historyMessage = nil
        historyLoading = false
    }

    private func resetConnectionView() -> Int {
        connectionGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshID = UUID()
        cancelHistory()
        calendars = []
        selectedCalendarID = nil
        window = nil
        if case .event = choice { choice = .automatic }
        isRefreshing = false
        lastRefreshAttempt = nil
        connectionBusy = true
        message = nil
        return connectionGeneration
    }

    private func finishConnection(_ error: Error, generation: Int, restoreExisting: Bool) async {
        guard generation == connectionGeneration else { return }
        if restoreExisting {
            await restoreConnection(generation: generation, explanation: error.localizedDescription)
            return
        }
        connectionBusy = false
        message = error.localizedDescription
    }

    private func restoreConnection(generation: Int, explanation: String) async {
        do {
            let status = try await auth.restore()
            guard generation == connectionGeneration else { return }
            authStatus = status
            connectionUnavailable = false
            connectionBusy = false
            if status == .connected { refresh() }
            message = explanation
        } catch {
            guard generation == connectionGeneration else { return }
            connectionBusy = false
            connectionUnavailable = true
            message = explanation + " " + error.localizedDescription
        }
    }

    private func readFailed(_ error: Error, historical: Bool) {
        let requiresSignIn: Bool
        if error is CalendarCredentialStoreError {
            requiresSignIn = true
        } else if let readError = error as? CalendarReadError, case .signInRequired = readError {
            requiresSignIn = true
        } else if let authError = error as? GoogleCalendarAuthError {
            requiresSignIn = [.reconnectRequired, .notConnected, .insufficientScopes, .invalidStoredCredentials].contains(authError)
        } else { requiresSignIn = false }
        if requiresSignIn {
            _ = resetConnectionView()
            authStatus = .disconnected
            connectionUnavailable = true
            connectionBusy = false
            message = error.localizedDescription + " Reconnect Google Calendar to refresh events."
            if historical { historyMessage = message }
        } else if historical {
            historyMessage = error.localizedDescription
        } else {
            message = error.localizedDescription + (window == nil ? "" : " Showing saved calendar details; updates are unavailable.")
        }
    }

    private static func day(containing date: Date) -> DateInterval {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: date)
        return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
    }
}
