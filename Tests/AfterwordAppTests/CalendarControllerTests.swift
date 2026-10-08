import AfterwordCore
import Foundation
import XCTest
@testable import AfterwordApp

private actor CalendarAuthFixture: CalendarAuthenticating {
    private(set) var restoreCount = 0
    var status: GoogleCalendarAuthStatus = .connected
    var connectError: GoogleCalendarAuthError?
    func restore() async throws -> GoogleCalendarAuthStatus { restoreCount += 1; return status }
    func importClientConfiguration(_ data: Data) async throws { status = .disconnected }
    func connect(openBrowser: @escaping @MainActor @Sendable (URL) async -> Bool) async throws {
        if let connectError { throw connectError }
        status = .connected
    }
    func cancelConnect() async {}
    func disconnect() async throws { status = .disconnected }
    func accessToken(forceRefresh: Bool) async throws -> String { throw GoogleCalendarAuthError.notConnected }
    func failConnect() { connectError = .permissionDenied }
}

private actor CalendarReaderFixture: CalendarReading {
    let calendar = CalendarInfo(providerID: .google, id: "calendar@example.test", title: "Test Calendar", isPrimary: true)
    let date: Date
    var returnedEvents: [CalendarEvent]
    var holdEvents = false
    var eventError: (any Error)?
    private var pending: [CheckedContinuation<Void, Never>] = []
    private(set) var eventCalls = 0

    init(date: Date, events: [CalendarEvent]) { self.date = date; returnedEvents = events }
    func calendars() async throws -> [CalendarInfo] { [calendar] }
    func events(calendar: CalendarInfo, from start: Date, to end: Date) async throws -> CalendarEventWindow {
        eventCalls += 1
        if holdEvents { await withCheckedContinuation { pending.append($0) } }
        if let eventError { throw eventError }
        return CalendarEventWindow(providerID: .google, calendarID: calendar.id, queryStart: start, queryEnd: end,
                                   fetchedAt: date, events: returnedEvents)
    }
    func setHold(_ value: Bool) { holdEvents = value }
    func failEvents(_ error: any Error) { eventError = error }
    func release() { let saved = pending; pending = []; saved.forEach { $0.resume() } }
}

