import Foundation
import XCTest
@testable import AfterwordApp

private final class OAuthHTTPFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    let data: Data
    let length: Int?
    let redirect: Bool

    init(data: Data = Data("{}".utf8), length: Int? = nil, redirect: Bool = false) {
        self.data = data
        self.length = length
        self.redirect = redirect
    }
    func record(_ request: URLRequest) { lock.withLock { requests.append(request) } }
    var received: [URLRequest] { lock.withLock { requests } }
}

private final class OAuthURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixture: OAuthHTTPFixture?
    static func install(_ value: OAuthHTTPFixture?) { lock.withLock { fixture = value } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = Self.lock.withLock({ Self.fixture }), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        fixture.record(request)
        var headers = ["Content-Type": "application/json"]
        if let length = fixture.length { headers["Content-Length"] = String(length) }
        let response = HTTPURLResponse(url: url, statusCode: fixture.redirect ? 307 : 200,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        if fixture.redirect {
            var redirected = request
            redirected.url = URL(string: "https://untrusted.example/collect")!
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class GoogleOAuthTransportTests: XCTestCase, @unchecked Sendable {
    override func tearDown() {
        OAuthURLProtocol.install(nil)
        super.tearDown()
    }

    private func transport(_ fixture: OAuthHTTPFixture) -> GoogleOAuthHTTPTransport {
        OAuthURLProtocol.install(fixture)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OAuthURLProtocol.self]
        return GoogleOAuthHTTPTransport(configuration: configuration)
    }

    private var request: URLRequest {
        var value = URLRequest(url: GoogleCalendarAuth.tokenURL)
        value.httpMethod = "POST"
        value.httpBody = Data("refresh_token=fixture-only".utf8)
        return value
    }

    func testRedirectCannotForwardTokenExchangeBody() async throws {
        let fixture = OAuthHTTPFixture(redirect: true)
        do {
            let result = try await transport(fixture).post(request)
            XCTAssertEqual(result.statusCode, 307)
        } catch {}
        XCTAssertEqual(fixture.received.count, 1)
        XCTAssertEqual(fixture.received.first?.url, GoogleCalendarAuth.tokenURL)
    }

    func testDeclaredAndStreamedPayloadLimitsRejectOversizedResponses() async throws {
        for fixture in [OAuthHTTPFixture(length: 65_537), OAuthHTTPFixture(data: Data(repeating: 32, count: 65_537))] {
            do { _ = try await transport(fixture).post(request); XCTFail("Oversized token response accepted") }
            catch { XCTAssertEqual(error as? GoogleCalendarAuthError, .invalidResponse) }
            XCTAssertEqual(fixture.received.count, 1)
        }
        let fixture = OAuthHTTPFixture(data: Data(repeating: 32, count: 65_536))
        let result = try await transport(fixture).post(request)
        XCTAssertEqual(result.data.count, 65_536)
    }

    func testUnpinnedURLAndNonPOSTNeverReachTransport() async throws {
        let fixture = OAuthHTTPFixture()
        let client = transport(fixture)
        var wrongURL = request
        wrongURL.url = URL(string: "https://untrusted.example/token")
        var wrongMethod = request
        wrongMethod.httpMethod = "GET"
        for value in [wrongURL, wrongMethod] {
            do { _ = try await client.post(value); XCTFail("Unpinned token request accepted") }
            catch { XCTAssertEqual(error as? GoogleCalendarAuthError, .invalidResponse) }
        }
        XCTAssertTrue(fixture.received.isEmpty)
    }
}
