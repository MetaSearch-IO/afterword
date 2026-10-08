import AVFoundation
import Foundation
import Testing
@testable import AfterwordCore

struct MeetingStoreTests {
    private func fixture(_ body: (MeetingStore, URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("afterword-core-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(MeetingStore(rootURL: url), url)
    }

    private func record(_ store: MeetingStore, meeting: Meeting, id: String = "chunk-1", count: Int64 = 480) throws -> ChunkDescriptor {
        let directory = try store.beginChunk(meetingID: meeting.id, chunkID: id)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        buffer.floatChannelData![0].initialize(repeating: 0.25, count: Int(count))
        do {
            let file = try AVAudioFile(forWriting: directory.appendingPathComponent("audio.caf"), settings: format.settings)
            try file.write(from: buffer)
        }
        return ChunkDescriptor(id: id, source: .microphone, generation: 0, startUS: 0,
                               frameCount: count, sampleRate: 48_000, channelCount: 1,
                               relativePath: "audio/\(id)/audio.caf")
    }

    @Test func committedAudioSurvivesMissingManifestUpdateAndRecoveryIsIdempotent() throws {
        try fixture { store, _ in
            var meeting = try store.create(title: "Recovery")
            meeting.captureState = .recording
            meeting.intervals = [CaptureInterval(generation: 0, startUS: 0)]
            try store.save(meeting)
            let chunk = try record(store, meeting: meeting)
            _ = try store.commitChunk(meetingID: meeting.id, descriptor: chunk)
            try store.save(meeting)
            let recovered = try #require(store.recover().first)
            #expect(recovered.chunks == [chunk])
            #expect(recovered.captureState == .interrupted)
            #expect(recovered.intervals[0].endUS == 10_000)
            #expect(try store.recover() == [recovered])
            #expect(store.recoveryIssues.isEmpty)
        }
    }

    @Test func failedAudioValidationDoesNotPublishOrDiscardPartial() throws {
        try fixture { store, _ in
            var meeting = try store.create(title: "Invalid")
            meeting.intervals = [CaptureInterval(generation: 0, startUS: 0)]
            try store.save(meeting)
            var chunk = try record(store, meeting: meeting)
            chunk.frameCount += 1
            #expect(throws: (any Error).self) { try store.commitChunk(meetingID: meeting.id, descriptor: chunk) }
            #expect(try store.load(id: meeting.id).chunks.isEmpty)
            let partial = try store.artifactURL(meetingID: meeting.id, relativePath: "audio/chunk-1.partial/audio.caf")
            #expect(FileManager.default.fileExists(atPath: partial.path))
            #expect(try store.recover().count == 1)
            #expect(store.recoveryIssues.isEmpty)
        }
    }

    @Test func unknownSchemaIsPreservedAndReported() throws {
        try fixture { store, _ in
            let meeting = try store.create(title: "Future")
            let path = try store.artifactURL(meetingID: meeting.id, relativePath: "meeting.json")
            let bytes = Data("{\"schema_version\":99}".utf8)
            try bytes.write(to: path)
            #expect(throws: (any Error).self) { try store.load(id: meeting.id) }
            #expect(try store.recover().isEmpty)
            #expect(store.recoveryIssues.count == 1)
            #expect(try Data(contentsOf: path) == bytes)
        }
    }

    @Test func rejectsTraversalSymlinksAndCrossPauseChunks() throws {
        try fixture { store, root in
            var meeting = try store.create(title: "Paths")
            meeting.intervals = [CaptureInterval(generation: 0, startUS: 0, endUS: 5_000)]
            try store.save(meeting)
            #expect(throws: (any Error).self) { try store.artifactURL(meetingID: meeting.id, relativePath: "../meeting.json") }
            let link = try store.artifactURL(meetingID: meeting.id, relativePath: "outside")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
            #expect(throws: (any Error).self) { try store.artifactURL(meetingID: meeting.id, relativePath: "outside/file") }
            let insideLink = try store.artifactURL(meetingID: meeting.id, relativePath: "inside")
            try FileManager.default.createSymbolicLink(at: insideLink, withDestinationURL: store.meetingURL(id: meeting.id))
            #expect(throws: (any Error).self) { try store.artifactURL(meetingID: meeting.id, relativePath: "inside/meeting.json") }
            let chunk = try record(store, meeting: meeting)
            #expect(throws: (any Error).self) { try store.commitChunk(meetingID: meeting.id, descriptor: chunk) }
        }
    }

    @Test func corruptCommittedDescriptorIsVisibleWithoutDeletingAudio() throws {
        try fixture { store, _ in
            var meeting = try store.create(title: "Corrupt")
            meeting.intervals = [CaptureInterval(generation: 0, startUS: 0)]
            try store.save(meeting)
            let chunk = try record(store, meeting: meeting)
            _ = try store.commitChunk(meetingID: meeting.id, descriptor: chunk)
            let descriptor = try store.artifactURL(meetingID: meeting.id, relativePath: "audio/chunk-1/chunk.json")
            try Data("broken".utf8).write(to: descriptor)
            let recovered = try #require(store.recover().first)
            #expect(recovered.captureState == .interrupted)
            #expect(store.recoveryIssues.count == 2)
            #expect(recovered.chunks.isEmpty)
            #expect(FileManager.default.fileExists(atPath: try store.artifactURL(meetingID: meeting.id, relativePath: chunk.relativePath).path))
        }
    }

    @Test func jsonUsesExplicitSnakeCaseAndIntegerTimes() throws {
        let meeting = Meeting(title: "中文 English")
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(meeting)) as? [String: Any])
        #expect(object["schema_version"] as? Int == 1)
        #expect(object["processing_status"] as? String == "idle")
        #expect(object["capture_state"] as? String == "starting")
        #expect(object["speaker_names"] != nil)
    }

