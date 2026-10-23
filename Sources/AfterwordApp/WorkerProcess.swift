import Darwin
import Foundation

struct WorkerEvent: Decodable, Sendable {
    let protocol_version: Int
    let run_id: String
    let type: String
    let stage: String?
    let code: String?
    let message: String?
    let revision_id: String?
    let summary_id: String?
    let transcript_path: String?
    let provenance_path: String?
    let summary_path: String?
    let input_fingerprint: String?
    let process_group_id: Int32?
    let process_group_finished: Bool?
    let completed: Int?
    let total: Int?
    let progress_unit: String?
    let progress_phase: String?
}

struct WorkerResult: Sendable {
    let exitStatus: Int32
    let terminal: WorkerEvent?
    let error: String?
    let cleanupConfirmed: Bool
}

final class WorkerProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var control: FileHandle?
    private var groups: Set<Int32> = []
    private var failure: String?
    private var terminal: WorkerEvent?
    private var stderr = Data()
    private var cancelling = false
    private var running = false
    private var pipesClosed = false
    private var currentStage: String?
    private var progressCounts: [String: (completed: Int, total: Int)] = [:]
    private let runID: String

    init(runID: String) { self.runID = runID }

    func run(executable: URL, arguments: [String], directory: URL, environment overrides: [String: String] = [:],
             event: @escaping @Sendable (WorkerEvent) async -> Void) async throws -> WorkerResult {
        let process = Process()
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let input = Pipe(), output = Pipe(), errors = Pipe()
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw CaptureFailure(message: "Unable to configure the worker control pipe.")
        }
        process.executableURL = executable
        process.qualityOfService = .background
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        environment["PYANNOTE_METRICS_ENABLED"] = "0"
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        environment["PYTHONPATH"] = directory.path
        environment.removeValue(forKey: "AFTERWORD_REMOTE")
        environment.merge(overrides) { _, override in override }
        process.environment = environment
        try process.run()
        lock.withLock { self.process = process; control = input.fileHandleForWriting; running = true }
        if lock.withLock({ cancelling }) { sendCancellation() }
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { try? output.fileHandleForReading.close(); readers.leave() }
            var pending = Data()
            do {
                while let bytes = try Self.readBlock(output.fileHandleForReading) {
                    pending.append(bytes)
                    while let end = pending.firstIndex(of: 10) {
                        let line = Data(pending[..<end])
                        pending.removeSubrange(...end)
                        guard line.count < 65_536 else { self.protocolFailure("Worker event exceeds 64 KiB."); continue }
                        self.receive(line, event: event)
                    }
                    if pending.count >= 65_536 { pending.removeAll(keepingCapacity: false); self.protocolFailure("Worker event exceeds 64 KiB.") }
                }
                if !pending.isEmpty { self.protocolFailure("Worker output ended in an incomplete event.") }
            } catch { self.protocolFailure("Unable to read worker events.") }
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { try? errors.fileHandleForReading.close(); readers.leave() }
            do {
                while let bytes = try Self.readBlock(errors.fileHandleForReading) {
                    self.lock.withLock {
                        self.stderr.append(bytes)
                        if self.stderr.count > 262_144 { self.stderr.removeFirst(self.stderr.count - 262_144) }
                    }
                }
            } catch { self.protocolFailure("Unable to drain worker diagnostics.") }
        }
        readers.notify(queue: .global(qos: .utility)) { self.lock.withLock { self.pipesClosed = true } }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                exited.wait()
                self.lock.withLock { self.running = false; try? self.control?.close(); self.control = nil }
                let deadline = Date().addingTimeInterval(3)
                let drained = readers.wait(timeout: .now() + 3) == .success
                var cleanup = self.groupsExited()
                while !cleanup && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                    cleanup = self.groupsExited()
                }
                let result = self.lock.withLock {
                    WorkerResult(exitStatus: process.terminationStatus, terminal: self.terminal,
                                 error: self.failure ?? (drained ? nil : "Worker output pipes did not close."),
                                 cleanupConfirmed: cleanup && drained)
                }
                continuation.resume(returning: result)
            }
        }
    }

    func cancel() {
        let first = lock.withLock { let first = !cancelling; cancelling = true; return first }
        if first { sendCancellation() }
    }

    private static func readBlock(_ handle: FileHandle) throws -> Data? {
        var bytes = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            if count > 0 { return Data(bytes.prefix(count)) }
            if count == 0 { return nil }
            if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }

    private func sendCancellation() {
        lock.withLock {
            let bytes = Data("{\"protocol_version\":1,\"run_id\":\"\(runID)\",\"type\":\"cancel\"}\n".utf8)
            try? control?.write(contentsOf: bytes)
            try? control?.close()
            control = nil
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            self.lock.withLock { if self.running { self.process?.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                self.lock.withLock {
                    if self.running, let process = self.process { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
    }

    private func groupsExited() -> Bool {
        lock.withLock {
            groups = groups.filter { !(kill(-$0, 0) != 0 && errno == ESRCH) }
            return groups.isEmpty
        }
    }

    func cleanupConfirmed() -> Bool { groupsExited() && lock.withLock { !running && pipesClosed } }

    private func protocolFailure(_ message: String) {
        lock.withLock { if failure == nil { failure = message } }
        cancel()
    }

    private func receive(_ data: Data, event callback: @escaping @Sendable (WorkerEvent) async -> Void) {
        do {
            let event = try JSONDecoder().decode(WorkerEvent.self, from: data)
            try Artifacts.require(event.protocol_version == 1 && event.run_id == runID, "Worker event version or run identity does not match.")
            try Artifacts.require(["started", "stage_started", "stage_progress", "stage_completed", "completed", "cancelled", "failed"].contains(event.type), "Unknown worker event.")
            if ["stage_started", "stage_progress", "stage_completed", "cancelled", "failed"].contains(event.type) {
                try Artifacts.require(event.stage.map { !$0.isEmpty && $0.count <= 128 } == true, "Worker event is missing its stage.")
            }
            if event.type == "failed" {
                try Artifacts.require(event.code?.isEmpty == false && event.message?.isEmpty == false, "Worker failure is missing its explanation.")
            }
            if let group = event.process_group_id { try Artifacts.require(group > 1, "Invalid worker process group.") }
            if event.process_group_finished == true { try Artifacts.require(event.process_group_id != nil, "Worker cleanup event has no process group.") }
            let accepted = try lock.withLock {
                guard terminal == nil, failure == nil else { return false }
                if event.type == "stage_progress" {
                    let units: [String: Set<String>] = ["asr": ["audio_windows", "speech_clips"],
                        "diarization": ["segmentation_chunks", "embedding_batches"], "summary": ["note_groups", "reduction_groups"]]
                    guard let completed = event.completed, let total = event.total, let unit = event.progress_unit,
                          let phase = event.progress_phase else {
                        throw CaptureFailure(message: "Worker progress is missing its counters or phase.")
                    }
                    try Artifacts.require(event.process_group_id == nil && event.stage == currentStage
                                          && units[event.stage ?? ""]?.contains(unit) == true
                                          && 0 <= completed && completed <= total && total > 0 && total <= 1_000_000_000
                                          && phase.utf8.count <= 96 && Artifacts.identifier(phase),
                                          "Worker progress has invalid counters, phase, or stage.")
                    let key = unit + "/" + phase
                    if let previous = progressCounts[key] {
                        try Artifacts.require(previous.total == total && previous.completed <= completed,
                                              "Worker progress moved backwards or changed its total.")
                    } else {
                        try Artifacts.require(progressCounts.count < 4096, "Worker progress has too many phases.")
                    }
                    progressCounts[key] = (completed, total)
                } else {
                    try Artifacts.require(event.completed == nil && event.total == nil && event.progress_unit == nil && event.progress_phase == nil,
                                          "Counters are only allowed on progress events.")
                }
                if event.process_group_id == nil {
                    if event.type == "stage_started" {
                        currentStage = event.stage
                        progressCounts.removeAll(keepingCapacity: true)
                    } else if event.type == "stage_completed" {
                        currentStage = nil
                    }
                }
                if let group = event.process_group_id, group > 1 {
                    if event.process_group_finished == true && kill(-group, 0) != 0 && errno == ESRCH { groups.remove(group) }
                    else { groups.insert(group) }
                }
                if ["completed", "cancelled", "failed"].contains(event.type) { terminal = event }
                return true
            }
            try Artifacts.require(accepted, "Worker emitted an event after completion.")
            let delivered = DispatchSemaphore(value: 0)
            Task { await callback(event); delivered.signal() }
            delivered.wait()
        } catch { protocolFailure(error.localizedDescription) }
    }
}
