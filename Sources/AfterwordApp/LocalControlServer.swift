import Darwin
import Foundation

struct LocalControlReply: Encodable, Sendable {
    let ok: Bool
    let status: String?
    let runID: String?
    let error: String?

    static func accepted(status: String, runID: String?) -> Self {
        Self(ok: true, status: status, runID: runID, error: nil)
    }

    static func rejected(_ error: String) -> Self {
        Self(ok: false, status: nil, runID: nil, error: error)
    }
}

final class LocalControlServer: @unchecked Sendable {
    private let descriptor: Int32
    private let path: String
    private let process: @MainActor @Sendable (String) -> LocalControlReply

    static var defaultSocketURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Afterword/cli/control.sock")
    }

    init(socketURL: URL = defaultSocketURL,
         process: @escaping @MainActor @Sendable (String) -> LocalControlReply) throws {
        let directory = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else {
            throw NSError(domain: "AfterwordCLI", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The local command directory is not private."])
        }
        let path = socketURL.path
        var address = sockaddr_un()
        let bytes = Array(path.utf8CString).map { UInt8(bitPattern: $0) }
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw NSError(domain: "AfterwordCLI", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "The local command socket path is too long."])
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        do {
            if lstat(path, &info) == 0 {
                guard info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFSOCK else {
                    throw NSError(domain: "AfterwordCLI", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "The local command path is not an owned socket."])
                }
                let active = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                guard active != 0, errno == ECONNREFUSED, unlink(path) == 0 else {
                    throw NSError(domain: "AfterwordCLI", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: "Another Afterword command server owns the socket."])
                }
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 8) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            close(descriptor)
            throw error
        }
        self.descriptor = descriptor
        self.path = path
        self.process = process
        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                let client = accept(descriptor, nil, nil)
                if client < 0 { break }
                _ = fcntl(client, F_SETFD, FD_CLOEXEC)
                Task.detached { [self] in await handle(client) }
            }
        }
    }

    func stop() {
        shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
        unlink(path)
    }

    private func handle(_ client: Int32) async {
        defer { close(client) }
        var user = uid_t()
        var group = gid_t()
        guard getpeereid(client, &user, &group) == 0, user == geteuid() else { return }
        var noSignal: Int32 = 1
        _ = withUnsafePointer(to: &noSignal) {
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        var input = Data()
        var byte: UInt8 = 0
        while input.count < 4_096 {
            let count = read(client, &byte, 1)
            if count <= 0 { return }
            if byte == 10 { break }
            input.append(byte)
        }
        let reply: LocalControlReply
        if let request = try? JSONSerialization.jsonObject(with: input) as? [String: String],
           request["command"] == "process", let id = request["meeting_id"] {
            reply = await process(id)
        } else {
            reply = .rejected("Unsupported local command.")
        }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(reply) + Data([10]) else { return }
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                let count = write(client, base.advanced(by: sent), bytes.count - sent)
                if count > 0 { sent += count }
                else if count == 0 || errno != EINTR { break }
            }
        }
    }
}
