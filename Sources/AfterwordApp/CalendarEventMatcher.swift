import Foundation

enum CalendarMatch: Equatable, Sendable {
    case none
    case unique(CalendarEvent)
    case ambiguous([CalendarEvent])
    case stale
}

enum CalendarEventMatcher {
    static let maximumAge: TimeInterval = 300

    static func match(window: CalendarEventWindow?, at date: Date) -> CalendarMatch {
        guard let window else { return .none }
        guard date.timeIntervalSince1970.isFinite, (try? window.validate()) != nil else { return .stale }
        let age = date.timeIntervalSince(window.fetchedAt)
        guard age >= 0, age <= maximumAge, window.queryStart <= date, date < window.queryEnd else { return .stale }
        let candidates = window.events.filter { event in
            guard ["confirmed", "tentative"].contains(event.status), !event.isDeclinedOnCalendar,
                  case let .timed(start, end) = event.time else { return false }
            return start <= date && date < end
        }.sorted { $0.id < $1.id }
        switch candidates.count {
        case 0: return .none
        case 1: return .unique(candidates[0])
        default: return .ambiguous(candidates)
        }
    }
}
