import AfterwordCore
import Foundation

struct MeetingStatus {
    enum Tone: Equatable { case neutral, active, recording, success, warning }
    let title: String
    let symbol: String
    let tone: Tone
    let explanation: String

    static func primary(_ meeting: Meeting, stage: String? = nil) -> MeetingStatus {
        meeting.captureState.isActive ? recording(meeting) : processing(meeting, stage: stage)
    }

    static func recording(_ meeting: Meeting) -> MeetingStatus {
        switch meeting.captureState {
        case .starting:
            return .init(title: "Starting recording", symbol: "record.circle", tone: .active, explanation: "Setting up microphone and system audio capture.")
        case .recording:
            return .init(title: "Recording", symbol: "record.circle.fill", tone: .recording, explanation: "Microphone and system audio capture is active.")
        case .paused:
            return .init(title: "Recording paused", symbol: "pause.circle", tone: .neutral, explanation: "Paused audio is excluded from this meeting.")
        case .finalizing:
            return .init(title: "Saving recording", symbol: "square.and.arrow.down", tone: .active, explanation: "Finishing and saving recorded audio.")
        case .stopped:
            return .init(title: "Recording saved", symbol: "waveform", tone: .neutral, explanation: "Recording ended normally. Transcription and notes have a separate processing status.")
        case .interrupted:
            let retained = meeting.chunks.isEmpty ? "No audio was saved." : "Saved audio is available to review or process."
            return .init(title: "Recording interrupted", symbol: "exclamationmark.triangle.fill", tone: .warning,
                         explanation: "Recording ended unexpectedly. \(retained)")
        }
    }

    static func processing(_ meeting: Meeting, stage: String? = nil) -> MeetingStatus {
        switch meeting.processingStatus {
        case "processing":
            return .init(title: stageTitle(stage ?? meeting.processingStage), symbol: "gearshape.2", tone: .active,
                         explanation: "Processing saved audio locally. Saved results remain available while work continues.")
        case "queued":
            return .init(title: "Queued", symbol: "clock", tone: .neutral, explanation: "Waiting for recording or another processing job to finish.")
        case "paused":
            return .init(title: "Processing paused", symbol: "pause.circle", tone: .neutral, explanation: "Processing is paused. Resume Processing continues from reusable completed work.")
        case "failed":
            return .init(title: "Processing failed", symbol: "exclamationmark.circle", tone: .warning, explanation: "Processing failed. Saved audio and accepted results are preserved; see the meeting details before retrying.")
        case "cancelled":
            return .init(title: "Processing cancelled", symbol: "stop.circle", tone: .neutral, explanation: "Processing was cancelled. Saved audio and accepted results are preserved.")
        case "interrupted":
            return .init(title: "Processing interrupted", symbol: "exclamationmark.circle", tone: .warning, explanation: "An earlier processing job ended unexpectedly. Saved work may be reusable on retry.")
        case "empty":
            return .init(title: "No audio saved", symbol: "waveform", tone: .neutral, explanation: "There is no retained audio to transcribe.")
        case "idle", "completed", "transcript_ready":
            if meeting.activeRevisionID != nil {
                if meeting.activeSummaryID != nil {
                    return .init(title: "Transcript and notes ready", symbol: "checkmark.circle.fill", tone: .success, explanation: "The transcript and notes cover the audio that was saved.")
                }
                return .init(title: "Transcript ready", symbol: "doc.text", tone: .success, explanation: "A transcript is saved. Open the meeting to review it or continue processing.")
            }
            if meeting.processingStatus != "idle" {
                return .init(title: "No transcript saved", symbol: "exclamationmark.circle", tone: .warning, explanation: "No accepted transcript is available. Review the meeting details and retry processing.")
            }
            if meeting.chunks.isEmpty {
                return .init(title: "No audio saved", symbol: "waveform", tone: .neutral, explanation: "There is no retained audio to transcribe.")
            }
            return .init(title: "Ready to transcribe", symbol: "waveform", tone: .neutral, explanation: "Audio is saved. Choose Process Saved Audio to create a transcript and notes.")
        default:
            return .init(title: "Status unavailable", symbol: "questionmark.circle", tone: .warning, explanation: "The processing state is not recognized. Review the meeting details.")
        }
    }

    static func stageTitle(_ stage: String?) -> String {
        switch stage {
        case "preflight": "Checking setup"
        case "preparing", "preparation": "Preparing audio"
        case "asr": "Transcribing"
        case "transcript", "alignment": "Saving transcript"
        case "diarization": "Labeling speakers"
        case "summary": "Writing notes"
        case "cancelling": "Stopping processing"
        default: "Processing"
        }
    }

    static func savedResults(_ meeting: Meeting) -> String? {
        guard !meeting.captureState.isActive, meeting.activeRevisionID != nil,
              ["processing", "queued", "paused", "failed", "cancelled", "interrupted"].contains(meeting.processingStatus) else { return nil }
        return meeting.activeSummaryID == nil ? "Saved transcript available" : "Saved transcript and notes available"
    }

    static func date(_ value: String, locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let parser = ISO8601DateFormatter()
        var parsed = parser.date(from: value)
        if parsed == nil {
            parser.formatOptions.insert(.withFractionalSeconds)
            parsed = parser.date(from: value)
        }
        guard let parsed else { return value }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("yMMMdjm")
        return formatter.string(from: parsed)
    }
}
