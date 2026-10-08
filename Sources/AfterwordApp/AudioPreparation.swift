import AVFoundation
import AfterwordCore
import Foundation

struct PreparedAudio: Codable, Sendable {
    var schema_version = 1
    let run_id: String
    let meeting_id: String
    var sample_rate = 16_000
    let sources: [PreparedSource]
}

struct PreparedSource: Codable, Sendable {
    let source: AudioSource
    let relative_path: String
    let pieces: [PreparedPiece]
}

struct PreparedPiece: Codable, Sendable {
    let sample_start: Int64
    let sample_end: Int64
    let meeting_start_us: Int64
}

enum AudioPreparation {
    // AVAudioConverter invokes its input block synchronously; each reader belongs to one conversion.
    private final class ChunkReader: @unchecked Sendable {
        let urls: [URL]
        let format: AVAudioFormat
        var input: AVAudioFile
        var index = 0
        var error: Error?

        init(urls: [URL]) throws {
            self.urls = urls
            input = try AVAudioFile(forReading: urls[0])
            format = input.processingFormat
        }

        func read(_ requested: AVAudioPacketCount, status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            do {
                try Task.checkCancellation()
                while input.framePosition >= input.length {
                    index += 1
                    guard index < urls.count else { status.pointee = .endOfStream; return nil }
                    input = try AVAudioFile(forReading: urls[index])
                    guard input.processingFormat == format else {
                        throw CaptureFailure(message: "A source changed audio format within a continuous interval.")
                    }
                }
                let capacity = min(requested, 16_384)
                let data = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
                try input.read(into: data, frameCount: capacity)
                status.pointee = .haveData
                return data
            } catch {
                self.error = error
                status.pointee = .endOfStream
                return nil
            }
        }
    }

    static func prepare(meeting: Meeting, rootURL: URL, runID: String) throws -> String {
        let store = MeetingStore(rootURL: rootURL)
        let relativeDirectory = "work/\(runID)"
        let directory = try store.artifactURL(meetingID: meeting.id, relativePath: relativeDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var sources: [PreparedSource] = []
        for source in AudioSource.allSources {
            try Task.checkCancellation()
            let chunks = meeting.chunks.filter { $0.source == source }.sorted { $0.startUS < $1.startUS }
            guard !chunks.isEmpty else { continue }
            var groups: [[ChunkDescriptor]] = []
            for chunk in chunks {
                if let previous = groups.last?.last,
                   previous.generation == chunk.generation, abs(previous.endUS - chunk.startUS) <= 2,
                   previous.sampleRate == chunk.sampleRate, previous.channelCount == chunk.channelCount {
                    groups[groups.count - 1].append(chunk)
                } else { groups.append([chunk]) }
            }
            let path = "\(relativeDirectory)/\(source.rawValue).wav"
            let outputURL = try store.artifactURL(meetingID: meeting.id, relativePath: path)
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            var settings = format.settings
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsNonInterleaved] = false
            var output: AVAudioFile? = try AVAudioFile(forWriting: outputURL, settings: settings,
                                                      commonFormat: .pcmFormatFloat32, interleaved: false)
            var position: Int64 = 0
            var pieces: [PreparedPiece] = []
            for group in groups {
                try Task.checkCancellation()
                let frames = try convert(group, meetingID: meeting.id, store: store, output: output!, format: format)
                if frames > 0 {
                    pieces.append(PreparedPiece(sample_start: position, sample_end: position + frames,
                                                meeting_start_us: group[0].startUS))
                    position += frames
                }
            }
            output = nil
            if !pieces.isEmpty { sources.append(PreparedSource(source: source, relative_path: path, pieces: pieces)) }
        }
        let relativePath = "\(relativeDirectory)/prepared.json"
        let prepared = PreparedAudio(run_id: runID, meeting_id: meeting.id, sources: sources)
        try JSONEncoder().encode(prepared).write(to: store.artifactURL(meetingID: meeting.id, relativePath: relativePath), options: .atomic)
        return relativePath
    }

    private static func convert(_ chunks: [ChunkDescriptor], meetingID: String, store: MeetingStore,
                                output: AVAudioFile, format: AVAudioFormat) throws -> Int64 {
        let reader = try ChunkReader(urls: chunks.map { try store.artifactURL(meetingID: meetingID, relativePath: $0.relativePath) })
        guard let converter = AVAudioConverter(from: reader.format, to: format) else {
            throw CaptureFailure(message: "Cannot convert the captured audio format to 16 kHz mono.")
        }
        converter.primeMethod = .none
        let limit = Int64(floor(Double(chunks.reduce(Int64(0)) { $0 + $1.frameCount }) * 16_000 / chunks[0].sampleRate))
        var written: Int64 = 0
        while written < limit {
            try Task.checkCancellation()
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192)!
            var error: NSError?
            let result = converter.convert(to: buffer, error: &error) { requested, status in
                reader.read(requested, status: status)
            }
            if let inputError = reader.error { throw inputError }
            if let error { throw error }
            buffer.frameLength = AVAudioFrameCount(min(Int64(buffer.frameLength), limit - written))
            if buffer.frameLength > 0 { try output.write(from: buffer); written += Int64(buffer.frameLength) }
            if result == .endOfStream { break }
            if result == .error || (buffer.frameLength == 0 && result != .inputRanDry) {
                throw CaptureFailure(message: "Audio conversion stopped before producing the retained input.")
            }
        }
        guard written == limit else { throw CaptureFailure(message: "Prepared audio is shorter than its source timeline.") }
        return written
    }
}
