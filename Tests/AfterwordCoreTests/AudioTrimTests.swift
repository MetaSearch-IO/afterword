import AVFoundation
import Foundation
import Testing
@testable import AfterwordCore

struct AudioTrimTests {
    @Test func trimPreservesSourcesAndCutsBoundaryFrames() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("afterword-trim-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(rootURL: directory.appendingPathComponent("meetings"))
        var source = try store.create(title: "Original")
        source.captureState = .stopped
        source.intervals = [CaptureInterval(generation: 0, startUS: 0, endUS: 2_000_000)]
        try store.save(source)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        for (id, track, start) in [("system-0", AudioSource.system, Int64(0)),
                                    ("system-1", .system, 1_000_000),
                                    ("microphone-0", .microphone, 500_000)] {
            let chunk = try store.beginChunk(meetingID: source.id, chunkID: id)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
            buffer.frameLength = 48_000
            buffer.floatChannelData![0].initialize(repeating: 0.25, count: 48_000)
            do {
                let file = try AVAudioFile(forWriting: chunk.appendingPathComponent("audio.caf"), settings: format.settings)
                try file.write(from: buffer)
            }
            source = try store.commitChunk(meetingID: source.id, descriptor: ChunkDescriptor(
                id: id, source: track, generation: 0, startUS: start,
                frameCount: 48_000, sampleRate: 48_000, channelCount: 1,
                relativePath: "audio/\(id)/audio.caf"))
        }
        let trimmed = try AudioTrim.create(from: source.id, in: store, startUS: 250_000, endUS: 1_750_000)
        #expect(trimmed.captureState == .stopped)
        #expect(trimmed.intervals[0].endUS == 1_500_000)
        #expect(trimmed.chunks.count == 3)
        #expect(trimmed.chunks.filter { $0.source == .system }.map(\.frameCount) == [36_000, 36_000])
        #expect(trimmed.chunks.first { $0.source == .microphone }?.startUS == 250_000)
        #expect(try store.load(id: trimmed.id) == trimmed)
        #expect(try store.load(id: source.id).chunks.count == 3)
    }
}
