import Foundation
import XCTest
@testable import AfterwordApp

private struct CalendarHTTPReply: Sendable {
    var status = 200
    var data = Data()
    var headers = ["Content-Type": "application/json"]
    var responseURL: URL?
    var redirectURL: URL?
    var hold = false

    init(status: Int = 200, json: [String: Any] = [:]) throws {
        self.status = status
        data = try JSONSerialization.data(withJSONObject: json)
    }
}

private final class CalendarHTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [CalendarHTTPReply]
    private var requests: [URLRequest] = []
    private var stops = 0

    init(_ replies: [CalendarHTTPReply]) { self.replies = replies }

    func next(_ request: URLRequest) -> CalendarHTTPReply? {
        lock.withLock {
            requests.append(request)
            return replies.isEmpty ? nil : replies.removeFirst()
        }
    }

    func stopped() { lock.withLock { stops += 1 } }
    var recorded: [URLRequest] { lock.withLock { requests } }
    var stopCount: Int { lock.withLock { stops } }
}

private final class CalendarURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixture: CalendarHTTPState?
    private var owner: CalendarHTTPState?

    static func install(_ fixture: CalendarHTTPState?) { lock.withLock { self.fixture = fixture } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        owner = Self.lock.withLock { Self.fixture }
        guard let reply = owner?.next(request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if reply.hold { return }
        let response = HTTPURLResponse(url: reply.responseURL ?? url, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        if let target = reply.redirectURL {
            var redirected = request
            redirected.url = target
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { owner?.stopped() }
}

private actor CalendarTestTokens: CalendarAccessTokenProviding {
    private(set) var calls: [Bool] = []
    private var token = "fixture-token"

    func accessToken(forceRefresh: Bool) async throws -> String {
        calls.append(forceRefresh)
        if forceRefresh { token = "fixture-refreshed-token" }
        return token
    }
}

final class GoogleCalendarClientTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 1_793_514_600)
    private let calendar = CalendarInfo(providerID: .google, id: "person@example.test", title: "Test calendar", timeZoneID: "UTC", isPrimary: true)

    override func tearDown() {
        CalendarURLProtocol.install(nil)
        super.tearDown()
    }

    private func fixture(_ replies: [CalendarHTTPReply]) -> (GoogleCalendarClient, CalendarTestTokens, CalendarHTTPState) {
        let state = CalendarHTTPState(replies)
        CalendarURLProtocol.install(state)
        let tokens = CalendarTestTokens()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CalendarURLProtocol.self]
        let clock = now
        return (GoogleCalendarClient(tokenProvider: tokens, configuration: configuration, now: { clock }), tokens, state)
    }

    private func row(id: String = "event", start: String = "2026-11-01T01:30:00-07:00",
                     end: String = "2026-11-01T01:30:00-08:00") -> [String: Any] {
        ["id": id, "summary": "讨论 meeting", "status": "confirmed", "eventType": "default",
         "start": ["dateTime": start, "timeZone": "America/Los_Angeles"], "end": ["dateTime": end]]
    }

    private func fetch(_ client: GoogleCalendarClient, calendar: CalendarInfo? = nil) async throws -> CalendarEventWindow {
        try await client.events(calendar: calendar ?? self.calendar, from: now.addingTimeInterval(-86_400), to: now.addingTimeInterval(86_400))
    }

    func testCatalogPaginationFiltersRolesAndUsesReadOnlyRequests() async throws {
        let replies = [try CalendarHTTPReply(json: ["items": [], "nextPageToken": "next&+/#"]),
                       try CalendarHTTPReply(json: ["items": [
                        ["id": "shared@example.test", "summary": "Original", "summaryOverride": "Chosen", "accessRole": "reader"],
                        ["id": "primary@example.test", "summary": "Primary", "primary": true, "accessRole": "owner", "timeZone": "Asia/Shanghai"],
                        ["id": "busy@example.test", "accessRole": "freeBusyReader"],
                        ["id": "hidden@example.test", "accessRole": "reader", "hidden": true],
                        ["id": "deleted@example.test", "accessRole": "owner", "deleted": true]]])]
        let (client, tokens, state) = fixture(replies)
        let calendars = try await client.calendars()
        XCTAssertEqual(calendars.map(\.id), ["primary@example.test", "shared@example.test"])
        XCTAssertEqual(calendars.last?.title, "Chosen")
        XCTAssertEqual(state.recorded.count, 2)
        for request in state.recorded {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.url?.host, "www.googleapis.com")
            XCTAssertEqual(request.url?.path, "/calendar/v3/users/me/calendarList")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        }
        let query = URLComponents(url: state.recorded[1].url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "pageToken" }?.value, "next&+/#")
        XCTAssertEqual(query.first { $0.name == "minAccessRole" }?.value, "reader")
        let calls = await tokens.calls
        XCTAssertEqual(calls, [false])
    }

    func testEventsExpandOccurrencesParseDSTAndPreserveInviteeMetadata() async throws {
        var timed = row()
        timed["recurringEventId"] = "master"
        timed["originalStartTime"] = ["dateTime": "2026-11-01T01:30:00-07:00"]
        timed["description"] = "<b>Meeting context</b> stays plain text"
        timed["location"] = "会议室"
        timed["organizer"] = ["displayName": "Organizer", "email": "host@example.test"]
        timed["htmlLink"] = "https://calendar.google.com/calendar/event?eid=fixture"
        timed["hangoutLink"] = "javascript:alert(1)"
        timed["conferenceData"] = ["entryPoints": [["entryPointType": "video", "uri": "https://meet.google.com/abc-defg-hij"]]]
        timed["attendees"] = [["email": "person@example.test", "self": true, "responseStatus": "accepted"],
                               ["email": "room@example.test", "displayName": "Room", "resource": true],
                               ["displayName": "于虎", "additionalGuests": 1]]
        timed["guestsCanSeeOtherGuests"] = false
        let allDay: [String: Any] = ["id": "all-day", "start": ["date": "2026-11-01"], "end": ["date": "2026-11-02"]]
        var focus = row(id: "focus")
        focus["eventType"] = "focusTime"
        let (client, _, state) = fixture([try CalendarHTTPReply(json: ["items": [
            ["id": "cancelled", "status": "cancelled"], timed, allDay, focus]])])
        let oddID = CalendarInfo(providerID: .google, id: "team/name?x=1#room@example.test", title: "Encoded ID")
        let result = try await fetch(client, calendar: oddID)
        XCTAssertEqual(result.events.count, 2)
        let event = result.events[0]
        XCTAssertEqual(event.calendarID, oddID.id)
        XCTAssertEqual(event.time.interval?.duration, 3_600)
        XCTAssertEqual(event.originalStartTime, "2026-11-01T01:30:00-07:00")
        XCTAssertEqual(event.organizer?.email, "host@example.test")
        XCTAssertEqual(event.description, "<b>Meeting context</b> stays plain text")
        XCTAssertEqual(event.nameSuggestions, ["person@example.test", "于虎"])
        XCTAssertTrue(event.inviteeListMayBeIncomplete)
        XCTAssertEqual(event.joinURL?.host, "meet.google.com")
        XCTAssertTrue(result.events[1].time.isAllDay)
        XCTAssertEqual(result.fetchedAt, now)
        let components = URLComponents(url: state.recorded[0].url!, resolvingAgainstBaseURL: false)!
        XCTAssertTrue(components.percentEncodedPath.contains("team%2Fname%3Fx%3D1%23room%40example.test"))
        let query = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["singleEvents"], "true")
        XCTAssertEqual(query["timeZone"], "UTC")
        XCTAssertEqual(query["eventTypes"], "default")
        XCTAssertEqual(query["showDeleted"], "false")
        XCTAssertEqual(query["orderBy"], "startTime")
        XCTAssertNil(query["maxAttendees"])
        XCTAssertTrue(query["timeMin"]!.hasSuffix("Z"))
        XCTAssertTrue(query["fields"]!.contains("attendeesOmitted"))
        XCTAssertFalse(query["fields"]!.contains("attachments"))
    }

    func testOffsetlessMixedAllDayAndInvalidEventTimesRejectWholeWindow() async throws {
        var mixed = row()
        mixed["start"] = ["date": "2026-11-01"]
        let invalid = [row(start: "2026-11-01T01:30:00", end: "2026-11-01T02:30:00"), mixed,
                       row(start: "2026-11-01T03:30:00Z", end: "2026-11-01T02:30:00Z"),
                       row(start: "2026-11-01T01:30:00Z\n", end: "2026-11-01T02:30:00Z")]
        for bad in invalid {
            let (client, _, _) = fixture([try CalendarHTTPReply(json: ["items": [row(id: "valid"), bad]])])
            do { _ = try await fetch(client); XCTFail("Invalid timing must not produce a partial matchable window.") }
            catch { XCTAssertFalse(error.localizedDescription.contains("PRIVATE")) }
        }
        let (client, _, _) = fixture([try CalendarHTTPReply(json: ["items": [
            row(start: "2026-11-01T01:30:00.125Z", end: "2026-11-01T02:30:00.250Z")]])])
        let fractional = try await fetch(client)
        XCTAssertEqual(fractional.events.first?.time.interval?.duration, 3_600.125)
    }

    func testUnauthorizedRefreshesOnceAndDoesNotExposeResponseBodies() async throws {
        for succeeds in [true, false] {
            let (client, tokens, state) = fixture([
                try CalendarHTTPReply(status: 401, json: ["error": "PRIVATE_RESPONSE_BODY"]),
                try CalendarHTTPReply(status: succeeds ? 200 : 401, json: succeeds ? ["items": []] : ["error": "PRIVATE_RESPONSE_BODY"])])
            do {
                _ = try await client.calendars()
                XCTAssertTrue(succeeds)
            } catch {
                XCTAssertFalse(succeeds)
                XCTAssertFalse(error.localizedDescription.contains("PRIVATE_RESPONSE_BODY"))
                XCTAssertFalse(error.localizedDescription.contains("fixture-token"))
            }
            let calls = await tokens.calls
            XCTAssertEqual(calls, [false, true])
            XCTAssertEqual(state.recorded.count, 2)
            XCTAssertEqual(state.recorded.last?.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-refreshed-token")
        }
    }

    func testIncompleteOrUnboundedPaginationCannotPublishAWindow() async throws {
        let sequences = [
            [try CalendarHTTPReply(json: ["items": [row()], "nextPageToken": "repeat"]),
             try CalendarHTTPReply(json: ["items": [], "nextPageToken": "repeat"])],
            try (0..<20).map { try CalendarHTTPReply(json: ["items": [], "nextPageToken": "page-\($0)"]) },
            [try CalendarHTTPReply(json: ["items": Array(repeating: ["status": "cancelled"], count: 2_001)])],
            [try CalendarHTTPReply(json: ["items": [row()], "nextPageToken": "next"]),
             try CalendarHTTPReply(status: 503, json: ["error": "PRIVATE_RESPONSE_BODY"])]]
        for replies in sequences {
            let (client, _, state) = fixture(replies)
            do { _ = try await fetch(client); XCTFail("Incomplete pagination must fail the entire refresh.") }
            catch { XCTAssertFalse(error.localizedDescription.contains("PRIVATE_RESPONSE_BODY")) }
            XCTAssertLessThanOrEqual(state.recorded.count, 20)
        }
    }

    func testResponseBoundsAndWrongResponseHostAreRejected() async throws {
        var oversizedHeader = try CalendarHTTPReply()
        oversizedHeader.headers["Content-Length"] = String(GoogleCalendarClient.maximumResponseBytes + 1)
        var oversizedBody = try CalendarHTTPReply()
        oversizedBody.data = Data(repeating: 32, count: GoogleCalendarClient.maximumResponseBytes + 1)
        var wrongHost = try CalendarHTTPReply(json: ["items": []])
        wrongHost.responseURL = URL(string: "https://other.example.test/calendar/v3/users/me/calendarList")
        var malformed = try CalendarHTTPReply()
        malformed.data = Data("PRIVATE_INVALID_RESPONSE".utf8)
        for reply in [oversizedHeader, oversizedBody, wrongHost, malformed] {
            let (client, _, state) = fixture([reply])
            do { _ = try await client.calendars(); XCTFail("Unsafe or oversized responses must be rejected.") }
            catch { XCTAssertFalse(error.localizedDescription.contains("PRIVATE_INVALID_RESPONSE")) }
            XCTAssertEqual(state.recorded.count, 1)
        }
    }

    func testRedirectNeverForwardsTheBearerToken() async throws {
        var redirect = try CalendarHTTPReply(status: 302)
        redirect.redirectURL = URL(string: "https://other.example.test/collect")
        redirect.headers["Location"] = redirect.redirectURL!.absoluteString
        let (client, _, state) = fixture([redirect, try CalendarHTTPReply(json: ["items": []])])
        do { _ = try await client.calendars(); XCTFail("Redirects must be rejected.") }
        catch { XCTAssertFalse(error.localizedDescription.contains("fixture-token")) }
        XCTAssertEqual(state.recorded.count, 1)
        XCTAssertTrue(state.recorded.allSatisfy { $0.url?.host == "www.googleapis.com" })
    }

    func testInvalidQueriesDoNotRequestTokensOrContactTransport() async throws {
        let (client, tokens, state) = fixture([])
        for id in ["primary", ".", ".."] {
            let invalid = CalendarInfo(providerID: .google, id: id, title: "Invalid identifier")
            do { _ = try await fetch(client, calendar: invalid); XCTFail("Calendar identity must be canonical and safe as one path component.") }
            catch {}
        }
        do { _ = try await client.events(calendar: calendar, from: now, to: now.addingTimeInterval(32 * 86_400)); XCTFail("Query exceeds its range bound.") }
        catch {}
        let calls = await tokens.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(state.recorded.isEmpty)
    }

    func testCancellationStopsAnOutstandingRead() async throws {
        var held = try CalendarHTTPReply()
        held.hold = true
        let (client, _, state) = fixture([held])
        let task = Task { try await client.calendars() }
        for _ in 0..<200 where state.recorded.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(state.recorded.count, 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled reads must not produce catalog data.") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