    @Test func transcriptionLanguageIsOptionalAndValidated() throws {
        let legacy = Meeting(title: "Existing meeting")
        let encoded = try JSONEncoder().encode(legacy)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["asr_language"] == nil)
        #expect(try JSONDecoder().decode(Meeting.self, from: encoded).asrLanguage == nil)
        try fixture { store, _ in
            var meeting = try store.create(title: "Language")
            for language in ["auto", "zh", "en"] {
                meeting.asrLanguage = language
                try store.save(meeting)
                #expect(try store.load(id: meeting.id).asrLanguage == language)
            }
            meeting.asrLanguage = "unsupported"
            #expect(throws: (any Error).self) { try store.save(meeting) }
        }
    }

    @Test func renamedMeetingPersistsAndRejectsEmptyOrOverlongNames() throws {
        try fixture { store, root in
            var meeting = try store.create(title: "Meeting")
            meeting.captureState = .stopped
            meeting.asrLanguage = "zh"
            try store.save(meeting)
            let renamed = try store.rename(id: meeting.id, title: "  产品评审 / Product review\n")
            #expect(renamed.title == "产品评审 / Product review")
            #expect(renamed.id == meeting.id)
            #expect(renamed.asrLanguage == "zh")
            #expect(try store.list().first?.title == renamed.title)
            #expect(try MeetingStore(rootURL: root).load(id: meeting.id).title == renamed.title)
            #expect(throws: (any Error).self) { try store.rename(id: meeting.id, title: " \n\t ") }
            #expect(throws: (any Error).self) { try store.rename(id: meeting.id, title: String(repeating: "a", count: 201)) }
            #expect(try store.load(id: meeting.id).title == renamed.title)
        }
    }

    @Test func maximumIntervalBoundaryDoesNotOverflowValidation() throws {
        try fixture { store, _ in
            var meeting = try store.create(title: "Boundary")
            meeting.intervals = [CaptureInterval(generation: 0, startUS: 0, endUS: .max)]
            try store.save(meeting)
            let chunk = try record(store, meeting: meeting)
            let committed = try store.commitChunk(meetingID: meeting.id, descriptor: chunk)
            #expect(committed.chunks == [chunk])
        }
    }

    @Test func retainedDurationIsUnionOfAsymmetricSources() {
        var meeting = Meeting(title: "Union")
        meeting.chunks = [
            ChunkDescriptor(id: "mic", source: .microphone, generation: 0, startUS: 0,
                            frameCount: 48_000, sampleRate: 48_000, channelCount: 1, relativePath: "audio/mic/audio.caf"),
            ChunkDescriptor(id: "system", source: .system, generation: 0, startUS: 500_000,
                            frameCount: 48_000, sampleRate: 48_000, channelCount: 1, relativePath: "audio/system/audio.caf")
        ]
        #expect(meeting.retainedDurationUS == 1_500_000)
    }

    @Test func missingChunkDoesNotHideRemainingMeetingAudio() throws {
        try fixture { store, _ in
            var meeting = try store.create(title: "Missing")
            meeting.intervals = [CaptureInterval(generation: 0, startUS: 0)]
            try store.save(meeting)
            let retained = try record(store, meeting: meeting)
            meeting = try store.commitChunk(meetingID: meeting.id, descriptor: retained)
            var absent = retained
            absent.id = "missing"
            absent.source = .system
            absent.relativePath = "audio/missing/audio.caf"
            meeting.chunks.append(absent)
            try store.save(meeting)
            let recovered = try #require(store.recover().first)
            #expect(recovered.chunks == [retained])
            #expect(recovered.captureState == .interrupted)
            #expect(store.recoveryIssues.count == 1)
        }
    }
}
