import AfterwordCore
import Foundation

struct TranscriptRow: Identifiable {
    var segments: [TranscriptSegment]

    var id: String { segments[0].id }
    var startUS: Int64 { segments[0].start_us }
    var endUS: Int64 { segments[segments.count - 1].end_us }
    var source: AudioSource { segments[0].source }
    var speakerID: String? { segments[0].speaker_id }

    var text: String {
        var result = ""
        for segment in segments {
            let part = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { continue }
            if !result.isEmpty && TranscriptRows.needsSpace(after: result, before: part) { result += " " }
            result += part
        }
        return result
    }
}

enum TranscriptRows {
    static func make(_ segments: [TranscriptSegment], compact: Bool) -> [TranscriptRow] {
        guard compact else { return segments.map { TranscriptRow(segments: [$0]) } }
        var rows: [TranscriptRow] = []
        for segment in segments {
            if let index = rows.indices.last, canJoin(rows[index], segment) {
                rows[index].segments.append(segment)
            } else {
                rows.append(TranscriptRow(segments: [segment]))
            }
        }
        return rows
    }

    private static func canJoin(_ row: TranscriptRow, _ next: TranscriptSegment) -> Bool {
        guard let previous = row.segments.last, let speaker = previous.speaker_id,
              next.speaker_id == speaker && next.source == previous.source,
              !previous.overlap && !next.overlap,
              next.start_us >= previous.end_us && next.start_us - previous.end_us <= 600_000,
              next.end_us - row.startUS <= 12_000_000 else { return false }
        let ending = previous.text.trimmingCharacters(in: .whitespacesAndNewlines).last
        return ending.map { !".!?。！？".contains($0) } ?? false
    }

    static func needsSpace(after left: String, before right: String) -> Bool {
        guard let last = left.unicodeScalars.last, let first = right.unicodeScalars.first else { return false }
        if isCJK(last) && isCJK(first) { return false }
        if ",.!?;:，。！？；：)]}".unicodeScalars.contains(first) { return false }
        return true
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        (0x3400...0x9FFF).contains(scalar.value) || (0xF900...0xFAFF).contains(scalar.value)
            || (0x3040...0x30FF).contains(scalar.value) || (0xAC00...0xD7AF).contains(scalar.value)
    }
}
