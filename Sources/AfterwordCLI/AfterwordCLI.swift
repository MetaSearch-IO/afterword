import AfterwordCore
import Darwin
import Foundation

private struct CommandError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct MeetingStatus: Codable {
    let id: String
    let title: String
    let startedAt: String
    let durationSeconds: Int
    let captureState: String
    let processingStatus: String
    let processingStage: String?
    let processingError: String?
    let processingRunID: String?
    let hasTranscript: Bool
    let hasNotes: Bool

    init(_ meeting: Meeting) {
        id = meeting.id
        title = meeting.title
        startedAt = meeting.startedAt
        durationSeconds = Int(meeting.retainedDurationUS / 1_000_000)
        captureState = meeting.captureState.rawValue
        processingStatus = meeting.processingStatus
        processingStage = meeting.processingStage
        processingError = meeting.processingError
        processingRunID = meeting.processingRunID
        hasTranscript = meeting.activeRevisionID != nil
        hasNotes = meeting.activeSummaryID != nil
    }
}

private struct CommandReply: Codable {
    let ok: Bool
    let status: String?
    let runID: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok, status, error
        case runID = "run_id"
    }
}

@main
private enum AfterwordCLI {
    private static let usage = "Usage: afterwordctl list [--json] | status [ID|latest] [--json] | record | stop | process [ID|latest] | notes [ID|latest] | label ID SEGMENT_ID SPEAKER_ID | watch [ID|latest] | trim ID START_SECONDS END_SECONDS | import FILE | storage [--json] | delete-audio ID --yes [--erase-untranscribed]"

