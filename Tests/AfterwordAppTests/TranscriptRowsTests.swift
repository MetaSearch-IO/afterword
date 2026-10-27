import AfterwordCore
import XCTest
@testable import AfterwordApp

final class TranscriptRowsTests: XCTestCase {
    private func segment(_ id: String, _ text: String, _ start: Int64, _ end: Int64,
                         speaker: String? = "remote-001", source: AudioSource = .system,
                         overlap: Bool = false) -> TranscriptSegment {
        TranscriptSegment(id: id, source: source, start_us: start, end_us: end, text: text,
                          speaker_id: speaker, attribution_reason: speaker == nil ? "incomplete_speaker_timing" : "exclusive",
                          overlap: overlap)
    }

    func testConfirmedWordFragmentsBecomeOneDisplayRowWithoutChangingSegments() {
        let fragments = [segment("one", "use cases", 110_000_000, 110_500_000),
                         segment("two", "are", 110_500_000, 111_000_000),
                         segment("three", "I mean", 111_000_000, 112_000_000),
                         segment("four", "I can", 112_000_000, 112_500_000),
                         segment("five", "think of", 112_500_000, 113_000_000),
                         segment("six", "quite a few", 113_000_000, 114_000_000),
                         segment("unknown", "Mm-hmm.", 114_000_000, 114_600_000, speaker: nil)]
        let rows = TranscriptRows.make(fragments, compact: true)
        XCTAssertEqual(rows.map(\.id), ["one", "unknown"])
        XCTAssertEqual(rows[0].segments.map(\.id), fragments.prefix(6).map(\.id))
        XCTAssertEqual(rows[0].text, "use cases are I mean I can think of quite a few")
        XCTAssertEqual(rows[0].endUS, 114_000_000)
        XCTAssertEqual(TranscriptRows.make(fragments, compact: false).count, fragments.count)
    }

    func testGroupingStopsAtSpeakerSourceOverlapPauseAndSentenceBoundary() {
        let segments = [segment("a", "Hello.", 0, 500_000),
                        segment("b", "Next", 500_000, 900_000),
                        segment("c", "speaker", 900_000, 1_300_000, speaker: "remote-002"),
                        segment("d", "microphone", 1_300_000, 1_700_000, source: .microphone),
                        segment("e", "overlap", 1_700_000, 2_100_000, source: .microphone, overlap: true),
                        segment("f", "later", 3_000_000, 3_400_000, source: .microphone)]
        XCTAssertEqual(TranscriptRows.make(segments, compact: true).map(\.id), segments.map(\.id))
    }

    func testChineseFragmentsJoinWithoutInsertedSpaces() {
        let segments = [segment("one", "你好", 0, 400_000),
                        segment("two", "世界。", 400_000, 800_000),
                        segment("three", "下一句", 800_000, 1_200_000)]
        XCTAssertEqual(TranscriptRows.make(segments, compact: true).map(\.text), ["你好世界。", "下一句"])
    }
}
