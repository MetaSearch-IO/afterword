import AfterwordCore
import Darwin
import XCTest
@testable import AfterwordApp

final class CalendarDataTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ id: String = "event", start: TimeInterval = -60, end: TimeInterval = 60,
                       status: String = "confirmed", attendees: [CalendarAttendee] = []) -> CalendarEvent {
        CalendarEvent(providerID: .google, calendarID: "person@example.test", eventID: id, title: "讨论 meeting",
                      time: .timed(start: now.addingTimeInterval(start), end: now.addingTimeInterval(end)), status: status,
                      attendees: attendees)
    }

    private func window(_ events: [CalendarEvent], fetchedAt: Date? = nil) -> CalendarEventWindow {
        CalendarEventWindow(providerID: .google, calendarID: "person@example.test",
            queryStart: now.addingTimeInterval(-3_600), queryEnd: now.addingTimeInterval(3_600),
            fetchedAt: fetchedAt ?? now, events: events)
    }

    func testMatchingRequiresUniqueFreshOngoingEligibleEvent() {
        let ongoing = event()
        XCTAssertEqual(CalendarEventMatcher.match(window: nil, at: now), .none)
        XCTAssertEqual(CalendarEventMatcher.match(window: window([]), at: now), .none)
        XCTAssertEqual(CalendarEventMatcher.match(window: window([ongoing]), at: now), .unique(ongoing))
        XCTAssertEqual(CalendarEventMatcher.match(window: window([event(start: 0)]), at: now), .unique(event(start: 0)))
        XCTAssertEqual(CalendarEventMatcher.match(window: window([event(end: 0)]), at: now), .none)
        XCTAssertEqual(CalendarEventMatcher.match(window: window([event(status: "cancelled")]), at: now), .none)
        XCTAssertEqual(CalendarEventMatcher.match(window: window([event(status: "future-unknown-status")]), at: now), .none)
        let declined = event(attendees: [CalendarAttendee(responseStatus: "declined", isSelf: true)])
        XCTAssertEqual(CalendarEventMatcher.match(window: window([declined]), at: now), .none)
        let otherDeclined = event(attendees: [CalendarAttendee(responseStatus: "declined")])
        XCTAssertEqual(CalendarEventMatcher.match(window: window([otherDeclined]), at: now), .unique(otherDeclined))
        let allDay = CalendarEvent(providerID: .google, calendarID: "person@example.test", eventID: "all-day",
                                  time: .allDay(startDate: "2026-10-08", endDateExclusive: "2026-10-09"))
        XCTAssertEqual(CalendarEventMatcher.match(window: window([allDay]), at: now), .none)
        guard case let .ambiguous(matches) = CalendarEventMatcher.match(window: window([ongoing, event("second")]), at: now) else {
            return XCTFail("Overlapping meetings must require an explicit choice.")
        }
        XCTAssertEqual(Set(matches.map(\.eventID)), ["event", "second"])
    }

    func testMatchingRejectsStaleFutureOutOfWindowAndIncompleteIdentityData() {
        let ongoing = event()
        XCTAssertEqual(CalendarEventMatcher.match(window: window([ongoing], fetchedAt: now.addingTimeInterval(-300)), at: now), .unique(ongoing))
        for age in [-301.0, 1.0] {
            XCTAssertEqual(CalendarEventMatcher.match(window: window([ongoing], fetchedAt: now.addingTimeInterval(age)), at: now), .stale)
        }
        let uncovered = CalendarEventWindow(providerID: .google, calendarID: "person@example.test",
            queryStart: now.addingTimeInterval(1), queryEnd: now.addingTimeInterval(120), fetchedAt: now, events: [ongoing])
        XCTAssertEqual(CalendarEventMatcher.match(window: uncovered, at: now), .stale)
        XCTAssertEqual(CalendarEventMatcher.match(window: window([ongoing, ongoing]), at: now), .stale)
        let wrongCalendar = CalendarEvent(providerID: .google, calendarID: "other@example.test", eventID: "other",
                                          time: ongoing.time)
        XCTAssertEqual(CalendarEventMatcher.match(window: window([wrongCalendar]), at: now), .stale)
        XCTAssertEqual(CalendarEventMatcher.match(window: window([event(end: -120)]), at: now), .stale)
    }

    func testOccurrenceIdentityAndDSTUseAbsoluteInstants() throws {
        let parser = ISO8601DateFormatter()
        let first = try XCTUnwrap(parser.date(from: "2026-11-01T01:30:00-07:00"))
        let second = try XCTUnwrap(parser.date(from: "2026-11-01T01:30:00-08:00"))
        XCTAssertEqual(second.timeIntervalSince(first), 3_600)
        let early = CalendarEvent(providerID: .google, calendarID: "person@example.test", eventID: "series",
            time: .timed(start: first, end: second), timeZoneID: "America/Los_Angeles", recurringEventID: "master",
            originalStartTime: "2026-11-01T01:30:00-07:00")
        let late = CalendarEvent(providerID: .google, calendarID: "person@example.test", eventID: "series",
            time: .timed(start: second, end: second.addingTimeInterval(3_600)), timeZoneID: "America/Los_Angeles", recurringEventID: "master",
            originalStartTime: "2026-11-01T01:30:00-08:00")
        XCTAssertNotEqual(early.id, late.id)
        let snapshot = CalendarEventWindow(providerID: .google, calendarID: "person@example.test",
            queryStart: first, queryEnd: second.addingTimeInterval(7_200), fetchedAt: second, events: [early, late])
        XCTAssertEqual(CalendarEventMatcher.match(window: snapshot, at: second), .unique(late))
        let anotherCalendar = CalendarEvent(providerID: .google, calendarID: "other@example.test", eventID: "series", time: early.time,
                                           originalStartTime: early.originalStartTime)
        XCTAssertNotEqual(early.id, anotherCalendar.id)
        XCTAssertThrowsError(try CalendarEvent(providerID: .google, calendarID: "person@example.test", eventID: "bad-day",
            time: .allDay(startDate: "2026-02-29", endDateExclusive: "2026-03-01")).validate())
        XCTAssertNoThrow(try CalendarEvent(providerID: .google, calendarID: "person@example.test", eventID: "leap-day",
            time: .allDay(startDate: "2024-02-29", endDateExclusive: "2024-03-01")).validate())
    }

    func testInviteeLabelsAndSuggestionsDoNotTreatRoomsOrDeclinesAsSpeakers() throws {
        let attendees = [CalendarAttendee(email: "one@example.test", displayName: "  于虎  "),
                         CalendarAttendee(email: "two@example.test"), CalendarAttendee(),
                         CalendarAttendee(displayName: "Meeting room", isResource: true),
                         CalendarAttendee(displayName: "Declined person", responseStatus: "declined"),
                         CalendarAttendee(displayName: "于虎")]
        XCTAssertEqual(attendees[0].displayLabel, "于虎")
        XCTAssertEqual(attendees[1].displayLabel, "two@example.test")
        XCTAssertEqual(attendees[2].displayLabel, "Unnamed invitee")
        let event = CalendarEvent(providerID: .google, calendarID: "person@example.test", eventID: "event",
            title: "  第一行\n第二行  ", time: .timed(start: now, end: now.addingTimeInterval(60)),
            attendees: attendees, attendeesOmitted: true, guestListVisible: false)
        XCTAssertEqual(event.nameSuggestions, ["于虎", "two@example.test"])
        XCTAssertEqual(event.suggestedMeetingTitle, "第一行 第二行")
        XCTAssertTrue(event.inviteeListMayBeIncomplete)
        XCTAssertNoThrow(try event.validate())
        XCTAssertEqual(CalendarAttendee(displayName: String(repeating: "字", count: 300)).nameSuggestion?.count, 100)
    }

    func testMetadataAndURLBoundsRejectUnsafeInputs() throws {
        for value in ["http://meet.example.test/a", "file:///tmp/a", "javascript:alert(1)",
                      "https://person:secret@meet.example.test/a", "https://meet.example.test:444/a",
                      "https://meet.example.test/a%0Ab"] {
            XCTAssertFalse(CalendarEvent.safeLink(try XCTUnwrap(URL(string: value))), value)
        }
        XCTAssertTrue(CalendarEvent.safeLink(try XCTUnwrap(URL(string: "https://meet.google.com/abc-defg-hij"))))
        XCTAssertFalse(CalendarEvent.safeCalendarLink(try XCTUnwrap(URL(string: "https://calendar.google.com.other.example/calendar/event"))))
        XCTAssertFalse(CalendarEvent.safeCalendarLink(try XCTUnwrap(URL(string: "https://www.google.com/url?url=https://example.test"))))
        XCTAssertTrue(CalendarEvent.safeCalendarLink(try XCTUnwrap(URL(string: "https://calendar.google.com/calendar/event?eid=fixture"))))
        XCTAssertThrowsError(try CalendarEvent(providerID: .google, calendarID: "primary", eventID: "event", time: event().time).validate())
        XCTAssertThrowsError(try CalendarEvent(providerID: .google, calendarID: "person@example.test", eventID: "event",
            time: event().time, description: String(repeating: "x", count: 32_001)).validate())
        XCTAssertThrowsError(try CalendarEvent(providerID: .google, calendarID: "person@example.test", eventID: "event",
            time: .timed(start: now, end: Date(timeIntervalSince1970: 1e100))).validate())
    }

    private func storeFixture(_ body: (MeetingStore, Meeting, CalendarEventStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("afterword-calendar-data-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(rootURL: root)
        var meeting = try store.create(title: "My manual meeting title")
        meeting.captureState = .stopped
        try store.save(meeting)
        try body(store, meeting, CalendarEventStore(store: store))
    }

    func testSidecarRoundTripUsesUnixEpochWithoutChangingMeetingOrArtifacts() throws {
        try storeFixture { store, meeting, calendarStore in
            let meetingFile = try store.artifactURL(meetingID: meeting.id, relativePath: "meeting.json")
            let before = try Data(contentsOf: meetingFile)
            let source = try store.artifactURL(meetingID: meeting.id, relativePath: "sentinel-transcript.json")
            let immutable = Data("Original transcript remains unchanged".utf8)
            try immutable.write(to: source)
            XCTAssertNil(try calendarStore.read(meetingID: meeting.id))
            let snapshot = CalendarEventSnapshot(meetingID: meeting.id, event: event(), fetchedAt: now, linkedAt: now)
            let processingLock = try store.artifactURL(meetingID: meeting.id, relativePath: ".processing.lock")
            let descriptor = open(processingLock.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            defer { close(descriptor) }
            XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
            defer { flock(descriptor, LOCK_UN) }
            try calendarStore.save(snapshot)
            XCTAssertEqual(try calendarStore.read(meetingID: meeting.id), snapshot)
            let file = try store.artifactURL(meetingID: meeting.id, relativePath: "calendar-event.json")
            let value = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            XCTAssertEqual(value["linked_at"] as? Double, now.timeIntervalSince1970)
            XCTAssertEqual(value["provider_id"] as? String, "google")
            let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
            XCTAssertEqual(permissions.intValue & 0o777, 0o600)
            let replacement = CalendarEventSnapshot(meetingID: meeting.id, event: event("replacement"), fetchedAt: now, linkedAt: now)
            try calendarStore.save(replacement)
            XCTAssertEqual(try calendarStore.read(meetingID: meeting.id), replacement)
            try calendarStore.unlink(meetingID: meeting.id)
            XCTAssertNil(try calendarStore.read(meetingID: meeting.id))
            XCTAssertEqual(try Data(contentsOf: meetingFile), before)
            XCTAssertEqual(try Data(contentsOf: source), immutable)
            XCTAssertEqual(try store.load(id: meeting.id).title, "My manual meeting title")
        }
    }

    func testSidecarRejectsWrongMeetingProviderVersionSizeAndSymlinks() throws {
        try storeFixture { store, meeting, calendarStore in
            let snapshot = CalendarEventSnapshot(meetingID: meeting.id, event: event(), fetchedAt: now, linkedAt: now)
            try calendarStore.save(snapshot)
            let file = try store.artifactURL(meetingID: meeting.id, relativePath: "calendar-event.json")
            let original = try Data(contentsOf: file)
            let raw = try JSONSerialization.jsonObject(with: original) as! [String: Any]
            for (key, value) in [("meeting_id", "other" as Any), ("provider_id", "unsupported" as Any), ("schema_version", 2 as Any)] {
                var invalid = raw
                invalid[key] = value
                try JSONSerialization.data(withJSONObject: invalid).write(to: file)
                XCTAssertThrowsError(try calendarStore.read(meetingID: meeting.id), key)
            }
            try Data(repeating: 32, count: CalendarEventStore.maximumBytes + 1).write(to: file)
            XCTAssertThrowsError(try calendarStore.read(meetingID: meeting.id))
            try FileManager.default.removeItem(at: file)
            let outside = store.rootURL.appendingPathComponent("outside.json")
            try original.write(to: outside)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
            XCTAssertThrowsError(try calendarStore.read(meetingID: meeting.id))
            XCTAssertThrowsError(try calendarStore.save(snapshot))
            XCTAssertThrowsError(try calendarStore.unlink(meetingID: meeting.id))
            XCTAssertEqual(try Data(contentsOf: outside), original)
            XCTAssertThrowsError(try calendarStore.read(meetingID: "../outside"))
        }
    }

    func testDedicatedSidecarLockBlocksMutationButKeepsAcceptedReadsAvailable() throws {
        try storeFixture { store, meeting, calendarStore in
            let snapshot = CalendarEventSnapshot(meetingID: meeting.id, event: event(), fetchedAt: now, linkedAt: now)
            try calendarStore.save(snapshot)
            let path = try store.artifactURL(meetingID: meeting.id, relativePath: ".calendar-event.lock")
            let descriptor = open(path.path, O_RDWR)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            defer { close(descriptor) }
            XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
            defer { flock(descriptor, LOCK_UN) }
            XCTAssertThrowsError(try calendarStore.save(snapshot))
            XCTAssertThrowsError(try calendarStore.unlink(meetingID: meeting.id))
            XCTAssertEqual(try calendarStore.read(meetingID: meeting.id), snapshot)
        }
    }
}
