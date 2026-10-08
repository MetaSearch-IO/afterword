import Foundation
import XCTest
@testable import AfterwordApp

final class GoogleCalendarAuthTests: XCTestCase, @unchecked Sendable {
    private final class Store: CalendarCredentialStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?
        private var interactions: [Bool] = []
        private var saveInteractions: [Bool] = []
        private var isLocked = false
        private var saveFails = false
        var locked: Bool {
            get { lock.withLock { isLocked } }
            set { lock.withLock { isLocked = newValue } }
        }
        var failSave: Bool {
            get { lock.withLock { saveFails } }
            set { lock.withLock { saveFails = newValue } }
        }
        func load(allowInteraction: Bool) throws -> Data? {
            try lock.withLock {
                interactions.append(allowInteraction)
                if isLocked { throw CalendarCredentialStoreError.locked }
                return data
            }
        }
        func save(_ data: Data, allowInteraction: Bool) throws {
            try lock.withLock {
                saveInteractions.append(allowInteraction)
                if saveFails { throw CalendarCredentialStoreError.locked }
                self.data = data
            }
        }
        func snapshot() -> (Data?, [Bool], [Bool]) { lock.withLock { (data, interactions, saveInteractions) } }
    }

    private actor Transport: GoogleOAuthTransport {
        var requests: [URLRequest] = []
        var reply: GoogleOAuthResponse?
        var waiting: [CheckedContinuation<GoogleOAuthResponse, Error>] = []
        init(reply: GoogleOAuthResponse? = nil) { self.reply = reply }
        func post(_ request: URLRequest) async throws -> GoogleOAuthResponse {
            requests.append(request)
            if let reply { return reply }
            return try await withCheckedThrowingContinuation { waiting.append($0) }
        }
        func count() -> Int { requests.count }
        func first() -> URLRequest? { requests.first }
        func release(_ value: GoogleOAuthResponse) {
            reply = value
            let pending = waiting
            waiting = []
            for continuation in pending { continuation.resume(returning: value) }
        }
    }

    private final class Receiver: GoogleOAuthRedirectReceiving, @unchecked Sendable {
        private let lock = NSLock()
        private var state: String?
        let redirect: URL
        init(redirect: URL = URL(string: "http://127.0.0.1:54321/")!) { self.redirect = redirect }
        func start(state: String) async throws -> URL {
            lock.withLock { self.state = state }
            return redirect
        }
        func authorizationCode() async throws -> String { "fixture+code/one=" }
        func cancel() {}
        func savedState() -> String? { lock.withLock { state } }
    }

    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    private var client: GoogleOAuthClient {
        GoogleOAuthClient(clientID: "fixture.apps.googleusercontent.com", clientSecret: "fixture&secret+=/")
    }

    private func configuration(_ client: GoogleOAuthClient) throws -> Data {
        var encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(client)) as! [String: Any]
        encoded["token_uri"] = "https://untrusted.invalid/token"
        encoded["auth_uri"] = "https://untrusted.invalid/auth"
        return try JSONSerialization.data(withJSONObject: ["installed": encoded])
    }

    private func response(access: String = "new-access", refresh: String? = "new-refresh", scope: String? = nil,
                          omitScope: Bool = false) throws -> GoogleOAuthResponse {
        var value: [String: Any] = ["access_token": access, "token_type": "Bearer", "expires_in": 3600]
        if let refresh { value["refresh_token"] = refresh }
        if !omitScope { value["scope"] = scope ?? GoogleCalendarAuth.scopes.sorted().joined(separator: " ") }
        return GoogleOAuthResponse(statusCode: 200, data: try JSONSerialization.data(withJSONObject: value))
    }

    private func configuredStore(expired: Bool = true) throws -> Store {
        let store = Store()
        let tokens = GoogleOAuthTokens(clientID: client.clientID, accessToken: "old-access", refreshToken: "old-refresh",
                                       expiresAt: date.addingTimeInterval(expired ? -1 : 3600), scopes: GoogleCalendarAuth.scopes)
        try store.save(JSONEncoder().encode(GoogleOAuthCredentials(client: client, tokens: tokens)), allowInteraction: true)
        return store
    }

    private func waitForRequest(_ transport: Transport) async throws {
        let deadline = Date().addingTimeInterval(5)
        while await transport.count() == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let count = await transport.count()
        XCTAssertEqual(count, 1)
    }

    func testPKCEVectorAndDesktopImportRejectWrongTypesWithoutTouchingPriorGrant() async throws {
        XCTAssertEqual(GoogleCalendarAuth.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let store = try configuredStore(expired: false)
        let original = store.snapshot().0
        let transport = Transport()
        let auth = GoogleCalendarAuth(store: store, transport: transport)
        for data in [Data("{\"web\":{}}".utf8), Data("{}".utf8), Data(repeating: 32, count: 131_073),
                     Data("{\"installed\":{\"client_id\":\".apps.googleusercontent.com\"}}".utf8)] {
            do { try await auth.importClientConfiguration(data); XCTFail("Invalid Desktop config accepted") }
            catch { XCTAssertEqual(error as? GoogleCalendarAuthError, .invalidConfiguration) }
        }
        XCTAssertEqual(store.snapshot().0, original)
        try await auth.importClientConfiguration(configuration(GoogleOAuthClient(clientID: client.clientID, clientSecret: nil)))
        let status = try await auth.restore()
        XCTAssertEqual(status, .disconnected)
        XCTAssertNil(try JSONDecoder().decode(GoogleOAuthCredentials.self, from: XCTUnwrap(store.snapshot().0)).tokens)
    }

    func testRestoreDoesNotPromptAndDistinguishesLockedFromMissingCredentials() async throws {
        let store = Store()
        let auth = GoogleCalendarAuth(store: store, transport: Transport())
        let missing = try await auth.restore()
        XCTAssertEqual(missing, .unconfigured)
        store.locked = true
        let locked = try await auth.restore()
        XCTAssertEqual(locked, .keychainLocked)
        XCTAssertEqual(store.snapshot().1, [false, false])
    }

    func testConnectPinsEndpointsUsesOnlyReadonlyScopesAndEncodesSecretsInPOSTBody() async throws {
        let store = Store()
        let transport = Transport(reply: try response())
        let receiver = Receiver()
        let auth = GoogleCalendarAuth(store: store, transport: transport, makeReceiver: { receiver }, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        try await auth.importClientConfiguration(configuration(client))
        try await auth.connect { url in
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, "accounts.google.com")
            XCTAssertEqual(url.path, "/o/oauth2/v2/auth")
            let values = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
            XCTAssertEqual(Set(values["scope"]!.split(separator: " ").map(String.init)), GoogleCalendarAuth.scopes)
            XCTAssertEqual(values["redirect_uri"], receiver.redirect.absoluteString)
            XCTAssertEqual(values["state"], receiver.savedState())
            XCTAssertEqual(values["state"]?.count, 43)
            XCTAssertEqual(values["code_challenge_method"], "S256")
            XCTAssertEqual(values["code_challenge"]?.count, 43)
            XCTAssertNil(values["client_secret"])
            return true
        }
        let capturedRequest = await transport.first()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url, GoogleCalendarAuth.tokenURL)
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(String(data: XCTUnwrap(request.httpBody), encoding: .utf8))
        let fields = Dictionary(uniqueKeysWithValues: URLComponents(string: "http://fixture.invalid/?" + body)!.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(fields["client_secret"], client.clientSecret)
        XCTAssertEqual(fields["code"], "fixture+code/one=")
        XCTAssertEqual(fields["code_verifier"]?.count, 43)
        XCTAssertEqual(fields["redirect_uri"], receiver.redirect.absoluteString)
        let token = try await auth.accessToken()
        XCTAssertEqual(token, "new-access")
        let status = try await auth.restore()
        XCTAssertEqual(status, .connected)
        XCTAssertEqual(store.snapshot().2, [true, true])
    }

    func testPartialOrBroaderScopesCannotPersistConnectedGrant() async throws {
        for scope in [GoogleCalendarAuth.scopes.sorted()[0], GoogleCalendarAuth.scopes.sorted().joined(separator: " ") + " openid"] {
            let store = Store()
            let transport = Transport(reply: try response(scope: scope))
            let auth = GoogleCalendarAuth(store: store, transport: transport, makeReceiver: { Receiver() })
            try await auth.importClientConfiguration(configuration(client))
            do { try await auth.connect { _ in true }; XCTFail("Unexpected grant accepted") }
            catch { XCTAssertEqual(error as? GoogleCalendarAuthError, .insufficientScopes) }
            let status = try await auth.restore()
            XCTAssertEqual(status, .disconnected)
        }
    }

    func testConcurrentRefreshCoalescesAndPreservesUnrotatedRefreshToken() async throws {
        let store = try configuredStore()
        let transport = Transport()
        let auth = GoogleCalendarAuth(store: store, transport: transport, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        async let first = auth.accessToken()
        async let second = auth.accessToken()
        try await waitForRequest(transport)
        await transport.release(try response(refresh: nil, omitScope: true))
        let values = try await [first, second]
        XCTAssertEqual(values, ["new-access", "new-access"])
        let count = await transport.count()
        XCTAssertEqual(count, 1)
        let saved = try JSONDecoder().decode(GoogleOAuthCredentials.self, from: XCTUnwrap(store.snapshot().0))
        XCTAssertEqual(saved.tokens?.refreshToken, "old-refresh")
        XCTAssertEqual(saved.tokens?.scopes, GoogleCalendarAuth.scopes)
        XCTAssertEqual(store.snapshot().2, [true, false])
    }

    func testDisconnectDuringRefreshAndCodeExchangeRejectsLateSuccess() async throws {
        for connecting in [false, true] {
            let store = try configuredStore()
            let transport = Transport()
            let auth = GoogleCalendarAuth(store: store, transport: transport, makeReceiver: { Receiver() }, now: { Date(timeIntervalSince1970: 1_700_000_000) })
            let operation = Task {
                if connecting { try await auth.connect { _ in true } }
                else { _ = try await auth.accessToken() }
            }
            try await waitForRequest(transport)
            try await auth.disconnect()
            await transport.release(try response())
            do { try await operation.value; XCTFail("Late grant accepted") }
            catch { XCTAssertTrue(error is CancellationError) }
            let saved = try JSONDecoder().decode(GoogleOAuthCredentials.self, from: XCTUnwrap(store.snapshot().0))
            XCTAssertNil(saved.tokens)
            let status = try await auth.restore()
            XCTAssertEqual(status, .disconnected)
        }
    }

    func testInvalidGrantClearsTokensAndDisconnectNeverCallsGoogle() async throws {
        let store = try configuredStore()
        let transport = Transport(reply: GoogleOAuthResponse(statusCode: 400, data: Data("{\"error\":\"invalid_grant\",\"error_description\":\"fixture-private-value\"}".utf8)))
        let auth = GoogleCalendarAuth(store: store, transport: transport, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        do { _ = try await auth.accessToken(); XCTFail("Invalid grant accepted") }
        catch {
            XCTAssertEqual(error as? GoogleCalendarAuthError, .reconnectRequired)
            XCTAssertFalse(error.localizedDescription.contains("fixture-private-value"))
        }
        try await auth.disconnect()
        let count = await transport.count()
        XCTAssertEqual(count, 1)
        XCTAssertNil(try JSONDecoder().decode(GoogleOAuthCredentials.self, from: XCTUnwrap(store.snapshot().0)).tokens)
        XCTAssertEqual(store.snapshot().2, [true, false, true])
    }

    func testInvalidGrantWithFailedNoninteractiveCleanupCannotReuseCachedToken() async throws {
        let store = try configuredStore(expired: false)
        let transport = Transport(reply: GoogleOAuthResponse(statusCode: 400, data: Data("{\"error\":\"invalid_grant\"}".utf8)))
        let auth = GoogleCalendarAuth(store: store, transport: transport, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        _ = try await auth.restore()
        store.failSave = true
        do { _ = try await auth.accessToken(forceRefresh: true); XCTFail("Failed cleanup was accepted") }
        catch { XCTAssertTrue(error is CalendarCredentialStoreError) }
        do { _ = try await auth.accessToken(); XCTFail("Revoked cached token reused") }
        catch { XCTAssertEqual(error as? GoogleCalendarAuthError, .notConnected) }
        let status = try await auth.restore()
        XCTAssertEqual(status, .disconnected)
        let count = await transport.count()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.snapshot().2, [true, false])
        XCTAssertNotNil(try JSONDecoder().decode(GoogleOAuthCredentials.self, from: XCTUnwrap(store.snapshot().0)).tokens)
    }

    func testFailedDisconnectStillStopsLocalUseAndDoesNotClaimCredentialsWereRemoved() async throws {
        let store = try configuredStore(expired: false)
        let transport = Transport()
        let auth = GoogleCalendarAuth(store: store, transport: transport, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let original = try await auth.restore()
        XCTAssertEqual(original, .connected)
        store.failSave = true
        do { try await auth.disconnect(); XCTFail("Failed Keychain write reported success") }
        catch { XCTAssertTrue(error is CalendarCredentialStoreError) }
        do { _ = try await auth.accessToken(); XCTFail("Disconnected instance reused credentials") }
        catch { XCTAssertEqual(error as? GoogleCalendarAuthError, .notConnected) }
        let local = try await auth.restore()
        XCTAssertEqual(local, .disconnected)
        let count = await transport.count()
        XCTAssertEqual(count, 0)
        let persisted = try JSONDecoder().decode(GoogleOAuthCredentials.self, from: XCTUnwrap(store.snapshot().0))
        XCTAssertNotNil(persisted.tokens)
        let reopened = GoogleCalendarAuth(store: store, transport: transport)
        let restored = try await reopened.restore()
        XCTAssertEqual(restored, .connected)
    }

    func testClientReplacementDuringRefreshCannotRestoreOldGrant() async throws {
        let store = try configuredStore()
        let transport = Transport()
        let auth = GoogleCalendarAuth(store: store, transport: transport, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let refresh = Task { try await auth.accessToken() }
        try await waitForRequest(transport)
        let replacement = GoogleOAuthClient(clientID: "replacement.apps.googleusercontent.com", clientSecret: nil)
        try await auth.importClientConfiguration(configuration(replacement))
        await transport.release(try response())
        do { _ = try await refresh.value; XCTFail("Previous client's token was returned") }
        catch { XCTAssertTrue(error is CancellationError) }
        let persisted = try JSONDecoder().decode(GoogleOAuthCredentials.self, from: XCTUnwrap(store.snapshot().0))
        XCTAssertEqual(persisted.client.clientID, replacement.clientID)
        XCTAssertNil(persisted.tokens)
    }

    func testBrowserFailureAndNonLoopbackRedirectCannotExchangeCode() async throws {
        for redirect in [URL(string: "http://127.0.0.1:54321/")!, URL(string: "https://untrusted.invalid/")!] {
            let store = Store()
            let transport = Transport()
            let auth = GoogleCalendarAuth(store: store, transport: transport, makeReceiver: { Receiver(redirect: redirect) })
            try await auth.importClientConfiguration(configuration(client))
            do { try await auth.connect { _ in false }; XCTFail("Invalid browser flow accepted") }
            catch { XCTAssertTrue(error is GoogleCalendarAuthError) }
            let count = await transport.count()
            XCTAssertEqual(count, 0)
        }
    }
}
