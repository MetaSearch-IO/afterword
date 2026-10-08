import Foundation

protocol CalendarAccessTokenProviding: Sendable {
    func accessToken(forceRefresh: Bool) async throws -> String
}

protocol CalendarReading: Sendable {
    func calendars() async throws -> [CalendarInfo]
    func events(calendar: CalendarInfo, from start: Date, to end: Date) async throws -> CalendarEventWindow
}

actor GoogleCalendarClient: CalendarReading {
    static let maximumResponseBytes = 4 * 1_024 * 1_024
    private let tokenProvider: any CalendarAccessTokenProviding
    private let session: URLSession
    private let now: @Sendable () -> Date

    init(tokenProvider: any CalendarAccessTokenProviding, configuration: URLSessionConfiguration = .ephemeral,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.tokenProvider = tokenProvider
        self.now = now
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpAdditionalHeaders = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: CalendarRedirectBlocker(), delegateQueue: nil)
    }

    func calendars() async throws -> [CalendarInfo] {
        let rows: [CalendarRow] = try await pages(path: "/calendar/v3/users/me/calendarList", query: [
            URLQueryItem(name: "maxResults", value: "100"), URLQueryItem(name: "minAccessRole", value: "reader"),
            URLQueryItem(name: "showDeleted", value: "false"), URLQueryItem(name: "showHidden", value: "false"),
            URLQueryItem(name: "fields", value: "nextPageToken,items(id,summary,summaryOverride,timeZone,primary,accessRole,hidden,deleted)")
        ], limit: 200)
        var result: [CalendarInfo] = []
        var ids = Set<String>()
        for row in rows {
            guard row.deleted != true, row.hidden != true,
                  ["reader", "writerWithoutPrivateAccess", "writer", "owner"].contains(row.accessRole ?? "") else { continue }
            guard let id = row.id, id != "primary", ids.insert(id).inserted else { throw CalendarReadError.invalidResponse }
            let calendar = CalendarInfo(providerID: .google, id: id, title: nonempty(row.summaryOverride) ?? nonempty(row.summary) ?? id,
                                        timeZoneID: row.timeZone, isPrimary: row.primary)
            try calendar.validate()
            result.append(calendar)
        }
        return result.sorted {
            if ($0.isPrimary == true) != ($1.isPrimary == true) { return $0.isPrimary == true }
            return ($0.title, $0.id) < ($1.title, $1.id)
        }
    }

    func events(calendar: CalendarInfo, from start: Date, to end: Date) async throws -> CalendarEventWindow {
        try calendar.validate()
        guard calendar.id != "primary", start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite,
              start < end, end.timeIntervalSince(start) <= 31 * 86_400 else { throw CalendarReadError.invalidQuery }
        let fetchedAt = now()
        try CalendarEventWindow(providerID: .google, calendarID: calendar.id, queryStart: start, queryEnd: end,
                                fetchedAt: fetchedAt, events: []).validate()
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let id = calendar.id.addingPercentEncoding(withAllowedCharacters: allowed) else { throw CalendarReadError.invalidQuery }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let rows: [EventRow] = try await pages(path: "/calendar/v3/calendars/\(id)/events", query: [
            URLQueryItem(name: "maxResults", value: "100"), URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"), URLQueryItem(name: "timeZone", value: "UTC"),
            URLQueryItem(name: "showDeleted", value: "false"), URLQueryItem(name: "showHiddenInvitations", value: "false"),
            URLQueryItem(name: "eventTypes", value: "default"),
            URLQueryItem(name: "timeMin", value: formatter.string(from: start)), URLQueryItem(name: "timeMax", value: formatter.string(from: end)),
            URLQueryItem(name: "fields", value: "nextPageToken,items(id,summary,status,htmlLink,start,end,endTimeUnspecified,recurringEventId,originalStartTime,eventType,description,location,organizer(displayName,email,self),attendees(displayName,email,responseStatus,self,resource,additionalGuests,asyncOperation),attendeesOmitted,guestsCanSeeOtherGuests,hangoutLink,conferenceData(entryPoints(entryPointType,uri)))")
        ], limit: 2_000)
        var events: [CalendarEvent] = []
        for row in rows {
            guard row.status != "cancelled", row.eventType == nil || row.eventType == "default", row.endTimeUnspecified != true else { continue }
            guard let id = row.id, let start = row.start, let end = row.end else { throw CalendarReadError.invalidResponse }
            let time: CalendarEventTime
            if let first = start.date, let last = end.date, start.dateTime == nil, end.dateTime == nil {
                time = .allDay(startDate: first, endDateExclusive: last)
            } else if let first = start.dateTime, let last = end.dateTime, start.date == nil, end.date == nil,
                      let lower = Self.timestamp(first), let upper = Self.timestamp(last) {
                time = .timed(start: lower, end: upper)
            } else { throw CalendarReadError.invalidResponse }
            let guests = row.attendees ?? []
            let event = CalendarEvent(providerID: .google, calendarID: calendar.id, eventID: id, title: row.summary,
                time: time, status: row.status ?? "confirmed", description: row.description, location: row.location,
                organizer: row.organizer?.attendee, htmlLink: Self.link(row.htmlLink).flatMap { CalendarEvent.safeCalendarLink($0) ? $0 : nil },
                joinURL: Self.link(row.hangoutLink) ?? row.conferenceData?.entryPoints?.first(where: {
                    $0.entryPointType == "video" && Self.link($0.uri) != nil
                }).flatMap { Self.link($0.uri) },
                timeZoneID: start.timeZone ?? calendar.timeZoneID,
                recurringEventID: row.recurringEventId, originalStartTime: row.originalStartTime?.dateTime ?? row.originalStartTime?.date,
                attendees: guests.map(\.attendee), attendeesOmitted: row.attendeesOmitted == true || row.attendees == nil
                    || guests.contains { ($0.additionalGuests ?? 0) > 0 || $0.asyncOperation != nil },
                guestListVisible: row.guestsCanSeeOtherGuests)
            try event.validate()
            events.append(event)
        }
        let window = CalendarEventWindow(providerID: .google, calendarID: calendar.id, queryStart: start, queryEnd: end,
                                         fetchedAt: fetchedAt, events: events)
        try window.validate()
        return window
    }

    private func pages<Row: Decodable & Sendable>(path: String, query: [URLQueryItem], limit: Int) async throws -> [Row] {
        var token = try await tokenProvider.accessToken(forceRefresh: false)
        var refreshed = false
        var pageToken: String?
        var seen = Set<String>()
        var result: [Row] = []
        for _ in 0..<20 {
            try Task.checkCancellation()
            var components = URLComponents()
            components.scheme = "https"
            components.host = "www.googleapis.com"
            components.percentEncodedPath = path
            components.queryItems = query + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            guard let url = components.url else { throw CalendarReadError.invalidQuery }
            let bytes = try await request(url, token: &token, refreshed: &refreshed)
            let page: Page<Row>
            do { page = try JSONDecoder().decode(Page<Row>.self, from: bytes) }
            catch { throw CalendarReadError.invalidResponse }
            result.append(contentsOf: page.items ?? [])
            guard result.count <= limit else { throw CalendarReadError.resultLimit }
            guard let next = page.nextPageToken, !next.isEmpty else { return result }
            guard next.utf8.count <= 8_192, seen.insert(next).inserted else { throw CalendarReadError.invalidPagination }
            pageToken = next
        }
        throw CalendarReadError.resultLimit
    }

    private func request(_ url: URL, token: inout String, refreshed: inout Bool) async throws -> Data {
        while true {
            try Task.checkCancellation()
            guard !token.isEmpty, token.utf8.count <= 16_384, token.utf8.allSatisfy({ (33...126).contains($0) }) else {
                throw CalendarReadError.signInRequired
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (bytes, response): (URLSession.AsyncBytes, URLResponse)
            do { (bytes, response) = try await session.bytes(for: request) }
            catch is CancellationError { throw CancellationError() }
            catch let error as URLError where error.code == .cancelled { throw CancellationError() }
            catch { throw CalendarReadError.networkUnavailable }
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse, response.url?.scheme == "https",
                  response.url?.host == "www.googleapis.com", response.url?.path == url.path else {
                throw CalendarReadError.invalidResponse
            }
            if response.statusCode == 401 {
                bytes.task.cancel()
                guard !refreshed else { throw CalendarReadError.signInRequired }
                refreshed = true
                token = try await tokenProvider.accessToken(forceRefresh: true)
                continue
            }
            switch response.statusCode {
            case 200: break
            case 403: throw CalendarReadError.permissionDenied
            case 429: throw CalendarReadError.rateLimited
            case 500...599: throw CalendarReadError.serviceUnavailable
            default: throw CalendarReadError.requestFailed
            }
            guard response.expectedContentLength <= Int64(Self.maximumResponseBytes) else { throw CalendarReadError.responseLimit }
            var data = Data()
            do {
                for try await byte in bytes {
                    guard data.count < Self.maximumResponseBytes else { throw CalendarReadError.responseLimit }
                    data.append(byte)
                    if data.count % 4_096 == 0 { try Task.checkCancellation() }
                }
            } catch is CancellationError { throw CancellationError() }
            catch let error as CalendarReadError { throw error }
            catch let error as URLError where error.code == .cancelled { throw CancellationError() }
            catch { throw CalendarReadError.networkUnavailable }
            try Task.checkCancellation()
            return data
        }
    }

    private static func timestamp(_ value: String) -> Date? {
        guard value.utf8.count <= 128,
              value.range(of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})\z"#,
                          options: .regularExpression) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func link(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), CalendarEvent.safeLink(url) else { return nil }
        return url
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private struct Page<Row: Decodable & Sendable>: Decodable, Sendable {
        let nextPageToken: String?
        let items: [Row]?
    }

    private struct CalendarRow: Decodable, Sendable {
        let id: String?
        let summary: String?
        let summaryOverride: String?
        let timeZone: String?
        let primary: Bool?
        let accessRole: String?
        let hidden: Bool?
        let deleted: Bool?
    }

    private struct EventDate: Decodable, Sendable {
        let date: String?
        let dateTime: String?
        let timeZone: String?
    }

    private struct Person: Decodable, Sendable {
        let email: String?
        let displayName: String?
        let responseStatus: String?
        let isSelf: Bool?
        let resource: Bool?
        let additionalGuests: Int?
        let asyncOperation: String?
        var attendee: CalendarAttendee {
            CalendarAttendee(email: email, displayName: displayName, responseStatus: responseStatus,
                             isSelf: isSelf == true, isResource: resource == true)
        }
        enum CodingKeys: String, CodingKey {
            case email, displayName, responseStatus, resource, additionalGuests, asyncOperation
            case isSelf = "self"
        }
    }

    private struct Conference: Decodable, Sendable {
        let entryPoints: [Entry]?
        struct Entry: Decodable, Sendable {
            let entryPointType: String?
            let uri: String?
        }
    }

    private struct EventRow: Decodable, Sendable {
        let id: String?
        let summary: String?
        let status: String?
        let description: String?
        let location: String?
        let htmlLink: String?
        let hangoutLink: String?
        let eventType: String?
        let endTimeUnspecified: Bool?
        let start: EventDate?
        let end: EventDate?
        let recurringEventId: String?
        let originalStartTime: EventDate?
        let organizer: Person?
        let attendees: [Person]?
        let attendeesOmitted: Bool?
        let guestsCanSeeOtherGuests: Bool?
        let conferenceData: Conference?
    }
}

private final class CalendarRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum CalendarReadError: LocalizedError {
    case invalidQuery, invalidResponse, invalidPagination, responseLimit, resultLimit, signInRequired
    case permissionDenied, rateLimited, serviceUnavailable, requestFailed, networkUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidQuery: "Choose a calendar and a valid date range of at most 31 days."
        case .invalidResponse: "Google Calendar returned incomplete or invalid event data. Refresh to try again."
        case .invalidPagination: "Google Calendar returned an invalid page sequence. Refresh to try again."
        case .responseLimit, .resultLimit: "Calendar results exceed the local limits. Choose a narrower date range."
        case .signInRequired: "Google Calendar access expired. Sign in again."
        case .permissionDenied: "Google Calendar did not allow this read. Check the selected calendar and read-only access."
        case .rateLimited: "Google Calendar is limiting requests. Try refreshing later."
        case .serviceUnavailable: "Google Calendar is temporarily unavailable. Recording is still available."
        case .requestFailed: "Google Calendar could not complete the read. Try refreshing again."
        case .networkUnavailable: "Google Calendar could not be reached. Recording is still available."
        }
    }
}
