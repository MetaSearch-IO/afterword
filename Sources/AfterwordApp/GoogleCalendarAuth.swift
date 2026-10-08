import CryptoKit
import Foundation
import Security

enum GoogleCalendarAuthStatus: Sendable, Equatable {
    case unconfigured, disconnected, connected, keychainLocked
}

enum GoogleCalendarAuthError: LocalizedError, Sendable, Equatable {
    case invalidConfiguration, invalidStoredCredentials, notConfigured, notConnected
    case browserUnavailable, permissionDenied, invalidCallback, timedOut, invalidResponse, insufficientScopes
    case serverRejected, reconnectRequired, randomUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Choose the JSON file for a Google OAuth Desktop app client."
        case .invalidStoredCredentials: "Stored Google Calendar configuration is invalid. Import the Desktop client JSON again."
        case .notConfigured: "Import your Google OAuth Desktop client JSON before signing in."
        case .notConnected: "Sign in to Google Calendar first."
        case .browserUnavailable: "The default browser could not be opened."
        case .permissionDenied: "Google Calendar access was not granted."
        case .invalidCallback: "The sign-in response could not be validated. Try signing in again."
        case .timedOut: "Google Calendar sign-in timed out. Try signing in again."
        case .invalidResponse: "Google returned an invalid authorization response."
        case .insufficientScopes: "Grant both requested read-only Calendar permissions using a dedicated Desktop client."
        case .serverRejected: "Google Calendar authorization failed. Try signing in again."
        case .reconnectRequired: "Google Calendar authorization expired or was revoked. Sign in again."
        case .randomUnavailable: "Secure sign-in could not be initialized."
        }
    }
}

struct GoogleOAuthClient: Codable, Sendable {
    let clientID: String
    let clientSecret: String?

    enum CodingKeys: String, CodingKey { case clientID = "client_id", clientSecret = "client_secret" }

    static func imported(_ data: Data) throws -> Self {
        struct Download: Decodable { let installed: GoogleOAuthClient }
        guard data.count <= 131_072, let client = try? JSONDecoder().decode(Download.self, from: data).installed,
              client.isValid else { throw GoogleCalendarAuthError.invalidConfiguration }
        return client
    }

    var isValid: Bool {
        clientID.count > ".apps.googleusercontent.com".count && clientID.count <= 512 && clientID.hasSuffix(".apps.googleusercontent.com")
            && clientID.utf8.allSatisfy { (45...46).contains($0) || (48...57).contains($0)
                || (65...90).contains($0) || $0 == 95 || (97...122).contains($0) }
            && clientSecret.map { !$0.isEmpty && $0.utf8.count <= 4096 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) } != false
    }
}

struct GoogleOAuthTokens: Codable, Sendable {
    let clientID: String
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let scopes: Set<String>

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id", accessToken = "access_token", refreshToken = "refresh_token"
        case expiresAt = "expires_at", scopes
    }
}

struct GoogleOAuthCredentials: Codable, Sendable {
    var schemaVersion = 1
    let client: GoogleOAuthClient
    var tokens: GoogleOAuthTokens?

    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", client, tokens }
}

struct GoogleOAuthResponse: Sendable {
    let statusCode: Int
    let data: Data
}

protocol GoogleOAuthTransport: Sendable {
    func post(_ request: URLRequest) async throws -> GoogleOAuthResponse
}

private final class OAuthRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct GoogleOAuthHTTPTransport: GoogleOAuthTransport {
    private let session: URLSession

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpAdditionalHeaders = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration, delegate: OAuthRedirectBlocker(), delegateQueue: nil)
    }

    func post(_ request: URLRequest) async throws -> GoogleOAuthResponse {
        guard request.httpMethod == "POST", request.url == GoogleCalendarAuth.tokenURL else {
            throw GoogleCalendarAuthError.invalidResponse
        }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.url == GoogleCalendarAuth.tokenURL,
              response.expectedContentLength <= 65_536 else { throw GoogleCalendarAuthError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 65_536 else { throw GoogleCalendarAuthError.invalidResponse }
            data.append(byte)
        }
        return GoogleOAuthResponse(statusCode: http.statusCode, data: data)
    }
}

