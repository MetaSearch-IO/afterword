import AfterwordCore
import XCTest
@testable import AfterwordApp

final class MeetingStatusTests: XCTestCase {
    func testCompletedMeetingsShowReadyRegardlessOfRecordingOutcome() {
        for capture in [CaptureState.stopped, .interrupted] {
            var meeting = Meeting(title: "Completed meeting")
            meeting.captureState = capture
            meeting.processingStatus = "completed"
            meeting.activeRevisionID = "revision"
            meeting.activeSummaryID = "summary"
            XCTAssertEqual(MeetingStatus.primary(meeting).title, "Transcript and notes ready")
            XCTAssertEqual(MeetingStatus.recording(meeting).tone, capture == .interrupted ? .warning : .neutral)
        }
    }

    func testRecordingTakesPriorityOverExistingResults() {
        var meeting = Meeting(title: "Active recording")
        meeting.captureState = .recording
        meeting.processingStatus = "completed"
        meeting.activeRevisionID = "revision"
        meeting.activeSummaryID = "summary"
        XCTAssertEqual(MeetingStatus.primary(meeting).title, "Recording")
    }

    func testProcessingFailureDoesNotHideSavedResultsOrClaimReady() {
        var meeting = Meeting(title: "Retry failed")
        meeting.captureState = .stopped
        meeting.activeRevisionID = "old-revision"
        meeting.activeSummaryID = "old-notes"
        for (status, title) in [("failed", "Processing failed"), ("cancelled", "Processing cancelled"),
                                ("interrupted", "Processing interrupted"), ("queued", "Queued"), ("paused", "Processing paused")] {
            meeting.processingStatus = status
            XCTAssertEqual(MeetingStatus.primary(meeting).title, title)
            XCTAssertEqual(MeetingStatus.savedResults(meeting), "Saved transcript and notes available")
        }
        meeting.activeSummaryID = nil
        XCTAssertEqual(MeetingStatus.savedResults(meeting), "Saved transcript available")
        meeting.activeRevisionID = nil
        XCTAssertNil(MeetingStatus.savedResults(meeting))
    }

    func testEarlyTranscriptIsAvailableWhileLabelingAndNotesContinue() {
        var meeting = Meeting(title: "In progress")
        meeting.captureState = .interrupted
        meeting.processingStatus = "processing"
        meeting.activeRevisionID = "preview"
        for (stage, title) in [("preflight", "Checking setup"), ("preparing", "Preparing audio"), ("preparation", "Preparing audio"),
                               ("asr", "Transcribing"), ("transcript", "Saving transcript"), ("alignment", "Saving transcript"),
                               ("diarization", "Labeling speakers"), ("summary", "Writing notes")] {
            meeting.processingStage = stage
            XCTAssertEqual(MeetingStatus.primary(meeting).title, title)
            XCTAssertEqual(MeetingStatus.savedResults(meeting), "Saved transcript available")
        }
        XCTAssertEqual(MeetingStatus.primary(meeting, stage: "cancelling").title, "Stopping processing")
        XCTAssertEqual(MeetingStatus.primary(meeting, stage: "future-stage").title, "Processing")
    }

    func testNoNotesDoesNotFalselyMeanNoSpeechAndMissingArtifactsDoNotMeanReady() {
        var meeting = Meeting(title: "Recovered transcript")
        meeting.captureState = .stopped
        meeting.processingStatus = "completed"
        meeting.activeRevisionID = "revision"
        XCTAssertEqual(MeetingStatus.primary(meeting).title, "Transcript ready")
        meeting.activeRevisionID = nil
        XCTAssertEqual(MeetingStatus.primary(meeting).title, "No transcript saved")
        meeting.activeSummaryID = "orphaned-notes"
        XCTAssertEqual(MeetingStatus.primary(meeting).title, "No transcript saved")
        meeting.processingStatus = "unknown-future-value"
        XCTAssertEqual(MeetingStatus.primary(meeting).title, "Status unavailable")
    }

    func testSavedAudioAwaitsTranscriptionAndInterruptionRetainsItsWarning() {
        var meeting = Meeting(title: "Interrupted before processing")
        meeting.captureState = .interrupted
        XCTAssertEqual(MeetingStatus.primary(meeting).title, "No audio saved")
        XCTAssertTrue(MeetingStatus.recording(meeting).explanation.contains("No audio was saved"))
        meeting.chunks = [ChunkDescriptor(id: "audio", source: .microphone, generation: 0, startUS: 0,
            frameCount: 16000, sampleRate: 16000, channelCount: 1, relativePath: "audio/audio/audio.caf")]
        XCTAssertEqual(MeetingStatus.primary(meeting).title, "Ready to transcribe")
        XCTAssertTrue(MeetingStatus.recording(meeting).explanation.contains("Saved audio is available"))
    }

    func testRecordingAndProcessingPauseAreDistinct() {
        var meeting = Meeting(title: "Paused")
        meeting.captureState = .paused
        meeting.processingStatus = "paused"
        XCTAssertEqual(MeetingStatus.primary(meeting).title, "Recording paused")
        meeting.captureState = .stopped
        XCTAssertEqual(MeetingStatus.primary(meeting).title, "Processing paused")
        for (state, title) in [(CaptureState.starting, "Starting recording"), (.finalizing, "Saving recording")] {
            meeting.captureState = state
            XCTAssertEqual(MeetingStatus.primary(meeting).title, title)
        }
    }

    func testDatesUseLocalTimeAcrossDayBoundaryAndSupportFractionalTimestamps() {
        let locale = Locale(identifier: "en_US_POSIX")
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        let utc = TimeZone(secondsFromGMT: 0)!
        let raw = "2026-09-30T23:30:00Z"
        let local = MeetingStatus.date(raw, locale: locale, timeZone: shanghai)
        XCTAssertTrue(local.contains("Oct 1, 2026"), local)
        XCTAssertTrue(local.contains("7:30"), local)
        XCTAssertTrue(MeetingStatus.date(raw, locale: locale, timeZone: utc).contains("Sep 30, 2026"))
        XCTAssertEqual(MeetingStatus.date("2026-09-30T23:30:00.125Z", locale: locale, timeZone: shanghai), local)
        XCTAssertEqual(MeetingStatus.date("2026-10-01T07:30:00+08:00", locale: locale, timeZone: shanghai), local)
        XCTAssertEqual(MeetingStatus.date("invalid saved date", locale: locale, timeZone: shanghai), "invalid saved date")
    }
}
