import AVFoundation
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

    func testRemovesAudioFromUntranscribedStoppedMeeting() throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = try meeting(store)
        let audio = try store.artifactURL(meetingID: target.id, relativePath: "audio/chunk/audio.caf")
        try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("recorded voice".utf8).write(to: audio)

        try MeetingDeletion.removeAudio(id: target.id, rootURL: store.rootURL)

        let saved = try store.load(id: target.id)
        XCTAssertEqual(saved.title, target.title)
        XCTAssertEqual(saved.processingStatus, "idle")
        XCTAssertTrue(saved.audioUnavailable)
        XCTAssertNil(saved.audioRemovalStartedAt)
        XCTAssertNotNil(saved.audioRemovedAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.meetingURL(id: target.id).appendingPathComponent("audio").path))
        try MeetingDeletion.removeAudio(id: target.id, rootURL: store.rootURL)
        XCTAssertEqual(try store.load(id: target.id).audioRemovedAt, saved.audioRemovedAt)
    }

    func testRemovesPreparedWAVsButPreservesCompletedMeetingArtifacts() throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var target = try meeting(store)
        target.processingStatus = "completed"
        try store.save(target)
        let removed = ["audio/chunk/audio.caf", "work/run/system.wav", "work/run/nested/microphone.WAV"]
        let kept = ["work/run/prepared.json", "work/run/nested/results.json", "revisions/current/transcript.json",
                    "revisions/current/notes.json", "calendar-event.json"]
        for path in removed + kept {
            let url = try store.artifactURL(meetingID: target.id, relativePath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(path.utf8).write(to: url)
        }

        try MeetingDeletion.removeAudio(id: target.id, rootURL: store.rootURL)

        for path in removed {
            XCTAssertFalse(FileManager.default.fileExists(atPath: try store.artifactURL(meetingID: target.id, relativePath: path).path), path)
        }
        for path in kept {
            let url = try store.artifactURL(meetingID: target.id, relativePath: path)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), path)
        }
        XCTAssertEqual(try store.load(id: target.id).processingStatus, "completed")
    }

    func testRetriesPendingRemovalAfterPartialDeletion() throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var target = try meeting(store)
        target.audioRemovalStartedAt = "2026-10-16T00:00:00Z"
        target.activeRevisionID = "missing-revision"
        try store.save(target)
        let audio = try store.artifactURL(meetingID: target.id, relativePath: "audio")
        try FileManager.default.removeItem(at: audio)
        let prepared = try store.artifactURL(meetingID: target.id, relativePath: "work/run/system.wav")
        try FileManager.default.createDirectory(at: prepared.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("prepared".utf8).write(to: prepared)

        try MeetingDeletion.removeAudio(id: target.id, rootURL: store.rootURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.path))
        let saved = try store.load(id: target.id)
        XCTAssertNil(saved.audioRemovalStartedAt)
        XCTAssertNotNil(saved.audioRemovedAt)
    }

    func testRejectsCorruptAcceptedArtifactsBeforeRemovingAudio() throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var target = try meeting(store)
        target.activeRevisionID = "revision"
        target.activeSummaryID = "summary"
        target.intervals = [CaptureInterval(generation: 0, startUS: 0, endUS: 1_000_000)]
        target.chunks = [ChunkDescriptor(id: "chunk", source: .system, generation: 0, startUS: 0,
                                         frameCount: 16_000, sampleRate: 16_000, channelCount: 1,
                                         relativePath: "audio/chunk/audio.caf")]
        try store.save(target)
        let audio = try store.artifactURL(meetingID: target.id, relativePath: "audio/chunk/audio.caf")
        try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("recorded voice".utf8).write(to: audio)
        func write(_ value: [String: Any], path: String) throws -> URL {
            let url = try store.artifactURL(meetingID: target.id, relativePath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: value).write(to: url)
            return url
        }
        let transcript = try write(["schema_version": 1, "run_id": "run", "meeting_id": target.id,
            "revision_id": "revision", "speakers": [], "warnings": [],
            "coverage": [["source": "system", "start_us": 0, "end_us": 1_000_000]],
            "segments": [["id": "s1", "source": "system", "start_us": 0, "end_us": 1_000_000,
                          "text": "Meeting", "speaker_id": NSNull(), "attribution_reason": "unknown", "overlap": false]]],
            path: "revisions/revision/transcript.json")
        _ = try write(["schema_version": 1, "run_id": "run", "meeting_id": target.id, "revision_id": "revision",
                   "input_fingerprint": "fixture", "committed_audio_fingerprint": Artifacts.audioFingerprint(target.chunks),
                   "preparation_version": 1, "alignment_version": 1], path: "revisions/revision/provenance.json")
        let summary = try write(["schema_version": 1, "run_id": "run", "meeting_id": target.id,
                                 "revision_id": "revision", "summary_id": "summary", "name_map_revision": "fixture",
                                 "covered_segment_ids": ["s1"], "overview": [["text": "Note", "segment_ids": ["s1"]]],
                                 "discussion_points": [], "decisions": [], "action_items": [], "open_questions": []],
                                path: "revisions/revision/summaries/summary.json")

        let originalTranscript = try Data(contentsOf: transcript)
        try Data("{}".utf8).write(to: transcript)
        XCTAssertThrowsError(try MeetingDeletion.removeAudio(id: target.id, rootURL: store.rootURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertFalse(try store.load(id: target.id).audioUnavailable)
        try originalTranscript.write(to: transcript)
        try Data("{}".utf8).write(to: summary)
        XCTAssertThrowsError(try MeetingDeletion.removeAudio(id: target.id, rootURL: store.rootURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertFalse(try store.load(id: target.id).audioUnavailable)
    }

    func testRejectsActiveMeetingsAndHeldLocksBeforeMarkingAudioUnavailable() throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var target = try meeting(store)
        target.captureState = .recording
        try store.save(target)
        XCTAssertThrowsError(try MeetingDeletion.removeAudio(id: target.id, rootURL: store.rootURL))
        target.captureState = .stopped
        for status in ["running", "processing", "cancelling", "queued", "paused"] {
            target.processingStatus = status
            try store.save(target)
            XCTAssertThrowsError(try MeetingDeletion.removeAudio(id: target.id, rootURL: store.rootURL), status)
        }
        target.processingStatus = "idle"
        try store.save(target)
        for name in [".processing.lock", ".calendar-event.lock"] {
            let lock = try store.artifactURL(meetingID: target.id, relativePath: name)
            let descriptor = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            guard descriptor >= 0 else { return }
            XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
            XCTAssertThrowsError(try MeetingDeletion.removeAudio(id: target.id, rootURL: store.rootURL))
            close(descriptor)
        }
        XCTAssertFalse(try store.load(id: target.id).audioUnavailable)
    }

    func testAudioRemovalDoesNotFollowNestedSymlinksOrLinkedAudioRoot() throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = try meeting(store)
        let outside = directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideWAV = outside.appendingPathComponent("keep.wav")
        try Data("keep".utf8).write(to: outsideWAV)
        let audio = try store.artifactURL(meetingID: target.id, relativePath: "audio")
        try FileManager.default.removeItem(at: audio)
        try FileManager.default.createSymbolicLink(at: audio, withDestinationURL: outside)
        XCTAssertThrowsError(try MeetingDeletion.removeAudio(id: target.id, rootURL: store.rootURL))
        XCTAssertEqual(try String(contentsOf: outsideWAV, encoding: .utf8), "keep")
        XCTAssertNotNil(try store.load(id: target.id).audioRemovalStartedAt)

        try FileManager.default.removeItem(at: audio)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: audio.appendingPathComponent("external"), withDestinationURL: outside)
        let work = try store.artifactURL(meetingID: target.id, relativePath: "work/run")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: work.appendingPathComponent("external"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: work.appendingPathComponent("linked.wav"), withDestinationURL: outsideWAV)

        try MeetingDeletion.removeAudio(id: target.id, rootURL: store.rootURL)

        XCTAssertEqual(try String(contentsOf: outsideWAV, encoding: .utf8), "keep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: work.appendingPathComponent("external").path), outside.path)
        XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: work.appendingPathComponent("linked.wav").path))
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

    @MainActor
    func testControllerRemovesOnlyAudioAndKeepsMeetingSelected() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var target = try meeting(store)
        target.intervals = [CaptureInterval(generation: 0, startUS: 0, endUS: 1_000_000)]
        try store.save(target)
        let partial = try store.beginChunk(meetingID: target.id, chunkID: "chunk")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        do {
            let file = try AVAudioFile(forWriting: partial.appendingPathComponent("audio.caf"), settings: format.settings)
            try file.write(from: buffer)
        }
        target = try store.commitChunk(meetingID: target.id, descriptor: ChunkDescriptor(id: "chunk", source: .system,
            generation: 0, startUS: 0, frameCount: 16_000, sampleRate: 16_000, channelCount: 1,
            relativePath: "audio/chunk/audio.caf"))
        let controller = MeetingController(rootURL: store.rootURL, requestMicrophoneAccess: { false })
        let deadline = Date().addingTimeInterval(3)
        while controller.isLoading && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(controller.isLoading)
        controller.selectedID = target.id
        XCTAssertTrue(controller.canDeleteMeetingAudio(target))
        try await controller.deleteMeetingAudio(id: target.id)
        XCTAssertEqual(controller.selectedID, target.id)
        XCTAssertEqual(controller.meetings.map(\.id), [target.id])
        XCTAssertEqual(controller.meetings.first?.chunks, target.chunks)
        XCTAssertNotNil(controller.meetings.first?.audioRemovedAt)
        XCTAssertFalse(controller.canProcess(try store.load(id: target.id)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.artifactURL(meetingID: target.id,
            relativePath: "audio/chunk/audio.caf").path))
    }

    @MainActor
    func testStartupFinishesPendingAudioRemoval() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var target = try meeting(store)
        target.audioRemovalStartedAt = "2026-10-16T00:00:00Z"
        try store.save(target)
        let audio = try store.artifactURL(meetingID: target.id, relativePath: "audio/chunk/audio.caf")
        try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("unfinished audio".utf8).write(to: audio)
        let prepared = try store.artifactURL(meetingID: target.id, relativePath: "work/run/system.wav")
        try FileManager.default.createDirectory(at: prepared.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("prepared audio".utf8).write(to: prepared)
        let controller = MeetingController(rootURL: store.rootURL, requestMicrophoneAccess: { false })
        let deadline = Date().addingTimeInterval(3)
        while controller.isLoading && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(controller.isLoading)
        XCTAssertNil(controller.meetings.first?.audioRemovalStartedAt)
        XCTAssertNotNil(controller.meetings.first?.audioRemovedAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.path))
    }
}
