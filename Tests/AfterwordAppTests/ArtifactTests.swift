import AfterwordCore
import XCTest
@testable import AfterwordApp

final class ArtifactTests: XCTestCase {
    private func fixture() -> (Meeting, Transcript) {
        var meeting = Meeting(id: "meeting", title: "Fixture")
        meeting.chunks = [ChunkDescriptor(id: "audio", source: .microphone, generation: 0, startUS: 0,
                          frameCount: 16_000, sampleRate: 16_000, channelCount: 1, relativePath: "audio/audio/audio.caf")]
        let transcript = Transcript(schema_version: 1, run_id: "run", meeting_id: "meeting", revision_id: "revision",
                                    segments: [TranscriptSegment(id: "s1", source: .microphone, start_us: 0, end_us: 1_000_000,
                                    text: "I will send it tomorrow", speaker_id: "local", attribution_reason: "microphone", overlap: false)],
                                    speakers: [TranscriptSpeaker(id: "local", source: .microphone, label: "You")],
                                    coverage: [TranscriptCoverage(source: .microphone, start_us: 0, end_us: 1_000_000)], warnings: [])
        return (meeting, transcript)
    }

    func testTranscriptCannotInventRetainedCoverage() throws {
        let (meeting, transcript) = fixture()
        try Artifacts.validate(transcript, meeting: meeting, revisionID: "revision", runID: "run")
        var truncated = meeting
        truncated.chunks[0].frameCount = 8_000
        XCTAssertThrowsError(try Artifacts.validate(transcript, meeting: truncated, revisionID: "revision"))
        XCTAssertThrowsError(try Artifacts.validate(transcript, meeting: meeting, revisionID: "other"))
    }

    func testSummaryRequiresRealReferencesAndExplicitOwnersAndDates() throws {
        let (_, transcript) = fixture()
        func notes(ref: String, owner: String?, due: String?, text: String = "I will send it tomorrow") -> MeetingSummary {
            MeetingSummary(schema_version: 1, run_id: "summary-run", meeting_id: "meeting", revision_id: "revision",
                summary_id: "summary", name_map_revision: "hash", covered_segment_ids: ["s1"], overview: [], discussion_points: [], decisions: [],
                action_items: [SummaryAction(text: text, segment_ids: [ref], owner_speaker_id: owner,
                    owner_evidence_segment_ids: owner == nil ? [] : [ref], due_date: due,
                    due_date_evidence_segment_ids: due == nil ? [] : [ref])], open_questions: [])
        }
        try Artifacts.validate(notes(ref: "s1", owner: "local", due: "tomorrow"), transcript: transcript, summaryID: "summary")
        XCTAssertThrowsError(try Artifacts.validate(notes(ref: "invented", owner: nil, due: nil), transcript: transcript, summaryID: "summary"))
        XCTAssertThrowsError(try Artifacts.validate(notes(ref: "s1", owner: "remote", due: nil), transcript: transcript, summaryID: "summary"))
        XCTAssertThrowsError(try Artifacts.validate(notes(ref: "s1", owner: "local", due: "Friday"), transcript: transcript, summaryID: "summary"))
        XCTAssertThrowsError(try Artifacts.validate(notes(ref: "s1", owner: "local", due: nil, text: "send it tomorrow"), transcript: transcript, summaryID: "summary"))
        XCTAssertThrowsError(try Artifacts.validate(notes(ref: "s1", owner: nil, due: nil, text: "Send report"), transcript: transcript, summaryID: "summary"))
    }

    func testMultiSegmentActionKeepsExactQuoteAndBoundedOwnerEvidence() throws {
        let segments = [TranscriptSegment(id: "s1", source: .system, start_us: 0, end_us: 500_000,
                          text: "I'll send", speaker_id: "grant", attribution_reason: "exclusive", overlap: false),
                        TranscriptSegment(id: "s2", source: .system, start_us: 500_000, end_us: 900_000,
                          text: "a spreadsheet", speaker_id: nil, attribution_reason: "incomplete_speaker_timing", overlap: false),
                        TranscriptSegment(id: "s3", source: .system, start_us: 900_000, end_us: 1_300_000,
                          text: "for projections tomorrow", speaker_id: "grant", attribution_reason: "exclusive", overlap: false)]
        let transcript = Transcript(schema_version: 1, run_id: "run", meeting_id: "meeting", revision_id: "revision",
                                    segments: segments, speakers: [TranscriptSpeaker(id: "grant", source: .system, label: "Grant")],
                                    coverage: [TranscriptCoverage(source: .system, start_us: 0, end_us: 1_300_000)], warnings: [])
        func notes(_ text: String, refs: [String], ownerRefs: [String]) -> MeetingSummary {
            MeetingSummary(schema_version: 1, run_id: "summary-run", meeting_id: "meeting", revision_id: "revision",
                summary_id: "summary", name_map_revision: "hash", covered_segment_ids: ["s1", "s2", "s3"],
                overview: [], discussion_points: [], decisions: [], action_items: [SummaryAction(text: text,
                    segment_ids: refs, owner_speaker_id: "grant", owner_evidence_segment_ids: ownerRefs,
                    due_date: "tomorrow", due_date_evidence_segment_ids: ["s3"])], open_questions: [])
        }
        try Artifacts.validate(notes("I'll send a spreadsheet for projections tomorrow", refs: ["s1", "s2", "s3"], ownerRefs: ["s1"]),
                               transcript: transcript, summaryID: "summary")
        XCTAssertThrowsError(try Artifacts.validate(notes("I'll send projections tomorrow", refs: ["s1", "s2", "s3"], ownerRefs: ["s1"]),
                                                  transcript: transcript, summaryID: "summary"))
        XCTAssertThrowsError(try Artifacts.validate(notes("I'll send a spreadsheet for projections tomorrow", refs: ["s1", "s3"], ownerRefs: ["s1"]),
                                                  transcript: transcript, summaryID: "summary"))
        XCTAssertThrowsError(try Artifacts.validate(notes("I'll send a spreadsheet for projections tomorrow", refs: ["s1", "s2", "s3"], ownerRefs: ["s2"]),
                                                  transcript: transcript, summaryID: "summary"))
    }

    func testNameMapHashIsStableAndChangesOnRename() throws {
        XCTAssertEqual(try Artifacts.nameMapRevision(["a": "甲", "b": "Bob"]), try Artifacts.nameMapRevision(["b": "Bob", "a": "甲"]))
        XCTAssertNotEqual(try Artifacts.nameMapRevision(["a": "甲"]), try Artifacts.nameMapRevision(["a": "乙"]))
    }
}