    static func main() {
        do { try run(Array(CommandLine.arguments.dropFirst())) }
        catch {
            fputs("afterwordctl: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static var store: MeetingStore {
        if let override = ProcessInfo.processInfo.environment["AFTERWORD_MEETINGS_ROOT"] {
            return MeetingStore(rootURL: URL(fileURLWithPath: override))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return MeetingStore(rootURL: support.appendingPathComponent("Afterword/meetings"))
    }

    private static var socketPath: String {
        if let override = ProcessInfo.processInfo.environment["AFTERWORD_CONTROL_SOCKET"] { return override }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Afterword/cli/control.sock").path
    }

    private static func run(_ arguments: [String]) throws {
        guard let command = arguments.first else {
            print(usage)
            return
        }
        if command == "--help" || command == "help" {
            print(usage)
            return
        }
        guard ["list", "status", "record", "stop", "process", "notes", "label", "watch", "trim", "import", "storage", "delete-audio"].contains(command) else {
            throw CommandError(message: "Unknown command: \(command). Run afterwordctl --help.")
        }
        let json = arguments.contains("--json")
        let confirmed = arguments.contains("--yes")
        let eraseUntranscribed = arguments.contains("--erase-untranscribed")
        let operands = arguments.dropFirst().filter { $0 != "--json" && $0 != "--yes" && $0 != "--erase-untranscribed" }
        if confirmed && command != "delete-audio" { throw CommandError(message: "--yes is only valid with delete-audio.") }
        if eraseUntranscribed && command != "delete-audio" {
            throw CommandError(message: "--erase-untranscribed is only valid with delete-audio.")
        }
        if command == "label" {
            guard operands.count == 3 else { throw CommandError(message: "Usage: afterwordctl label ID SEGMENT_ID SPEAKER_ID") }
        } else if command == "trim" {
            guard operands.count == 3 else { throw CommandError(message: "Usage: afterwordctl trim ID START_SECONDS END_SECONDS") }
        } else if command == "import" {
            guard operands.count == 1 else { throw CommandError(message: "Usage: afterwordctl import FILE") }
        } else if command == "delete-audio" {
            guard operands.count == 1, confirmed else {
                throw CommandError(message: "Permanently removes saved audio and prepared WAVs while retaining results. Usage: afterwordctl delete-audio ID --yes")
            }
        } else if command == "storage" {
            guard operands.isEmpty else { throw CommandError(message: "Usage: afterwordctl storage [--json]") }
        } else {
            guard operands.count <= (["list", "record", "stop"].contains(command) ? 0 : 1) else {
                throw CommandError(message: "Too many arguments for \(command).")
            }
        }
        if command == "record" || command == "stop" {
            let reply = try requestProcessing(id: "", command: command)
            guard reply.ok else { throw CommandError(message: reply.error ?? "The app rejected the command.") }
            if json { try printJSON(reply) } else { print(reply.status ?? command) }
            return
        }
        if command == "trim" {
            guard let start = Int64(operands[operands.index(operands.startIndex, offsetBy: 1)]),
                  let end = Int64(operands[operands.index(operands.startIndex, offsetBy: 2)]),
                  start >= 0, end > start, end <= Int64.max / 1_000_000 else {
                throw CommandError(message: "Trim times must be increasing whole seconds.")
            }
            let meeting = try AudioTrim.create(from: operands[operands.startIndex], in: store,
                startUS: start * 1_000_000, endUS: end * 1_000_000)
            notifyAppOfNewMeeting(id: meeting.id)
            if json { try printJSON(MeetingStatus(meeting)) } else { print(meeting.id) }
            return
        }
        if command == "import" {
            let meeting = try AudioImport.importFile(at: URL(fileURLWithPath: operands[operands.startIndex]), into: store)
            notifyAppOfNewMeeting(id: meeting.id)
            if json { try printJSON(MeetingStatus(meeting)) } else { print(meeting.id) }
            return
        }
        if command == "delete-audio" {
            guard ProcessInfo.processInfo.environment["AFTERWORD_MEETINGS_ROOT"] == nil else {
                throw CommandError(message: "Audio deletion requires the installed Afterword library; unset AFTERWORD_MEETINGS_ROOT.")
            }
            let id = operands[operands.startIndex]
            let before = try store.load(id: id)
            if before.audioRemovedAt != nil {
                if json { try printJSON(CommandReply(ok: true, status: "audio-removed", runID: nil, error: nil)) }
                else { print("audio-removed  \(id)") }
                return
            }
            guard before.activeRevisionID != nil || eraseUntranscribed else {
                throw CommandError(message: "This meeting has no transcript. Add --erase-untranscribed to permanently remove its only processable audio.")
            }
            let reply: CommandReply
            do { reply = try requestProcessing(id: id, command: command) }
            catch {
                guard (try? store.load(id: id).audioRemovedAt) != nil else { throw error }
                reply = CommandReply(ok: true, status: "audio-removed", runID: nil, error: nil)
            }
            guard reply.ok else { throw CommandError(message: reply.error ?? "Afterword rejected audio removal.") }
            let after = try store.load(id: id)
            guard after.audioRemovedAt != nil else { throw CommandError(message: "Audio removal was not confirmed.") }
            if json { try printJSON(reply) } else { print("audio-removed  \(id)") }
            return
        }
        if command == "storage" {
            let usages = try StorageReport.collect(store: store)
                .sorted { $0.deleteAudioReclaimableBytes > $1.deleteAudioReclaimableBytes }
            if json { try printJSON(usages) }
            else {
                for usage in usages {
                    print("\(usage.deleteAudioReclaimableBytes) reclaimable bytes  \(usage.processingStatus)  \(usage.title)  \(usage.id)")
                }
            }
            return
        }
        let saved = try store.list()
        if command == "list" {
            if json { try printJSON(saved.map(MeetingStatus.init)); return }
            for meeting in saved {
                print("\(meeting.startedAt)  \(meeting.processingStatus)  \(meeting.title)  \(meeting.id)")
            }
            return
        }
        if command == "label" {
            let id = operands[operands.startIndex]
            let segment = operands[operands.index(after: operands.startIndex)]
            let speaker = operands[operands.index(operands.startIndex, offsetBy: 2)]
            let before = try? store.load(id: id)
            let reply: CommandReply
            do { reply = try requestProcessing(id: id, command: command, fields: ["segment_id": segment, "speaker_id": speaker]) }
            catch {
                guard let current = try? store.load(id: id), current.activeRevisionID != before?.activeRevisionID,
                      current.processingStatus == "transcript_ready" else { throw error }
                reply = CommandReply(ok: true, status: current.processingStatus, runID: nil, error: nil)
            }
            guard reply.ok else { throw CommandError(message: reply.error ?? "The app rejected the speaker label.") }
            if json { try printJSON(reply) } else { print(reply.status ?? "transcript_ready") }
            return
        }
        let selector = operands.first ?? "latest"
        guard let id = selector == "latest" ? saved.first?.id : selector else {
            throw CommandError(message: "No saved recordings were found.")
        }
        if command == "process" || command == "notes" {
            let before = try? store.load(id: id)
            let reply: CommandReply
            do { reply = try requestProcessing(id: id, command: command) }
            catch {
                guard let current = try? store.load(id: id),
                      current.processingRunID != before?.processingRunID,
                      ["queued", "processing", "completed"].contains(current.processingStatus) else { throw error }
                reply = CommandReply(ok: true, status: current.processingStatus,
                                     runID: current.processingRunID, error: nil)
            }
            guard reply.ok else { throw CommandError(message: reply.error ?? "The app rejected processing.") }
            if json { try printJSON(reply) }
            else { print("\(reply.status ?? "queued")  \(reply.runID ?? "")") }
            return
        }
        if command == "status" {
            let status = MeetingStatus(try store.load(id: id))
            if json { try printJSON(status) } else { printStatus(status) }
            return
        }
        var previous = ""
        while true {
            let status = MeetingStatus(try store.load(id: id))
            let state = "\(status.processingStatus)/\(status.processingStage ?? "")/\(status.processingError ?? "")"
            if state != previous {
                if json { try printJSON(status) } else { printStatus(status) }
                fflush(stdout)
                previous = state
            }
            if ["completed", "failed", "cancelled", "empty"].contains(status.processingStatus) { return }
            Thread.sleep(forTimeInterval: 3)
        }
    }

    private static func printStatus(_ status: MeetingStatus) {
        print("\(status.title) (\(status.id))")
        print("\(status.startedAt)  \(status.durationSeconds)s  capture: \(status.captureState)")
        print("processing: \(status.processingStatus)\(status.processingStage.map { " / \($0)" } ?? "")")
        if let error = status.processingError { print("error: \(error)") }
        print("transcript: \(status.hasTranscript ? "ready" : "none")  notes: \(status.hasNotes ? "ready" : "none")")
    }

    private static func notifyAppOfNewMeeting(id: String) {
        guard ProcessInfo.processInfo.environment["AFTERWORD_MEETINGS_ROOT"] == nil else { return }
        do {
            let reply = try requestProcessing(id: id, command: "reload")
            if !reply.ok { fputs("afterwordctl: Meeting saved; app refresh failed: \(reply.error ?? "unknown error")\n", stderr) }
        } catch { fputs("afterwordctl: Meeting saved; app refresh failed: \(error.localizedDescription)\n", stderr) }
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    private static func requestProcessing(id: String, command: String, fields: [String: String] = [:]) throws -> CommandReply {
        var descriptor = connectToApp()
        if descriptor < 0 {
            let app = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Afterword.app")
            guard FileManager.default.fileExists(atPath: app.path) else {
                throw CommandError(message: "The installed Afterword app was not found at \(app.path).")
            }
            let launcher = Process()
            launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            launcher.arguments = [app.path]
            try launcher.run()
            launcher.waitUntilExit()
            guard launcher.terminationStatus == 0 else { throw CommandError(message: "Could not open Afterword.") }
            for _ in 0..<40 {
                Thread.sleep(forTimeInterval: 0.25)
                descriptor = connectToApp()
                if descriptor >= 0 { break }
            }
        }
        guard descriptor >= 0 else { throw CommandError(message: "Afterword did not open its local command socket.") }
        for attempt in 0..<40 {
            let reply = try sendProcessing(id: id, command: command, fields: fields, descriptor: descriptor)
            if reply.error != "Afterword is still loading." { return reply }
            if attempt == 39 { break }
            Thread.sleep(forTimeInterval: 0.25)
            descriptor = connectToApp()
            guard descriptor >= 0 else { break }
        }
        throw CommandError(message: "Afterword did not finish loading.")
    }

    private static func sendProcessing(id: String, command: String, fields: [String: String], descriptor: Int32) throws -> CommandReply {
        defer { close(descriptor) }
        var timeout = timeval(tv_sec: command == "delete-audio" ? 900 : 20, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        let request = try JSONSerialization.data(withJSONObject: fields.merging(["command": command, "meeting_id": id]) { _, required in required }) + Data([10])
        let wrote = request.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            var sent = 0
            while sent < bytes.count {
                let count = write(descriptor, base.advanced(by: sent), bytes.count - sent)
                if count > 0 { sent += count }
                else if count == 0 || errno != EINTR { return false }
            }
            return true
        }
        guard wrote else { throw CommandError(message: "Could not send the processing request to Afterword.") }
        var reply = Data()
        var byte: UInt8 = 0
        while reply.count < 4_096 {
            let count = read(descriptor, &byte, 1)
            if count <= 0 { break }
            if byte == 10 { return try JSONDecoder().decode(CommandReply.self, from: reply) }
            reply.append(byte)
        }
        throw CommandError(message: "Afterword did not confirm the processing request.")
    }

    private static func connectToApp() -> Int32 {
        let path = socketPath
        let bytes = Array(path.utf8CString).map { UInt8(bitPattern: $0) }
        var address = sockaddr_un()
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return -1 }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return -1 }
        var noSignal: Int32 = 1
        _ = withUnsafePointer(to: &noSignal) {
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected == 0 { return descriptor }
        close(descriptor)
        return -1
    }
}
