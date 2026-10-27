import Darwin
import Foundation
import XCTest
@testable import AfterwordApp

final class LocalControlServerTests: XCTestCase {
    @MainActor
    func testControllerQueuesSavedMeetingWithoutUI() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("afterword-cli-controller-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = MeetingController(rootURL: directory.appendingPathComponent("meetings"))
        for _ in 0..<100 where controller.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(controller.isLoading)
        var meeting = try controller.store.create(title: "Saved audio")
        meeting.captureState = .stopped
        try controller.store.save(meeting)
        let reply = controller.processFromCLI(id: meeting.id)
        XCTAssertTrue(reply.ok, reply.error ?? "")
        XCTAssertNotNil(reply.runID)
        XCTAssertEqual(try controller.store.load(id: meeting.id).processingRunID, reply.runID)
    }

    func testProcessCommandReceivesAnAcknowledgement() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/aw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = directory.appendingPathComponent("control.sock")
        let server = try LocalControlServer(socketURL: socket) { command, id in
            .accepted(status: "queued", runID: "\(command):\(id)")
        }
        defer { server.stop() }
        let data = try await Task.detached { try sendLocalCommand(socket: socket) }.value
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["status"] as? String, "queued")
        XCTAssertEqual(reply["run_id"] as? String, "process:test-id")
        let notes = try await Task.detached { try sendLocalCommand(socket: socket, command: "notes") }.value
        let notesReply = try XCTUnwrap(JSONSerialization.jsonObject(with: notes) as? [String: Any])
        XCTAssertEqual(notesReply["run_id"] as? String, "notes:test-id")
    }
}

private func sendLocalCommand(socket: URL, command: String = "process") throws -> Data {
    let line = "{\"command\":\"\(command)\",\"meeting_id\":\"test-id\"}\n"
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = Array(socket.path.utf8CString).map { UInt8(bitPattern: $0) }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(descriptor) }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let sent = line.withCString { write(descriptor, $0, line.utf8.count) }
    guard sent == line.utf8.count else { throw POSIXError(.EIO) }
    var response = Data()
    var byte: UInt8 = 0
    while read(descriptor, &byte, 1) == 1, byte != 10 { response.append(byte) }
    return response
}
