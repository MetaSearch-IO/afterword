import Foundation
import Network
import XCTest
@testable import AfterwordApp

final class GoogleOAuthLoopbackTests: XCTestCase, @unchecked Sendable {
    private func request(_ target: String = "/?state=fixture-state&code=fixture-code", host: String = "127.0.0.1:54321") -> Data {
        Data("GET \(target) HTTP/1.1\r\nHost: \(host)\r\n\r\n".utf8)
    }

    func testCallbackRejectsForgeryDuplicateFieldsWrongEndpointAndOversizedInput() {
        XCTAssertEqual(GoogleOAuthCallback.parse(request(), state: "fixture-state", port: 54321), .code("fixture-code"))
        for target in ["/?state=wrong&code=x", "/?code=x", "/?state=fixture-state&state=fixture-state&code=x",
                       "/?state=fixture-state&code=x&code=y", "/?state=fixture-state&error=access_denied&code=x",
                       "/other?state=fixture-state&code=x", "/?state=fixture-state&code=%00", "/?state=fixture-state&code=%XX"] {
            if case .reject = GoogleOAuthCallback.parse(request(target), state: "fixture-state", port: 54321) {}
            else { XCTFail("Invalid callback accepted: \(target)") }
        }
        XCTAssertEqual(GoogleOAuthCallback.parse(request(host: "untrusted.invalid"), state: "fixture-state", port: 54321), .reject(400))
        XCTAssertEqual(GoogleOAuthCallback.parse(Data(repeating: 65, count: 16_385), state: "fixture-state", port: 54321), .reject(400))
        XCTAssertEqual(GoogleOAuthCallback.parse(request("/?state=fixture-state&error=access_denied"), state: "fixture-state", port: 54321), .denied)
    }

    func testRealLoopbackBindsEphemeralIPv4AcceptsOnceAndHandlesFragmentedRequest() async throws {
        let receiver = GoogleOAuthLoopback(timeout: 5)
        defer { receiver.cancel() }
        let redirect = try await receiver.start(state: "fixture-state")
        XCTAssertEqual(redirect.host, "127.0.0.1")
        let port = try XCTUnwrap(redirect.port)
        XCTAssertGreaterThan(port, 0)
        let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        defer { connection.cancel() }
        let body = request(host: "127.0.0.1:\(port)")
        connection.start(queue: DispatchQueue(label: "afterword-calendar-loopback-test"))
        try await send(Data(body.prefix(8)), connection: connection)
        try await send(Data(body.dropFirst(8)), connection: connection)
        let code = try await receiver.authorizationCode()
        XCTAssertEqual(code, "fixture-code")
        do { _ = try await receiver.authorizationCode(); XCTFail("Callback replay accepted") }
        catch { XCTAssertEqual(error as? GoogleCalendarAuthError, .invalidCallback) }
    }

    func testCancellationAndTimeoutTerminatePendingCallback() async throws {
        for cancelling in [true, false] {
            let receiver = GoogleOAuthLoopback(timeout: cancelling ? 5 : 0.05)
            do {
                _ = try await receiver.start(state: "fixture-state")
                if cancelling { receiver.cancel() }
                _ = try await receiver.authorizationCode()
                XCTFail("Missing callback accepted")
            }
            catch {
                if cancelling { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? GoogleCalendarAuthError, .timedOut) }
            }
            receiver.cancel()
        }
    }

    func testRejectedRequestsDoNotExhaustTheAuthorizationListener() async throws {
        let receiver = GoogleOAuthLoopback(timeout: 20)
        defer { receiver.cancel() }
        let redirect = try await receiver.start(state: "fixture-state")
        let port = try XCTUnwrap(redirect.port)
        for _ in 0..<10 {
            let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
            connection.start(queue: DispatchQueue(label: "afterword-calendar-invalid-callback-test"))
            let data = request("/?state=wrong&code=fixture-code", host: "127.0.0.1:\(port)")
            let response = try await roundTrip(data, connection: connection)
            XCTAssertTrue(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 400"))
        }
        let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        connection.start(queue: DispatchQueue(label: "afterword-calendar-final-callback-test"))
        _ = try await roundTrip(request(host: "127.0.0.1:\(port)"), connection: connection)
        let code = try await receiver.authorizationCode()
        XCTAssertEqual(code, "fixture-code")
    }

    private func roundTrip(_ data: Data, connection: NWConnection) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await self.send(data, connection: connection)
                    var response = Data()
                    while true {
                        let (bytes, complete) = try await self.receive(connection)
                        response.append(bytes)
                        guard response.count <= 4096 else { throw GoogleCalendarAuthError.invalidCallback }
                        if complete { return response }
                    }
                } onCancel: { connection.cancel() }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                connection.cancel()
                throw GoogleCalendarAuthError.timedOut
            }
            defer { group.cancelAll(); connection.cancel() }
            return try await group.next()!
        }
    }

    private func receive(_ connection: NWConnection) async throws -> (Data, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: (data ?? Data(), complete)) }
            }
        }
    }

    private func send(_ data: Data, connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
}
