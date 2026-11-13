import AVFoundation
import AfterwordCore
import Foundation

enum AudioImport {
    struct ImportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func importFile(at inputURL: URL, into store: MeetingStore,
                           title requestedTitle: String? = nil, startedAt requestedStart: Date? = nil) throws -> Meeting {
        let input = inputURL.standardizedFileURL
        let supported = Set(["webm", "wav", "mp3"])
        guard supported.contains(input.pathExtension.lowercased()) else {
            throw ImportError(message: "Supported audio formats are WebM, WAV, and MP3.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: input.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ImportError(message: "The input must be an existing audio file.")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: input.path)
        guard ((attributes[.size] as? NSNumber)?.int64Value ?? 0) > 0 else {
            throw ImportError(message: "The input audio file is empty.")
        }
        let ffmpeg = try ffmpegURL()
        let fileName = input.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferredTitle = requestedTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let chosenTitle = !preferredTitle.isEmpty ? preferredTitle : (fileName.isEmpty ? "Imported Audio" : fileName)
        let startedAt = requestedStart ?? (attributes[.creationDate] as? Date)
            ?? (attributes[.modificationDate] as? Date) ?? Date()
        try FileManager.default.createDirectory(at: store.rootURL, withIntermediateDirectories: true)
        let parent = store.rootURL.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".afterword-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let stagingStore = MeetingStore(rootURL: staging)
        var meeting = try stagingStore.create(title: String(chosenTitle.prefix(200)), startedAt: startedAt)
        let chunkID = UUID().uuidString.lowercased()
        let directory = try stagingStore.beginChunk(meetingID: meeting.id, chunkID: chunkID)
        let output = directory.appendingPathComponent("audio.caf")
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-i", input.path,
                             "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "16000",
                             "-c:a", "pcm_s16le", "-f", "caf", output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ImportError(message: "Audio decoding failed (ffmpeg exit \(process.terminationStatus)).")
        }
        let audio = try AVAudioFile(forReading: output)
        guard audio.length > 0, audio.fileFormat.sampleRate == 16_000,
              audio.fileFormat.channelCount == 1 else {
            throw ImportError(message: "Decoded audio is empty or has an unexpected format.")
        }
        // Mixed external audio follows the system track so speaker diarization runs.
        let descriptor = ChunkDescriptor(id: chunkID, source: .system, generation: 0,
            startUS: 0, frameCount: audio.length, sampleRate: 16_000, channelCount: 1,
            relativePath: "audio/\(chunkID)/audio.caf")
        meeting.intervals = [CaptureInterval(generation: 0, startUS: 0, endUS: descriptor.endUS)]
        meeting.captureState = .stopped
        try stagingStore.finalizeChunk(meeting: meeting, descriptor: descriptor)
        meeting.chunks = [descriptor]
        try stagingStore.save(meeting)
        let source = try stagingStore.meetingURL(id: meeting.id)
        // Recreate the store after making a previously absent root so path resolution sees its directory.
        let destination = try MeetingStore(rootURL: store.rootURL).meetingURL(id: meeting.id)
        try FileManager.default.moveItem(at: source, to: destination)
        return meeting
    }

    private static func ffmpegURL() throws -> URL {
        let search = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/usr/local/bin", "/opt/homebrew/bin"]
        if let path = search.map({ URL(fileURLWithPath: $0).appendingPathComponent("ffmpeg").path })
            .first(where: FileManager.default.isExecutableFile(atPath:)) {
            return URL(fileURLWithPath: path)
        }
        throw ImportError(message: "ffmpeg is required to import WebM, WAV, or MP3 audio.")
    }
}
