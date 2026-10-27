import AVFoundation
import Foundation
import Darwin

public final class MeetingStore {
    private static let identifierCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
    public let rootURL: URL
    public private(set) var recoveryIssues: [String] = []
    public private(set) var busyMeetingIDs: [String] = []
    private let files = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    public init(rootURL: URL) { self.rootURL = rootURL.standardizedFileURL }

    public func meetingURL(id: String) throws -> URL {
        try validateID(id)
        return try safeURL(id, under: rootURL)
    }

    public func create(title: String, startedAt: Date = Date()) throws -> Meeting {
        let meeting = Meeting(title: title, startedAt: startedAt)
        let url = try meetingURL(id: meeting.id)
        try files.createDirectory(at: url.appendingPathComponent("audio"), withIntermediateDirectories: true)
        try save(meeting)
        return meeting
    }

    public func save(_ meeting: Meeting) throws {
        try validate(meeting)
        let url = try meetingURL(id: meeting.id)
        try encoder.encode(meeting).write(to: safeURL("meeting.json", under: url), options: .atomic)
    }

    public func load(id: String) throws -> Meeting {
        let url = try meetingURL(id: id)
        let meeting: Meeting = try decode(at: safeURL("meeting.json", under: url))
        guard meeting.id == id else { throw StoreError.invalid("Meeting ID does not match its directory.") }
        try validate(meeting)
        return meeting
    }

    public func rename(id: String, title: String) throws -> Meeting {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 200 else {
            throw StoreError.invalid("Meeting names must contain 1–200 characters.")
        }
        var meeting = try load(id: id)
        meeting.title = title
        try save(meeting)
        return meeting
    }

    public func beginChunk(meetingID: String, chunkID: String) throws -> URL {
        try validateID(chunkID)
        let meeting = try meetingURL(id: meetingID)
        let finalURL = try safeURL("audio/\(chunkID)", under: meeting)
        let partial = try safeURL("audio/\(chunkID).partial", under: meeting)
        guard !files.fileExists(atPath: finalURL.path), !files.fileExists(atPath: partial.path) else {
            throw StoreError.invalid("Chunk already exists.")
        }
        try files.createDirectory(at: partial, withIntermediateDirectories: false)
        return partial
    }