actor GoogleCalendarAuth: CalendarAccessTokenProviding {
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    static let scopes: Set<String> = ["https://www.googleapis.com/auth/calendar.events.readonly",
                                      "https://www.googleapis.com/auth/calendar.calendarlist.readonly"]
    private let store: any CalendarCredentialStoring
    private let transport: any GoogleOAuthTransport
    private let makeReceiver: @Sendable () -> any GoogleOAuthRedirectReceiving
    private let now: @Sendable () -> Date
    private var credentials: GoogleOAuthCredentials?
    private var generation = 0
    private var receiver: (any GoogleOAuthRedirectReceiving)?
    private var refreshTask: Task<GoogleOAuthTokens, Error>?
    private var refreshID: UUID?
    private var exchangeTask: Task<GoogleOAuthTokens, Error>?
    private var locallyDisconnected = false

    init(store: any CalendarCredentialStoring = KeychainCalendarCredentialStore(),
         transport: any GoogleOAuthTransport = GoogleOAuthHTTPTransport(),
         makeReceiver: @escaping @Sendable () -> any GoogleOAuthRedirectReceiving = { GoogleOAuthLoopback() },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.transport = transport
        self.makeReceiver = makeReceiver
        self.now = now
    }

    func restore() async throws -> GoogleCalendarAuthStatus {
        do {
            credentials = try load(allowInteraction: false)
            guard let credentials else { return .unconfigured }
            return credentials.tokens == nil || locallyDisconnected ? .disconnected : .connected
        } catch CalendarCredentialStoreError.locked {
            credentials = nil
            return .keychainLocked
        }
    }

    func importClientConfiguration(_ data: Data) async throws {
        let client = try GoogleOAuthClient.imported(data)
        invalidatePending()
        try save(GoogleOAuthCredentials(client: client, tokens: nil), allowInteraction: true)
        locallyDisconnected = false
    }

    func connect(openBrowser: @escaping @MainActor @Sendable (URL) async -> Bool) async throws {
        invalidatePending()
        let epoch = generation
        guard let current = try load(allowInteraction: true) else { throw GoogleCalendarAuthError.notConfigured }
        let verifier = try Self.randomString()
        let state = try Self.randomString()
        let flow = makeReceiver()
        receiver = flow
        defer {
            flow.cancel()
            if generation == epoch { receiver = nil; exchangeTask = nil }
        }
        try await withTaskCancellationHandler {
            let redirect = try await flow.start(state: state)
            try check(epoch)
            guard let components = URLComponents(url: redirect, resolvingAgainstBaseURL: false),
                  components.scheme == "http", components.host == "127.0.0.1", components.path == "/",
                  components.port.map({ (1...65535).contains($0) }) == true,
                  components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else {
                throw GoogleCalendarAuthError.invalidCallback
            }
            let url = Self.authorizationURL(client: current.client, redirect: redirect, verifier: verifier, state: state)
            guard await openBrowser(url) else { throw GoogleCalendarAuthError.browserUnavailable }
            try check(epoch)
            let code = try await flow.authorizationCode()
            try check(epoch)
            var fields = ["client_id": current.client.clientID, "code": code, "code_verifier": verifier,
                          "grant_type": "authorization_code", "redirect_uri": redirect.absoluteString]
            if let secret = current.client.clientSecret { fields["client_secret"] = secret }
            let request = Task { [fields] in try await self.exchange(fields, client: current.client, previous: nil) }
            exchangeTask = request
            let tokens = try await withTaskCancellationHandler { try await request.value } onCancel: { request.cancel() }
            try check(epoch)
            try save(GoogleOAuthCredentials(client: current.client, tokens: tokens), allowInteraction: true)
            locallyDisconnected = false
        } onCancel: { flow.cancel() }
    }

    func cancelConnect() {
        invalidatePending()
    }

    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard !locallyDisconnected else { throw GoogleCalendarAuthError.notConnected }
        let current: GoogleOAuthCredentials
        if let cached = credentials { current = cached }
        else {
            guard let loaded = try load(allowInteraction: false) else { throw GoogleCalendarAuthError.notConfigured }
            current = loaded
            credentials = loaded
        }
        guard let tokens = current.tokens else { throw GoogleCalendarAuthError.notConnected }
        let epoch = generation
        if !forceRefresh && tokens.expiresAt.timeIntervalSince(now()) > 60 { return tokens.accessToken }
        let task: Task<GoogleOAuthTokens, Error>
        if let pending = refreshTask { task = pending }
        else {
            let identifier = UUID()
            refreshID = identifier
            let pending = Task { try await self.refresh(current, epoch: epoch, identifier: identifier) }
            refreshTask = pending
            task = pending
        }
        let renewed = try await task.value
        try check(epoch)
        return renewed.accessToken
    }

    func disconnect() async throws {
        invalidatePending()
        locallyDisconnected = true
        let current: GoogleOAuthCredentials?
        if let cached = credentials { current = cached } else { current = try load(allowInteraction: true) }
        guard let current else { return }
        try save(GoogleOAuthCredentials(client: current.client, tokens: nil), allowInteraction: true)
    }

    private func refresh(_ current: GoogleOAuthCredentials, epoch: Int, identifier: UUID) async throws -> GoogleOAuthTokens {
        defer {
            if refreshID == identifier { refreshTask = nil; refreshID = nil }
        }
        guard let previous = current.tokens else { throw GoogleCalendarAuthError.notConnected }
        var fields = ["client_id": current.client.clientID, "refresh_token": previous.refreshToken, "grant_type": "refresh_token"]
        if let secret = current.client.clientSecret { fields["client_secret"] = secret }
        do {
            try check(epoch)
            let tokens = try await exchange(fields, client: current.client, previous: previous)
            try check(epoch)
            try save(GoogleOAuthCredentials(client: current.client, tokens: tokens), allowInteraction: false)
            return tokens
        } catch GoogleCalendarAuthError.reconnectRequired {
            try check(epoch)
            locallyDisconnected = true
            credentials = GoogleOAuthCredentials(client: current.client, tokens: nil)
            try save(GoogleOAuthCredentials(client: current.client, tokens: nil), allowInteraction: false)
            throw GoogleCalendarAuthError.reconnectRequired
        }
    }

    private func exchange(_ fields: [String: String], client: GoogleOAuthClient, previous: GoogleOAuthTokens?) async throws -> GoogleOAuthTokens {
        try Task.checkCancellation()
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formData(fields)
        let response = try await transport.post(request)
        try Task.checkCancellation()
        guard response.data.count <= 65_536,
              let value = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw GoogleCalendarAuthError.invalidResponse
        }
        if response.statusCode != 200 {
            if value["error"] as? String == "invalid_grant" { throw GoogleCalendarAuthError.reconnectRequired }
            throw GoogleCalendarAuthError.serverRejected
        }
        guard let access = value["access_token"] as? String, Self.validToken(access),
              let type = value["token_type"] as? String, type.caseInsensitiveCompare("Bearer") == .orderedSame,
              let seconds = value["expires_in"] as? NSNumber, CFGetTypeID(seconds) != CFBooleanGetTypeID(),
              seconds.doubleValue.isFinite, seconds.doubleValue > 0, seconds.doubleValue <= 86_400 else {
            throw GoogleCalendarAuthError.invalidResponse
        }
        let granted: Set<String>
        if let scope = value["scope"] as? String { granted = Set(scope.split(whereSeparator: \.isWhitespace).map(String.init)) }
        else if value["scope"] == nil, let previous { granted = previous.scopes }
        else { throw GoogleCalendarAuthError.insufficientScopes }
        guard granted == Self.scopes else { throw GoogleCalendarAuthError.insufficientScopes }
        let refresh: String
        if let returned = value["refresh_token"] as? String { refresh = returned }
        else if value["refresh_token"] == nil, let previous { refresh = previous.refreshToken }
        else { throw GoogleCalendarAuthError.invalidResponse }
        guard Self.validToken(refresh) else { throw GoogleCalendarAuthError.invalidResponse }
        return GoogleOAuthTokens(clientID: client.clientID, accessToken: access, refreshToken: refresh,
                                 expiresAt: now().addingTimeInterval(seconds.doubleValue), scopes: granted)
    }

    private func load(allowInteraction: Bool) throws -> GoogleOAuthCredentials? {
        guard let data = try store.load(allowInteraction: allowInteraction) else { return nil }
        guard data.count <= 65_536, let value = try? JSONDecoder().decode(GoogleOAuthCredentials.self, from: data),
              value.schemaVersion == 1, value.client.isValid else { throw GoogleCalendarAuthError.invalidStoredCredentials }
        if let tokens = value.tokens {
            guard tokens.clientID == value.client.clientID, Self.validToken(tokens.accessToken), Self.validToken(tokens.refreshToken),
                  tokens.expiresAt.timeIntervalSinceReferenceDate.isFinite, tokens.scopes == Self.scopes else {
                throw GoogleCalendarAuthError.invalidStoredCredentials
            }
        }
        return value
    }

    private func save(_ value: GoogleOAuthCredentials, allowInteraction: Bool) throws {
        try store.save(JSONEncoder().encode(value), allowInteraction: allowInteraction)
        credentials = value
    }

    private func invalidatePending() {
        generation += 1
        receiver?.cancel()
        receiver = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshID = nil
        exchangeTask?.cancel()
        exchangeTask = nil
    }

    private func check(_ epoch: Int) throws {
        try Task.checkCancellation()
        guard epoch == generation else { throw CancellationError() }
    }

    private static func validToken(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.count <= 16_384 && token.utf8.allSatisfy { (33...126).contains($0) }
    }

    static func challenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func randomString() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw GoogleCalendarAuthError.randomUnavailable }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func authorizationURL(client: GoogleOAuthClient, redirect: URL, verifier: String, state: String) -> URL {
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = ["client_id": client.clientID, "redirect_uri": redirect.absoluteString,
                          "response_type": "code", "scope": scopes.sorted().joined(separator: " "),
                          "code_challenge_method": "S256", "code_challenge": challenge(verifier), "state": state,
                          "access_type": "offline", "prompt": "consent"].map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }

    static func formData(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(fields.sorted(by: { $0.key < $1.key }).map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }
}