final class CalendarControllerTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_791_000_000)

    private func fixture() throws -> (URL, MeetingStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("afterword-calendar-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, MeetingStore(rootURL: directory.appendingPathComponent("meetings")))
    }

    private func event(_ id: String = "one", title: String = "需求讨论") -> CalendarEvent {
        CalendarEvent(providerID: .google, calendarID: "calendar@example.test", eventID: id, title: title,
                      time: .timed(start: date.addingTimeInterval(-60), end: date.addingTimeInterval(600)),
                      attendees: [CalendarAttendee(displayName: "Yu Hu")])
    }

    @MainActor
    private func waitFor(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }

    @MainActor
    func testInitializationDoesNotReadCredentialsAndUnavailableCalendarDoesNotBlockRecord() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auth = CalendarAuthFixture()
        let reader = CalendarReaderFixture(date: date, events: [])
        let calendar = CalendarController(store: store, auth: auth, reader: reader)
        let controller = MeetingController(rootURL: store.rootURL, calendarController: calendar,
                                           requestMicrophoneAccess: { false })
        try await waitFor { !controller.isLoading }
        let count = await auth.restoreCount
        XCTAssertEqual(count, 0)
        XCTAssertTrue(controller.canRecord)
        XCTAssertNil(calendar.recordingSelection())
        XCTAssertEqual(controller.activity.rawValue, "Ready to record")
    }

    @MainActor
    func testAutomaticRequiresFreshUniqueCurrentEventAndNonePersists() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var currentDate = date
        let selected = event()
        let calendar = CalendarController(store: store, auth: CalendarAuthFixture(),
            reader: CalendarReaderFixture(date: date, events: [selected]), now: { currentDate })
        await calendar.restore()
        try await waitFor { !calendar.isRefreshing }
        XCTAssertEqual(calendar.recordingSelection()?.event, selected)
        currentDate = date.addingTimeInterval(301)
        XCTAssertNil(calendar.recordingSelection())
        calendar.choice = .event(selected.id)
        XCTAssertEqual(calendar.recordingSelection()?.event, selected)
        XCTAssertTrue(calendar.selectionDescription.contains("saved calendar details"))
        calendar.choice = .none
        await calendar.disconnect()
        XCTAssertEqual(calendar.choice, .none)
        XCTAssertNil(calendar.recordingSelection())
    }

    @MainActor
    func testAmbiguousAutomaticEventsDoNotPickAnInvite() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calendar = CalendarController(store: store, auth: CalendarAuthFixture(),
            reader: CalendarReaderFixture(date: date, events: [event(), event("two")]), now: { self.date })
        await calendar.restore()
        try await waitFor { !calendar.isRefreshing }
        XCTAssertNil(calendar.recordingSelection())
        XCTAssertTrue(calendar.selectionDescription.contains("More than one"))
    }

    @MainActor
    func testRecordingSelectionIsFrozenAndSnapshotFailureIsNonfatal() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let selected = event()
        let calendar = CalendarController(store: store, auth: CalendarAuthFixture(),
            reader: CalendarReaderFixture(date: date, events: [selected]), now: { self.date })
        await calendar.restore()
        try await waitFor { !calendar.isRefreshing }
        calendar.choice = .event(selected.id)
        let frozen = try XCTUnwrap(calendar.recordingSelection())
        calendar.choice = .none
        let meeting = try store.create(title: frozen.event.suggestedMeetingTitle!)
        calendar.recordingStarted(meetingID: meeting.id, selection: frozen)
        XCTAssertEqual(try calendar.snapshot(meetingID: meeting.id)?.event, selected)
        XCTAssertEqual(calendar.choice, .none)
        calendar.recordingStarted(meetingID: "missing-meeting", selection: frozen)
        XCTAssertTrue(calendar.message?.contains("Recording started") == true)
    }

    @MainActor
    func testDisconnectInvalidatesLateCurrentAndHistoricalFetches() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = CalendarReaderFixture(date: date, events: [event()])
        let calendar = CalendarController(store: store, auth: CalendarAuthFixture(), reader: reader, now: { self.date })
        await calendar.restore()
        try await waitFor { !calendar.isRefreshing }
        await reader.setHold(true)
        calendar.refresh()
        calendar.findEvents(on: date.addingTimeInterval(-86_400))
        let deadline = Date().addingTimeInterval(3)
        while await reader.eventCalls < 3, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let count = await reader.eventCalls
        XCTAssertEqual(count, 3)
        await calendar.disconnect()
        await reader.release()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(calendar.isConnected)
        XCTAssertTrue(calendar.calendars.isEmpty)
        XCTAssertNil(calendar.window)
        XCTAssertNil(calendar.historyWindow)
        XCTAssertNil(calendar.recordingSelection())
    }

    @MainActor
    func testHistoricalLinkPreservesManualTitleUnlessExplicitlyReplaced() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var meeting = try store.create(title: "My title")
        meeting.captureState = .stopped
        try store.save(meeting)
        let calendar = CalendarController(store: store, auth: CalendarAuthFixture(),
            reader: CalendarReaderFixture(date: date, events: []))
        let controller = MeetingController(rootURL: store.rootURL, calendarController: calendar)
        try await waitFor { !controller.isLoading }
        let selection = RecordingCalendarSelection(event: event(), fetchedAt: date)
        try await controller.linkCalendarEvent(selection, meetingID: meeting.id, useEventTitle: true)
        XCTAssertEqual(try store.load(id: meeting.id).title, "My title")
        XCTAssertEqual(try calendar.snapshot(meetingID: meeting.id)?.event, selection.event)
        try await controller.linkCalendarEvent(selection, meetingID: meeting.id, useEventTitle: true, explicitlyReplaceTitle: true)
        XCTAssertEqual(try store.load(id: meeting.id).title, "需求讨论")
        try calendar.unlink(meetingID: meeting.id)
        XCTAssertNil(try calendar.snapshot(meetingID: meeting.id))
        XCTAssertEqual(try store.load(id: meeting.id).title, "需求讨论")
    }

    @MainActor
    func testBackgroundRefreshWaitsForTTLAndDoesNotDuplicateRequests() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var currentDate = date
        let reader = CalendarReaderFixture(date: date, events: [event()])
        let calendar = CalendarController(store: store, auth: CalendarAuthFixture(), reader: reader, now: { currentDate })
        await calendar.restore()
        try await waitFor { !calendar.isRefreshing }
        currentDate = date.addingTimeInterval(239)
        calendar.refreshIfNeeded()
        var calls = await reader.eventCalls
        XCTAssertEqual(calls, 1)
        currentDate = date.addingTimeInterval(240)
        calendar.refreshIfNeeded()
        calendar.refreshIfNeeded()
        try await waitFor { !calendar.isRefreshing }
        calls = await reader.eventCalls
        XCTAssertEqual(calls, 2)
        currentDate = date.addingTimeInterval(299)
        calendar.refreshIfNeeded()
        calls = await reader.eventCalls
        XCTAssertEqual(calls, 2)
    }

    @MainActor
    func testExpiredOrUnavailableCredentialsClearContextForCurrentAndHistoricalReads() async throws {
        let errors: [any Error] = [CalendarReadError.signInRequired, CalendarCredentialStoreError.locked,
                                   CalendarCredentialStoreError.unavailable(-25291)]
        for (historical, failure) in [false, true].flatMap({ historical in errors.map { (historical, $0) } }) {
            let (directory, store) = try fixture()
            defer { try? FileManager.default.removeItem(at: directory) }
            let reader = CalendarReaderFixture(date: date, events: [event()])
            let calendar = CalendarController(store: store, auth: CalendarAuthFixture(), reader: reader, now: { self.date })
            await calendar.restore()
            try await waitFor { !calendar.isRefreshing }
            let meeting = try store.create(title: "Saved context")
            let selected = try XCTUnwrap(calendar.recordingSelection())
            try calendar.save(selected, meetingID: meeting.id)
            await reader.failEvents(failure)
            if historical { calendar.findEvents(on: date) } else { calendar.refresh() }
            try await waitFor { !calendar.isRefreshing && !calendar.historyLoading }
            XCTAssertEqual(calendar.authStatus, .disconnected)
            XCTAssertFalse(calendar.isConnected)
            XCTAssertNil(calendar.window)
            XCTAssertNil(calendar.historyWindow)
            XCTAssertTrue(calendar.calendars.isEmpty)
            XCTAssertNil(calendar.recordingSelection())
            XCTAssertTrue(calendar.message?.contains("Reconnect") == true)
            XCTAssertTrue(calendar.message?.contains(failure.localizedDescription) == true)
            XCTAssertEqual(try calendar.snapshot(meetingID: meeting.id)?.event, selected.event)
        }
    }

    @MainActor
    func testCancelledOrFailedSignInRestoresExistingConnectedCalendar() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auth = CalendarAuthFixture()
        let calendar = CalendarController(store: store, auth: auth,
            reader: CalendarReaderFixture(date: date, events: [event()]), now: { self.date })
        await calendar.restore()
        try await waitFor { !calendar.isRefreshing }
        await calendar.cancelConnection()
        try await waitFor { !calendar.isRefreshing }
        XCTAssertTrue(calendar.isConnected)
        XCTAssertEqual(calendar.events.count, 1)
        await auth.failConnect()
        await calendar.connect(openBrowser: { _ in false })
        try await waitFor { !calendar.isRefreshing }
        XCTAssertTrue(calendar.isConnected)
        XCTAssertEqual(calendar.events.count, 1)
        XCTAssertNotNil(calendar.recordingSelection())
        XCTAssertTrue(calendar.message?.contains("not granted") == true)
    }
}
