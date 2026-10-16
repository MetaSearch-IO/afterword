import Foundation

public enum AudioSource: String, Codable, Sendable { case microphone, system }

public enum CaptureState: String, Codable, Sendable {
    case starting, recording, paused, finalizing, stopped, interrupted

    public var isActive: Bool {
        self == .starting || self == .recording || self == .paused || self == .finalizing
    }
}

public struct CaptureInterval: Codable, Equatable, Sendable {
    public var generation: Int
    public var startUS: Int64
    public var endUS: Int64?

    public init(generation: Int, startUS: Int64, endUS: Int64? = nil) {
        self.generation = generation
        self.startUS = startUS
        self.endUS = endUS
    }

    enum CodingKeys: String, CodingKey {
        case generation
        case startUS = "start_us", endUS = "end_us"
    }
}

public struct ChunkDescriptor: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var id: String
    public var source: AudioSource
    public var generation: Int
    public var startUS: Int64
    public var frameCount: Int64
    public var sampleRate: Double
    public var channelCount: Int
    public var format: String
    public var relativePath: String

    public init(id: String, source: AudioSource, generation: Int, startUS: Int64,
                frameCount: Int64, sampleRate: Double, channelCount: Int,
                format: String = "pcm", relativePath: String) {
        self.id = id
        self.source = source
        self.generation = generation
        self.startUS = startUS
        self.frameCount = frameCount
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.format = format
        self.relativePath = relativePath
    }

    public var durationUS: Int64 { Int64((Double(frameCount) * 1_000_000 / sampleRate).rounded()) }
    public var endUS: Int64 { startUS + durationUS }

    enum CodingKeys: String, CodingKey {
        case id, source, generation, format
        case schemaVersion = "schema_version", startUS = "start_us", frameCount = "frame_count"
        case sampleRate = "sample_rate", channelCount = "channel_count", relativePath = "relative_path"
    }
}

public struct Meeting: Codable, Identifiable, Equatable, Sendable {
    public var schemaVersion = 1
    public var id: String
    public var title: String
    public var startedAt: String
    public var asrLanguage: String?
    public var captureState: CaptureState = .starting
    public var captureError: String?
    public var intervals: [CaptureInterval] = []
    public var chunks: [ChunkDescriptor] = []
    public var audioRemovalStartedAt: String?
    public var audioRemovedAt: String?
    public var processingStatus: String = "idle"
    public var processingStage: String?
    public var processingError: String?
    public var processingRunID: String?
    public var pendingRevisionID: String?
    public var pendingSummaryID: String?
    public var pendingBaseRevisionID: String?
    public var pendingBaseSummaryID: String?
    public var processingNameMapRevision: String?
    public var activeRevisionID: String?
    public var activeSummaryID: String?
    public var speakerNames: [String: [String: String]] = [:]

    public init(id: String = UUID().uuidString, title: String, startedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.startedAt = ISO8601DateFormatter().string(from: startedAt)
    }

    public var retainedDurationUS: Int64 {
        var total: Int64 = 0
        var end: Int64 = 0
        for chunk in chunks.sorted(by: { $0.startUS < $1.startUS }) {
            total += max(0, chunk.endUS - max(end, chunk.startUS))
            end = max(end, chunk.endUS)
        }
        return total
    }

    public var audioUnavailable: Bool {
        audioRemovalStartedAt != nil || audioRemovedAt != nil
    }

    enum CodingKeys: String, CodingKey {
        case id, title, intervals, chunks
        case asrLanguage = "asr_language"
        case schemaVersion = "schema_version", startedAt = "started_at"
        case captureState = "capture_state", captureError = "capture_error"
        case audioRemovalStartedAt = "audio_removal_started_at", audioRemovedAt = "audio_removed_at"
        case processingStatus = "processing_status", processingStage = "processing_stage"
        case processingError = "processing_error", activeRevisionID = "active_revision_id"
        case processingRunID = "processing_run_id", pendingRevisionID = "pending_revision_id", pendingSummaryID = "pending_summary_id"
        case pendingBaseRevisionID = "pending_base_revision_id", pendingBaseSummaryID = "pending_base_summary_id"
        case processingNameMapRevision = "processing_name_map_revision"
        case activeSummaryID = "active_summary_id", speakerNames = "speaker_names"
    }
}

extension AudioSource {
    public static let allSources: [AudioSource] = [.microphone, .system]
}

public enum StoreError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}
