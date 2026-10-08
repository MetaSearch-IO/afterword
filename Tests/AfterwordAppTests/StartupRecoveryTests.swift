import AfterwordCore
import Darwin
import XCTest
@testable import AfterwordApp

final class StartupRecoveryTests: XCTestCase {
    @MainActor
    func testHeldWorkerLockBlocksRecordingWithoutChangingMetadataUntilRechecked() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("afterword-startup-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(rootURL: directory)
        var meeting = try store.create(title: "Still processing")
        meeting.captureState = .stopped
        meeting.processingStatus = "processing"
        try store.save(meeting)
        let manifest = try store.artifactURL(meetingID: meeting.id, relativePath: "meeting.json")
        let original = try Data(contentsOf: manifest)
        let lockURL = try store.artifactURL(meetingID: meeting.id, relativePath: ".processing.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        let controller = MeetingController(rootURL: directory)
        let firstDeadline = Date().addingTimeInterval(5)
        while !controller.recoveryBlocked && Date() < firstDeadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(controller.recoveryBlocked)
        XCTAssertFalse(controller.canRecord)
        XCTAssertEqual(try Data(contentsOf: manifest), original)
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        controller.recheckRecovery()
        let secondDeadline = Date().addingTimeInterval(5)
        while controller.isLoading && Date() < secondDeadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(controller.recoveryBlocked)
        XCTAssertTrue(controller.canRecord)
        XCTAssertEqual(try store.load(id: meeting.id).processingStatus, "interrupted")
    }
}
