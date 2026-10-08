import AVFoundation
import AfterwordCore
import XCTest
@testable import AfterwordApp

final class PreparationTests: XCTestCase, @unchecked Sendable {
    private func record(_ store: MeetingStore, meetingID: String, source: AudioSource,
                        start: Int64, rate: Double, channels: Int, generation: Int, frames: Int) throws {
        let id = UUID().uuidString
        let directory = try store.beginChunk(meetingID: meetingID, chunkID: id)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels))!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<channels {
            buffer.floatChannelData![channel].initialize(repeating: channel == 0 ? 0.25 : 0.75, count: frames)
        }
        do {
            var settings = format.settings
            settings[AVLinearPCMIsNonInterleaved] = false
            let file = try AVAudioFile(forWriting: directory.appendingPathComponent("audio.caf"), settings: settings)
            try file.write(from: buffer)
        }
        _ = try store.commitChunk(meetingID: meetingID, descriptor: ChunkDescriptor(
            id: id, source: source, generation: generation, startUS: start, frameCount: Int64(frames),
            sampleRate: rate, channelCount: channels, relativePath: "audio/\(id)/audio.caf"))
    }

    func testResamplingCoalescesStorageChunksAndPreservesPauseMapping() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("afterword-preparation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(rootURL: directory)
        var meeting = try store.create(title: "Preparation")
        meeting.captureState = .stopped
        meeting.intervals = [CaptureInterval(generation: 0, startUS: 0, endUS: 1_000_000),
                             CaptureInterval(generation: 1, startUS: 2_000_000, endUS: 3_000_000)]
        try store.save(meeting)
        try record(store, meetingID: meeting.id, source: .microphone, start: 0, rate: 44_100, channels: 2, generation: 0, frames: 22_050)
        try record(store, meetingID: meeting.id, source: .microphone, start: 500_000, rate: 44_100, channels: 2, generation: 0, frames: 22_050)
        try record(store, meetingID: meeting.id, source: .microphone, start: 2_000_000, rate: 44_100, channels: 2, generation: 1, frames: 44_100)
        try record(store, meetingID: meeting.id, source: .system, start: 0, rate: 48_000, channels: 1, generation: 0, frames: 48_000)
        meeting = try store.load(id: meeting.id)
        let path = try AudioPreparation.prepare(meeting: meeting, rootURL: directory, runID: "prepare-test")
        let prepared = try Artifacts.read(PreparedAudio.self, store: store, meetingID: meeting.id, path: path)
        XCTAssertEqual(prepared.sources.count, 2)
        let microphone = try XCTUnwrap(prepared.sources.first { $0.source == .microphone })
        XCTAssertEqual(microphone.pieces.map(\.sample_start), [0, 16_000])
        XCTAssertEqual(microphone.pieces.map(\.sample_end), [16_000, 32_000])
        XCTAssertEqual(microphone.pieces.map(\.meeting_start_us), [0, 2_000_000])
        let audio = try AVAudioFile(forReading: store.artifactURL(meetingID: meeting.id, relativePath: microphone.relative_path))
        XCTAssertEqual(audio.length, 32_000)
        XCTAssertEqual(audio.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(audio.fileFormat.channelCount, 1)
        XCTAssertEqual(audio.fileFormat.streamDescription.pointee.mBitsPerChannel, 16)
        let samples = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 128)!
        try audio.read(into: samples)
        XCTAssertGreaterThan(samples.floatChannelData![0][64], 0.2)
        XCTAssertLessThan(samples.floatChannelData![0][64], 0.8)
    }

    func testPreparationHonorsTaskCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("afterword-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(rootURL: directory)
        let meeting = try store.create(title: "Cancelled")
        let task = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            return try AudioPreparation.prepare(meeting: meeting, rootURL: directory, runID: "cancel-test")
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }
}
