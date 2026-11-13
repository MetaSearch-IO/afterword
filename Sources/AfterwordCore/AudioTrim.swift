import AVFoundation
import Foundation

package enum AudioTrim {
    package static func create(from sourceID: String, in store: MeetingStore, startUS: Int64,
                               endUS: Int64, title: String? = nil) throws -> Meeting {
        guard startUS >= 0, endUS > startUS else { throw StoreError.invalid("Invalid trim range.") }
        let source = try store.load(id: sourceID)
        guard !source.captureState.isActive, source.intervals.last?.endUS.map({ endUS <= $0 }) == true else {
            throw StoreError.invalid("Finish recording before trimming, and choose a range within its duration.")
        }
        guard let sourceDate = ISO8601DateFormatter().date(from: source.startedAt) else {
            throw StoreError.invalid("The source recording has an invalid start time.")
        }
        let files = FileManager.default
        let staging = store.rootURL.deletingLastPathComponent()
            .appendingPathComponent(".afterword-trim-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }
        let stagedStore = MeetingStore(rootURL: staging)
        var trimmed = try stagedStore.create(title: title ?? "\(source.title) (trimmed)",
            startedAt: sourceDate.addingTimeInterval(Double(startUS) / 1_000_000))
        trimmed.asrLanguage = source.asrLanguage
        trimmed.captureState = .stopped
        trimmed.intervals = [CaptureInterval(generation: 0, startUS: 0, endUS: endUS - startUS + 100)]
        for chunk in source.chunks where chunk.endUS > startUS && chunk.startUS < endUS {
            let rate = chunk.sampleRate
            let first = max(Int64(0), Int64(ceil(Double(max(startUS, chunk.startUS) - chunk.startUS) * rate / 1_000_000)))
            let last = min(chunk.frameCount, Int64(ceil(Double(min(endUS, chunk.endUS) - chunk.startUS) * rate / 1_000_000)))
            guard last > first else { continue }
            let directory = try stagedStore.beginChunk(meetingID: trimmed.id, chunkID: chunk.id)
            let input = try store.artifactURL(meetingID: source.id, relativePath: chunk.relativePath)
            let output = directory.appendingPathComponent("audio.caf")
            if first == 0 && last == chunk.frameCount {
                do { try files.linkItem(at: input, to: output) }
                catch { try files.copyItem(at: input, to: output) }
            } else {
                try copyFrames(from: input, to: output, start: first, count: last - first)
            }
            let sampleStartUS = chunk.startUS + Int64((Double(first) * 1_000_000 / rate).rounded())
            let descriptor = ChunkDescriptor(id: chunk.id, source: chunk.source, generation: 0,
                startUS: sampleStartUS - startUS, frameCount: last - first, sampleRate: rate,
                channelCount: chunk.channelCount, format: chunk.format,
                relativePath: "audio/\(chunk.id)/audio.caf")
            try stagedStore.finalizeChunk(meeting: trimmed, descriptor: descriptor)
            trimmed.chunks.append(descriptor)
        }
        guard !trimmed.chunks.isEmpty else { throw StoreError.invalid("No audio falls within the trim range.") }
        trimmed.chunks.sort { ($0.startUS, $0.id) < ($1.startUS, $1.id) }
        trimmed.intervals[0].endUS = max(endUS - startUS, trimmed.chunks.map(\.endUS).max() ?? 0)
        try stagedStore.save(trimmed)
        let manifest = try stagedStore.artifactURL(meetingID: trimmed.id, relativePath: "meeting.json")
        let bytes = try manifest.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard bytes <= 16 * 1_024 * 1_024 else {
            throw StoreError.invalid("The trimmed recording exceeds the worker metadata limit. Choose a shorter range.")
        }
        _ = try stagedStore.load(id: trimmed.id)
        try files.moveItem(at: stagedStore.meetingURL(id: trimmed.id), to: store.meetingURL(id: trimmed.id))
        return trimmed
    }

    private static func copyFrames(from inputURL: URL, to outputURL: URL,
                                   start: Int64, count: Int64) throws {
        let input = try AVAudioFile(forReading: inputURL)
        guard count > 0, start >= 0, count <= input.length, start <= input.length - count,
              let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat,
                                            frameCapacity: 8_192) else {
            throw StoreError.invalid("The trim boundary exceeds its audio chunk.")
        }
        input.framePosition = start
        let output = try AVAudioFile(forWriting: outputURL, settings: input.fileFormat.settings,
                                    commonFormat: input.processingFormat.commonFormat,
                                    interleaved: input.processingFormat.isInterleaved)
        var remaining = count
        while remaining > 0 {
            let frames = AVAudioFrameCount(min(remaining, 8_192))
            try input.read(into: buffer, frameCount: frames)
            guard buffer.frameLength == frames else {
                throw StoreError.invalid("The trim boundary audio is incomplete.")
            }
            try output.write(from: buffer)
            remaining -= Int64(frames)
        }
    }
}
