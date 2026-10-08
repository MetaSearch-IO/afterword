import Foundation

enum TranscriptSearch {
    static func matches(_ query: String, transcript: Transcript, names: [String: String]) -> [String] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let labels = Dictionary(uniqueKeysWithValues: transcript.speakers.map { ($0.id, names[$0.id] ?? $0.label) })
        return transcript.segments.filter { segment in
            segment.text.localizedStandardContains(query)
                || (segment.speaker_id.flatMap { labels[$0] } ?? "Unknown").localizedStandardContains(query)
        }.map(\.id)
    }

    static func next(in matches: [String], after current: String?, backwards: Bool = false) -> String? {
        guard !matches.isEmpty else { return nil }
        guard let current, let index = matches.firstIndex(of: current) else { return backwards ? matches.last : matches.first }
        return matches[(index + (backwards ? matches.count - 1 : 1)) % matches.count]
    }
}
