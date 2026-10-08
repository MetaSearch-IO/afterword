import Foundation

enum CalendarProviderID: String, Codable, Sendable {
    case google
}

struct CalendarInfo: Codable, Equatable, Identifiable, Sendable {
    let providerID: CalendarProviderID
    let id: String
    let title: String
    let timeZoneID: String?
    let isPrimary: Bool?

    init(providerID: CalendarProviderID, id: String, title: String, timeZoneID: String? = nil, isPrimary: Bool? = nil) {
        self.providerID = providerID
        self.id = id
        self.title = title
        self.timeZoneID = timeZoneID
        self.isPrimary = isPrimary
    }

    func validate() throws {
        try CalendarText.identifier(id)
        try CalendarText.require(id != "primary", "Select a calendar with its actual identifier.")
        try CalendarText.validate(title, limit: 2_000)
        if let timeZoneID {
            try CalendarText.require(timeZoneID.utf8.count <= 128 && TimeZone(identifier: timeZoneID) != nil,
                                     "Calendar time zone is invalid.")
        }
    }
}

struct CalendarAttendee: Codable, Equatable, Sendable {
    let email: String?
    let displayName: String?
    let responseStatus: String?
    let isSelf: Bool
    let isResource: Bool

    init(email: String? = nil, displayName: String? = nil, responseStatus: String? = nil,
         isSelf: Bool = false, isResource: Bool = false) {
        self.email = email
        self.displayName = displayName
        self.responseStatus = responseStatus
        self.isSelf = isSelf
        self.isResource = isResource
    }

    var displayLabel: String { CalendarText.nonempty(displayName) ?? CalendarText.nonempty(email) ?? "Unnamed invitee" }
    var nameSuggestion: String? {
        guard !isResource, responseStatus != "declined",
              let label = CalendarText.nonempty(displayName) ?? CalendarText.nonempty(email) else { return nil }
        return String(label.prefix(100))
    }

    fileprivate func validate() throws {
        try CalendarText.validate(email, limit: 512)
        try CalendarText.validate(displayName, limit: 500)
        try CalendarText.validate(responseStatus, limit: 64)
    }

    enum CodingKeys: String, CodingKey {
        case email
        case displayName = "display_name", responseStatus = "response_status", isSelf = "is_self", isResource = "is_resource"
    }
}

enum CalendarEventTime: Codable, Equatable, Sendable {
    case timed(start: Date, end: Date)
    case allDay(startDate: String, endDateExclusive: String)

    var interval: DateInterval? {
        guard case let .timed(start, end) = self, CalendarText.validDate(start), CalendarText.validDate(end), start < end else { return nil }
        return DateInterval(start: start, end: end)
    }

    var isAllDay: Bool {
        if case .allDay = self { return true }
        return false
    }

    fileprivate func validate() throws {
        switch self {
        case let .timed(start, end):
            try CalendarText.require(CalendarText.validDate(start) && CalendarText.validDate(end) && start < end,
                                     "Calendar event times are invalid.")
        case let .allDay(start, end):
            try CalendarText.require(Self.validDay(start) && Self.validDay(end) && start < end,
                                     "All-day calendar dates are invalid.")
        }
    }

    private static func validDay(_ value: String) -> Bool {
        guard value.utf8.count == 10, value.utf8.enumerated().allSatisfy({ index, byte in
            [4, 7].contains(index) ? byte == 45 : (48...57).contains(byte)
        }) else { return false }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, parts[0] >= 1 else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: components) else { return false }
        let result = calendar.dateComponents([.year, .month, .day], from: date)
        return result.year == parts[0] && result.month == parts[1] && result.day == parts[2]
    }
}

struct CalendarEvent: Codable, Equatable, Identifiable, Sendable {
    let providerID: CalendarProviderID
    let calendarID: String
    let eventID: String
    let title: String?
    let time: CalendarEventTime
    let status: String
    let description: String?
    let location: String?
    let organizer: CalendarAttendee?
    let htmlLink: URL?
    let joinURL: URL?
    let timeZoneID: String?
    let recurringEventID: String?
    let originalStartTime: String?
    let attendees: [CalendarAttendee]
    let attendeesOmitted: Bool
    let guestListVisible: Bool?

    init(providerID: CalendarProviderID, calendarID: String, eventID: String, title: String? = nil,
         time: CalendarEventTime, status: String = "confirmed", description: String? = nil, location: String? = nil,
         organizer: CalendarAttendee? = nil, htmlLink: URL? = nil, joinURL: URL? = nil, timeZoneID: String? = nil,
         recurringEventID: String? = nil, originalStartTime: String? = nil, attendees: [CalendarAttendee] = [],
         attendeesOmitted: Bool = false, guestListVisible: Bool? = nil) {
        self.providerID = providerID
        self.calendarID = calendarID
        self.eventID = eventID
        self.title = title
        self.time = time
        self.status = status
        self.description = description
        self.location = location
        self.organizer = organizer
        self.htmlLink = htmlLink
        self.joinURL = joinURL
        self.timeZoneID = timeZoneID
        self.recurringEventID = recurringEventID
        self.originalStartTime = originalStartTime
        self.attendees = attendees
        self.attendeesOmitted = attendeesOmitted
        self.guestListVisible = guestListVisible
    }

