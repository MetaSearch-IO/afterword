import AfterwordCore
import Darwin
import Foundation
import XCTest
@testable import AfterwordApp

final class MeetingDeletionTests: XCTestCase {
    private func fixture() throws -> (URL, MeetingStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("afterword-delete-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, MeetingStore(rootURL: directory.appendingPathComponent("meetings")))
    }

    private func meeting(_ store: MeetingStore, title: String = "Delete this meeting") throws -> Meeting {
        var meeting = try store.create(title: title)
        meeting.captureState = .stopped
        try store.save(meeting)
        return meeting
    }

    func testDeletesWholeMeetingDirectoryButPreservesOtherMeetingsAndExports() throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = try meeting(store)
        let other = try meeting(store, title: "Keep this meeting")
        let otherManifest = try store.artifactURL(meetingID: other.id, relativePath: "meeting.json")
        let original = try Data(contentsOf: otherManifest)
        for path in ["audio/chunk/audio.caf", "revisions/old/transcript.json", "revisions/old/summaries/notes.json",
                     "revisions/current/corrections.json", "work/run/cache/prepared.wav", "calendar-event.json"] {
            let url = try store.artifactURL(meetingID: target.id, relativePath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("synthetic file".utf8).write(to: url)
        }
        let export = directory.appendingPathComponent("exported-notes.txt")
        try Data("keep exported copy".utf8).write(to: export)
        try MeetingDeletion.remove(id: target.id, rootURL: store.rootURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.meetingURL(id: target.id).path))
        XCTAssertEqual(try store.list().map(\.id), [other.id])
        XCTAssertEqual(try Data(contentsOf: otherManifest), original)
        XCTAssertEqual(try String(contentsOf: export, encoding: .utf8), "keep exported copy")
    }

    func testRejectsActiveCaptureAndQueuedOrRunningProcessing() throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var target = try meeting(store)
        target.captureState = .recording
        try store.save(target)
        XCTAssertThrowsError(try MeetingDeletion.remove(id: target.id, rootURL: store.rootURL))
        target.captureState = .stopped
        for status in ["running", "processing", "cancelling", "queued", "paused"] {
            target.processingStatus = status
            try store.save(target)
            XCTAssertThrowsError(try MeetingDeletion.remove(id: target.id, rootURL: store.rootURL), status)
            XCTAssertEqual(try store.load(id: target.id).processingStatus, status)
        }
    }

    func testHeldProcessingOrCalendarLockPreventsDeletion() throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = try meeting(store)
        for name in [".processing.lock", ".calendar-event.lock"] {
            let lock = try store.artifactURL(meetingID: target.id, relativePath: name)
            let descriptor = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            guard descriptor >= 0 else { return }
            XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
            XCTAssertThrowsError(try MeetingDeletion.remove(id: target.id, rootURL: store.rootURL))
            XCTAssertEqual(try store.load(id: target.id).title, target.title)
            close(descriptor)
        }
        try MeetingDeletion.remove(id: target.id, rootURL: store.rootURL)
        XCTAssertTrue(try store.list().isEmpty)
    }

    func testRejectsTraversalAndLinkedMeetingOrLockButDoesNotFollowNestedSymlinks() throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = try meeting(store)
        let outside = directory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: outside)
        for id in ["..", "../keep.txt", "/", ""] {
            XCTAssertThrowsError(try MeetingDeletion.remove(id: id, rootURL: store.rootURL))
        }
        let lock = try store.artifactURL(meetingID: target.id, relativePath: ".processing.lock")
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: outside)
        XCTAssertThrowsError(try MeetingDeletion.remove(id: target.id, rootURL: store.rootURL))
        try FileManager.default.removeItem(at: lock)
        let folder = try store.meetingURL(id: target.id)
        let moved = directory.appendingPathComponent("protected-meeting")
        try FileManager.default.moveItem(at: folder, to: moved)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: moved)
        XCTAssertThrowsError(try MeetingDeletion.remove(id: target.id, rootURL: store.rootURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("meeting.json").path))
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: moved, to: folder)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("external-copy"), withDestinationURL: outside)
        try MeetingDeletion.remove(id: target.id, rootURL: store.rootURL)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "keep")
    }

    func testPartialFilesystemFailureKeepsManifestForRetry() throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = try meeting(store)
        let locked = try store.artifactURL(meetingID: target.id, relativePath: "work/locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: locked.appendingPathComponent("file"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        XCTAssertThrowsError(try MeetingDeletion.remove(id: target.id, rootURL: store.rootURL))
        XCTAssertEqual(try store.load(id: target.id).title, target.title)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        try MeetingDeletion.remove(id: target.id, rootURL: store.rootURL)
        XCTAssertTrue(try store.list().isEmpty)
    }

    @MainActor
    func testControllerDeletesRequestedIdentityAndMaintainsSelection() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try meeting(store, title: "First")
        let second = try meeting(store, title: "Second")
        let third = try meeting(store, title: "Third")
        let controller = MeetingController(rootURL: store.rootURL, requestMicrophoneAccess: { false })
        let deadline = Date().addingTimeInterval(3)
        while controller.isLoading && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(controller.isLoading)
        controller.selectedID = second.id
        try await controller.deleteMeeting(id: first.id)
        XCTAssertEqual(controller.selectedID, second.id)
        XCTAssertEqual(Set(controller.meetings.map(\.id)), [second.id, third.id])
        try await controller.deleteMeeting(id: second.id)
        XCTAssertEqual(controller.selectedID, third.id)
        try await controller.deleteMeeting(id: third.id)
        XCTAssertNil(controller.selectedID)
        XCTAssertTrue(controller.meetings.isEmpty)
        XCTAssertNil(controller.deletingMeetingID)
        XCTAssertTrue(controller.canRecord)
    }
}
