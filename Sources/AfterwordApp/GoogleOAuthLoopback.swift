import Foundation
import Network

protocol GoogleOAuthRedirectReceiving: Sendable {
    func start(state: String) async throws -> URL
    func authorizationCode() async throws -> String
    func cancel()
}

enum GoogleOAuthCallback: Equatable {
    case reject(Int)
    case code(String)
    case denied

    static func parse(_ data: Data, state: String, port: UInt16) -> Self {
        guard data.count <= 16_384, let request = String(data: data, encoding: .utf8),
              let boundary = request.range(of: "\r\n\r\n"), boundary.upperBound == request.endIndex else { return .reject(400) }
        let lines = request.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[0] == "GET", first[2] == "HTTP/1.1" else { return .reject(400) }
        let target = String(first[1])
        guard !target.contains("#"), !target.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return .reject(400) }
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.first == "/", parts.count == 2 else { return .reject(404) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .reject(400) }
            let name = String(line[..<colon]).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard headers[name] == nil else { return .reject(400) }
            headers[name] = value
        }
        guard headers["host"] == "127.0.0.1:\(port)", headers["transfer-encoding"] == nil,
              headers["content-length"].map({ $0 == "0" }) != false else { return .reject(400) }
        var query: [String: String] = [:]
        for item in parts[1].split(separator: "&", omittingEmptySubsequences: false) {
            let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2,
                  let name = String(pair[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  let value = String(pair[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  query[name] == nil else { return .reject(400) }
            query[name] = value
        }
        guard let returnedState = query["state"], equalState(returnedState, state) else { return .reject(400) }
        if query["error"] != nil {
            return query["code"] == nil ? .denied : .reject(400)
        }
        guard let code = query["code"], !code.isEmpty, code.utf8.count <= 4096,
              !code.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return .reject(400) }
        return .code(code)
    }

    private static func equalState(_ left: String, _ right: String) -> Bool {
        let a = Array(left.utf8), b = Array(right.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

final class GoogleOAuthLoopback: GoogleOAuthRedirectReceiving, @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.afterword.calendar-oauth-loopback")
    private let timeout: TimeInterval
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<URL, Error>?
    private var codeContinuation: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?
    private var codeClaimed = false
    private var started = false
    private var state = ""
    private var port: UInt16?
    private var connections: [UUID: NWConnection] = [:]
    private var buffers: [UUID: Data] = [:]

    init(timeout: TimeInterval = 300) { self.timeout = timeout }

    func start(state: String) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !self.started, self.result == nil, !state.isEmpty else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    self.started = true
                    self.state = state
                    self.startContinuation = continuation
                    do {
                        let parameters = NWParameters.tcp
                        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
                        parameters.requiredInterfaceType = .loopback
                        parameters.allowLocalEndpointReuse = false
                        let listener = try NWListener(using: parameters, on: .any)
                        self.listener = listener
                        listener.stateUpdateHandler = { [weak self] value in self?.listenerState(value) }
                        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                        listener.start(queue: self.queue)
                        self.queue.asyncAfter(deadline: .now() + self.timeout) { [weak self] in
                            self?.finish(.failure(GoogleCalendarAuthError.timedOut))
                        }
                    } catch { self.finish(.failure(GoogleCalendarAuthError.invalidCallback)) }
                }
            }
        } onCancel: { self.cancel() }
    }

    func authorizationCode() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard self.started, !self.codeClaimed else {
                        continuation.resume(throwing: GoogleCalendarAuthError.invalidCallback)
                        return
                    }
                    self.codeClaimed = true
                    if let result = self.result { continuation.resume(with: result) }
                    else { self.codeContinuation = continuation }
                }
            }
        } onCancel: { self.cancel() }
    }

    func cancel() { queue.async { self.finish(.failure(CancellationError())) } }

    private func listenerState(_ value: NWListener.State) {
        guard result == nil else { return }
        switch value {
        case .ready:
            guard let assigned = listener?.port?.rawValue,
                  let url = URL(string: "http://127.0.0.1:\(assigned)/") else {
                finish(.failure(GoogleCalendarAuthError.invalidCallback))
                return
            }
            port = assigned
            let continuation = startContinuation
            startContinuation = nil
            continuation?.resume(returning: url)
        case .failed, .cancelled:
            finish(.failure(GoogleCalendarAuthError.invalidCallback))
        default: break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard result == nil, connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        buffers[id] = Data()
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.close(id) }
        receive(id, connection: connection)
    }

    private func receive(_ id: UUID, connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self, self.connections[id] != nil else { return }
            if let data { self.buffers[id]?.append(data) }
            guard let buffer = self.buffers[id], buffer.count <= 16_384 else {
                self.respond(id, status: 431)
                return
            }
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil, let port = self.port {
                switch GoogleOAuthCallback.parse(buffer, state: self.state, port: port) {
                case .reject(let status): self.respond(id, status: status)
                case .denied:
                    self.respond(id, status: 200)
                    self.finish(.failure(GoogleCalendarAuthError.permissionDenied), keeping: id)
                case .code(let code):
                    self.respond(id, status: 200)
                    self.finish(.success(code), keeping: id)
                }
            } else if complete || error != nil { self.close(id) }
            else { self.receive(id, connection: connection) }
        }
    }

    private func respond(_ id: UUID, status: Int) {
        guard let connection = connections[id] else { return }
        let body = status == 200 ? "Return to Afterword to finish connecting. You can close this tab." : "Invalid sign-in response."
        let response = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in self?.close(id) })
    }

    private func finish(_ value: Result<String, Error>, keeping id: UUID? = nil) {
        guard result == nil else { return }
        result = value
        listener?.cancel()
        listener = nil
        for connectionID in Array(connections.keys) where connectionID != id { close(connectionID) }
        if let continuation = startContinuation {
            startContinuation = nil
            switch value {
            case .failure(let error): continuation.resume(throwing: error)
            case .success: continuation.resume(throwing: GoogleCalendarAuthError.invalidCallback)
            }
        }
        codeContinuation?.resume(with: value)
        codeContinuation = nil
        state = ""
    }

    private func close(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
        buffers.removeValue(forKey: id)
    }
}
