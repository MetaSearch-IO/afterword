import AVFoundation
import Foundation
import Testing
@testable import AfterwordCore

struct AudioImportTests {
    @Test func importsWAVIntoNewLibraryAndPreservesSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("afterword-import-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("sample.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0.25, count: 4_800) }
        do {
            let file = try AVAudioFile(forWriting: input, settings: format.settings)
            try file.write(from: buffer)
        }
        let original = try Data(contentsOf: input)
        let store = MeetingStore(rootURL: directory.appendingPathComponent("meetings"))
        let meeting = try AudioImport.importFile(at: input, into: store)
        #expect(meeting.captureState == .stopped)
        #expect(meeting.title == "sample")
        #expect(meeting.chunks.count == 1)
        #expect(meeting.chunks[0].source == .system)
        #expect(meeting.chunks[0].sampleRate == 16_000)
        #expect(meeting.chunks[0].frameCount == 1_600)
        #expect(try store.list().map(\.id) == [meeting.id])
        #expect(try Data(contentsOf: input) == original)

        let invalid = directory.appendingPathComponent("broken.webm")
        try Data("not audio".utf8).write(to: invalid)
        #expect(throws: (any Error).self) { try AudioImport.importFile(at: invalid, into: store) }
        #expect(try store.list().map(\.id) == [meeting.id])
    }
}