    public func list() throws -> [Meeting] {
        guard files.fileExists(atPath: rootURL.path) else { return [] }
        return try files.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try $0.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true }
            .compactMap { try? load(id: $0.lastPathComponent) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func commitChunk(meetingID: String, descriptor: ChunkDescriptor) throws -> Meeting {
        var meeting = try load(id: meetingID)
        try validate(descriptor, meeting: meeting)
        guard !meeting.chunks.contains(where: { $0.id == descriptor.id }) else {
            throw StoreError.invalid("Chunk already committed.")
        }
        meeting.chunks.append(descriptor)
        try validate(meeting)
        let directory = try meetingURL(id: meetingID)
        let partial = try safeURL("audio/\(descriptor.id).partial", under: directory)
        try validateAudio(descriptor, directory: partial)
        try encoder.encode(descriptor).write(to: safeURL("chunk.json", under: partial), options: .atomic)
        try files.moveItem(at: partial, to: safeURL("audio/\(descriptor.id)", under: directory))
        sortChunks(&meeting)
        try save(meeting)
        return meeting
    }

    public func recover() throws -> [Meeting] {
        recoveryIssues = []
        busyMeetingIDs = []
        try files.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var meetings: [Meeting] = []
        for directory in try files.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey]) {
            guard (try directory.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { continue }
            do {
                busyMeetingIDs.append(directory.lastPathComponent)
                let checkedDirectory = try meetingURL(id: directory.lastPathComponent)
                let lockURL = try safeURL(".processing.lock", under: checkedDirectory)
                let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
                guard descriptor >= 0 else {
                    throw StoreError.invalid("Unable to verify processing cleanup before recovery.")
                }
                defer { close(descriptor) }
                guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                    if let meeting = try? load(id: directory.lastPathComponent) { meetings.append(meeting) }
                    continue
                }
                defer { flock(descriptor, LOCK_UN) }
                busyMeetingIDs.removeAll { $0 == directory.lastPathComponent }
                var meeting = try load(id: directory.lastPathComponent)
                if meeting.audioUnavailable {
                    meetings.append(meeting)
                    continue
                }
                let audioURL = try safeURL("audio", under: directory)
                var validChunkIDs = Set<String>()
                for chunkURL in try files.contentsOfDirectory(at: audioURL, includingPropertiesForKeys: nil) {
                    if chunkURL.lastPathComponent.hasSuffix(".partial") { continue }
                    do {
                        let checkedURL = try safeURL("audio/\(chunkURL.lastPathComponent)", under: directory)
                        let chunk: ChunkDescriptor = try decode(at: safeURL("chunk.json", under: checkedURL))
                        guard chunk.id == chunkURL.lastPathComponent else { throw StoreError.invalid("Chunk ID does not match directory.") }
                        try validate(chunk, meeting: meeting)
                        try validateAudio(chunk, directory: checkedURL)
                        if let existing = meeting.chunks.first(where: { $0.id == chunk.id }) {
                            guard existing == chunk else { throw StoreError.invalid("Chunk descriptor differs from manifest.") }
                        } else {
                            var candidate = meeting
                            candidate.chunks.append(chunk)
                            try validate(candidate)
                            meeting = candidate
                        }
                        validChunkIDs.insert(chunk.id)
                    } catch {
                        recoveryIssues.append("\(meeting.id)/\(chunkURL.lastPathComponent): \(error.localizedDescription)")
                        meeting.captureError = "A saved audio chunk could not be validated. See recovery details."
                        meeting.captureState = .interrupted
                    }
                }
                let unavailable = meeting.chunks.filter { !validChunkIDs.contains($0.id) }
                if !unavailable.isEmpty {
                    recoveryIssues.append("\(meeting.id): \(unavailable.count) unavailable chunk(s) excluded from processing; existing files preserved.")
                    meeting.captureState = .interrupted
                    meeting.captureError = "Some saved audio is missing or corrupt. Only validated chunks are available."
                    meeting.chunks.removeAll { !validChunkIDs.contains($0.id) }
                }
                if meeting.captureState.isActive {
                    meeting.captureState = .interrupted
                    meeting.captureError = "Capture ended unexpectedly. Committed audio was retained."
                }
                for index in meeting.intervals.indices where meeting.intervals[index].endUS == nil {
                    let interval = meeting.intervals[index]
                    meeting.intervals[index].endUS = meeting.chunks.filter { $0.generation == interval.generation }
                        .map(\.endUS).max() ?? interval.startUS
                }
                if ["running", "processing", "cancelling"].contains(meeting.processingStatus) {
                    meeting.processingStatus = "interrupted"
                    meeting.processingError = "Processing ended unexpectedly. Retry from retained audio."
                }
                sortChunks(&meeting)
                try save(meeting)
                meetings.append(meeting)
            } catch {
                recoveryIssues.append("\(directory.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return meetings.sorted { $0.startedAt > $1.startedAt }
    }

    public func artifactURL(meetingID: String, relativePath: String) throws -> URL {
        try safeURL(relativePath, under: meetingURL(id: meetingID))
    }

    private func sortChunks(_ meeting: inout Meeting) {
        meeting.chunks.sort { ($0.startUS, $0.id) < ($1.startUS, $1.id) }
    }

    private func validateID(_ id: String) throws {
        guard !id.isEmpty, id.count <= 128,
              id.unicodeScalars.allSatisfy({ Self.identifierCharacters.contains($0) }) else {
            throw StoreError.invalid("Invalid artifact identifier.")
        }
    }

    private func safeURL(_ path: String, under root: URL) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              !path.contains("\\"), !path.contains("\0") else { throw StoreError.invalid("Invalid relative artifact path.") }
        var componentURL = root
        for component in components {
            componentURL.appendPathComponent(String(component))
            if (try? files.destinationOfSymbolicLink(atPath: componentURL.path)) != nil {
                throw StoreError.invalid("Artifact paths cannot contain symbolic links.")
            }
        }
        let result = root.appendingPathComponent(path).standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath().path + "/"
        guard result.resolvingSymlinksInPath().path.hasPrefix(resolvedRoot) else {
            throw StoreError.invalid("Artifact path escapes its directory.")
        }
        return result
    }

    private func decode<T: Decodable>(at url: URL) throws -> T {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 16 * 1_024 * 1_024 else { throw StoreError.invalid("Metadata exceeds size limit.") }
        let data = try Data(contentsOf: url)
        let version = try JSONDecoder().decode(SchemaHeader.self, from: data).schemaVersion
        guard version == 1 else {
            throw StoreError.invalid("Unsupported metadata schema version; files were left unchanged.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private struct SchemaHeader: Decodable {
        let schemaVersion: Int
        enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version" }
    }

    private func validate(_ meeting: Meeting) throws {
        guard meeting.schemaVersion == 1 else { throw StoreError.invalid("Unsupported meeting schema version.") }
        guard ["auto", "zh", "en"].contains(meeting.asrLanguage ?? "auto") else { throw StoreError.invalid("Unsupported transcription language.") }
        try validateID(meeting.id)
        var previousEnd: Int64 = 0
        var generations = Set<Int>()
        for (index, interval) in meeting.intervals.enumerated() {
            guard interval.generation >= 0, generations.insert(interval.generation).inserted,
                  interval.startUS >= previousEnd, (interval.endUS ?? interval.startUS) >= interval.startUS,
                  interval.endUS != nil || index == meeting.intervals.count - 1 else {
                throw StoreError.invalid("Invalid capture intervals.")
            }
            previousEnd = interval.endUS ?? interval.startUS
        }
        guard Set(meeting.chunks.map(\.id)).count == meeting.chunks.count else { throw StoreError.invalid("Duplicate chunk IDs.") }
        for chunk in meeting.chunks { try validate(chunk, meeting: meeting) }
        for source in AudioSource.allSources {
            var end: Int64 = 0
            for chunk in meeting.chunks.filter({ $0.source == source }).sorted(by: { $0.startUS < $1.startUS }) {
                guard chunk.startUS >= end - 2 else { throw StoreError.invalid("Overlapping source audio chunks.") }
                end = chunk.endUS
            }
        }
        if let id = meeting.activeRevisionID { try validateID(id) }
        if let id = meeting.activeSummaryID { try validateID(id) }
        for id in [meeting.processingRunID, meeting.pendingRevisionID, meeting.pendingSummaryID,
                   meeting.pendingBaseRevisionID, meeting.pendingBaseSummaryID].compactMap({ $0 }) { try validateID(id) }
    }

    private func validate(_ chunk: ChunkDescriptor, meeting: Meeting) throws {
        try validateID(chunk.id)
        guard chunk.schemaVersion == 1, chunk.startUS >= 0, chunk.frameCount > 0,
              chunk.sampleRate.isFinite, chunk.sampleRate >= 1, chunk.sampleRate <= 768_000,
              chunk.channelCount > 0, chunk.channelCount <= 64, !chunk.format.isEmpty,
              Double(chunk.frameCount) * 1_000_000 / chunk.sampleRate < Double(Int64.max - chunk.startUS),
              chunk.relativePath == "audio/\(chunk.id)/audio.caf",
              let interval = meeting.intervals.first(where: { $0.generation == chunk.generation }),
              chunk.startUS >= interval.startUS, interval.endUS.map({ chunk.endUS - 2 <= $0 }) ?? true else {
            throw StoreError.invalid("Invalid audio chunk descriptor or capture interval.")
        }
    }

    private func validateAudio(_ chunk: ChunkDescriptor, directory: URL) throws {
        let file = try AVAudioFile(forReading: safeURL("audio.caf", under: directory))
        guard file.length == chunk.frameCount, file.fileFormat.sampleRate == chunk.sampleRate,
              Int(file.fileFormat.channelCount) == chunk.channelCount,
              file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM else {
            throw StoreError.invalid("Finalized audio does not match its descriptor.")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1) else {
            throw StoreError.invalid("Cannot allocate audio validation buffer.")
        }
        file.framePosition = file.length - 1
        try file.read(into: buffer, frameCount: 1)
        guard buffer.frameLength == 1 else { throw StoreError.invalid("Finalized audio is truncated.") }
    }
}