    var id: String {
        [providerID.rawValue, calendarID, eventID, originalStartTime ?? ""].map { "\($0.utf8.count):\($0)" }.joined()
    }
    var displayTitle: String { CalendarText.nonempty(title) ?? "Untitled event" }
    var suggestedMeetingTitle: String? {
        CalendarText.nonempty(title).map { String($0.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(200)) }
    }
    var isDeclinedOnCalendar: Bool { attendees.contains { $0.isSelf && $0.responseStatus == "declined" } }
    var inviteeListMayBeIncomplete: Bool { attendeesOmitted || guestListVisible == false }
    var nameSuggestions: [String] {
        var seen = Set<String>()
        return attendees.compactMap(\.nameSuggestion).filter { seen.insert($0).inserted }
    }

    func validate() throws {
        try CalendarText.identifier(calendarID)
        try CalendarText.require(calendarID != "primary", "Calendar context requires the calendar's actual identifier.")
        try CalendarText.identifier(eventID)
        try CalendarText.validate(title, limit: 2_000)
        try CalendarText.validate(status, limit: 64)
        try CalendarText.require(!status.isEmpty, "Calendar event status is missing.")
        try CalendarText.validate(description, limit: 32_000)
        try CalendarText.validate(location, limit: 2_000)
        try CalendarText.validate(originalStartTime, limit: 128)
        if let recurringEventID { try CalendarText.identifier(recurringEventID) }
        if let timeZoneID {
            try CalendarText.require(timeZoneID.utf8.count <= 128 && TimeZone(identifier: timeZoneID) != nil,
                                     "Calendar time zone is invalid.")
        }
        try time.validate()
        try organizer?.validate()
        try CalendarText.require(attendees.count <= 1_000, "Calendar invitee list exceeds its limit.")
        for attendee in attendees { try attendee.validate() }
        if let htmlLink { try CalendarText.require(Self.safeCalendarLink(htmlLink), "Calendar event link is outside Google Calendar.") }
        if let joinURL { try CalendarText.require(Self.safeLink(joinURL), "Meeting links must be credential-free HTTPS URLs.") }
    }

    static func safeLink(_ url: URL) -> Bool {
        guard url.absoluteString.utf8.count <= 8_192, url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let decoded = url.absoluteString.removingPercentEncoding else { return false }
        return !decoded.unicodeScalars.contains { $0.value < 32 || (127...159).contains($0.value) }
    }

    static func safeCalendarLink(_ url: URL) -> Bool {
        safeLink(url) && ["calendar.google.com", "www.google.com"].contains(url.host?.lowercased() ?? "")
            && (url.path == "/calendar" || url.path.hasPrefix("/calendar/"))
            && !url.pathComponents.contains(where: { $0 == "." || $0 == ".." })
    }

    enum CodingKeys: String, CodingKey {
        case title, time, status, description, location, organizer, attendees
        case providerID = "provider_id", calendarID = "calendar_id", eventID = "event_id"
        case htmlLink = "html_link", joinURL = "join_url", timeZoneID = "time_zone_id"
        case recurringEventID = "recurring_event_id", originalStartTime = "original_start_time"
        case attendeesOmitted = "attendees_omitted", guestListVisible = "guest_list_visible"
    }
}

struct CalendarEventWindow: Equatable, Sendable {
    let providerID: CalendarProviderID
    let calendarID: String
    let queryStart: Date
    let queryEnd: Date
    let fetchedAt: Date
    let events: [CalendarEvent]

    func validate() throws {
        try CalendarText.identifier(calendarID)
        try CalendarText.require(CalendarText.validDate(queryStart) && CalendarText.validDate(queryEnd)
            && CalendarText.validDate(fetchedAt) && queryStart < queryEnd, "Calendar query window is invalid.")
        try CalendarText.require(events.count <= 2_000 && Set(events.map(\.id)).count == events.count,
                                 "Calendar results exceed their limit or contain duplicate occurrences.")
        for event in events {
            try event.validate()
            try CalendarText.require(event.providerID == providerID && event.calendarID == calendarID,
                                     "Calendar results belong to a different provider or calendar.")
        }
    }
}

struct CalendarEventSnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let providerID: CalendarProviderID
    let meetingID: String
    let linkedAt: Date
    let fetchedAt: Date
    let event: CalendarEvent

    init(meetingID: String, event: CalendarEvent, fetchedAt: Date, linkedAt: Date = Date()) {
        schemaVersion = 1
        providerID = event.providerID
        self.meetingID = meetingID
        self.linkedAt = linkedAt
        self.fetchedAt = fetchedAt
        self.event = event
    }

    func validate(meetingID expected: String) throws {
        try CalendarText.require(schemaVersion == 1 && meetingID == expected && providerID == event.providerID,
                                 "Calendar snapshot identity or version does not match this meeting.")
        try CalendarText.require(CalendarText.validDate(linkedAt) && CalendarText.validDate(fetchedAt),
                                 "Calendar snapshot dates are invalid.")
        try event.validate()
    }

    enum CodingKeys: String, CodingKey {
        case event
        case schemaVersion = "schema_version", providerID = "provider_id", meetingID = "meeting_id"
        case linkedAt = "linked_at", fetchedAt = "fetched_at"
    }
}

private enum CalendarText {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CalendarDataError(message: message) }
    }

    static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func identifier(_ value: String) throws {
        try require(!value.isEmpty && value != "." && value != ".." && value.utf8.count <= 2_048
            && !value.unicodeScalars.contains { $0.value < 32 || (127...159).contains($0.value) }, "Calendar identifier is invalid.")
    }

    static func validate(_ value: String?, limit: Int) throws {
        guard let value else { return }
        try require(value.utf8.count <= limit * 4 && value.count <= limit && !value.contains("\0"),
                    "Calendar text exceeds its limit or contains invalid characters.")
    }

    static func validDate(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && (-62_135_596_800..<253_402_300_800).contains(seconds)
    }
}

struct CalendarDataError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
