import Foundation

public struct SampleSlice: Equatable, Sendable {
    public let offset: Int
    public let count: Int
    public let startUS: Int64
}

public struct CaptureTimeline: Sendable {
    public var intervals: [CaptureInterval]

    public init(intervals: [CaptureInterval] = []) { self.intervals = intervals }

    public func intersections(bufferStartUS: Int64, frameCount: Int, sampleRate: Double,
                              generation: Int) -> [SampleSlice] {
        guard frameCount > 0, sampleRate.isFinite, sampleRate > 0,
              Double(frameCount) * 1_000_000 / sampleRate < Double(Int64.max),
              Double(bufferStartUS) + Double(frameCount) * 1_000_000 / sampleRate < Double(Int64.max) else { return [] }
        return intervals.filter { $0.generation == generation }.compactMap { interval in
            guard interval.startUS >= 0, (interval.endUS ?? interval.startUS) >= interval.startUS else { return nil }
            let lower = max(0, ceil((Double(interval.startUS) - Double(bufferStartUS)) * sampleRate / 1_000_000))
            let upper = min(Double(frameCount), interval.endUS.map {
                floor((Double($0) - Double(bufferStartUS)) * sampleRate / 1_000_000)
            } ?? Double(frameCount))
            guard upper > lower, lower < Double(frameCount) else { return nil }
            return SampleSlice(offset: Int(lower), count: Int(upper - lower),
                               startUS: bufferStartUS + Int64((lower * 1_000_000 / sampleRate).rounded()))
        }
    }
}

public struct TimelinePiece: Equatable, Sendable {
    public let sampleStart: Int64
    public let sampleEnd: Int64
    public let meetingStartUS: Int64
    public let sampleRate: Double

    public init(sampleStart: Int64, sampleEnd: Int64, meetingStartUS: Int64, sampleRate: Double) {
        self.sampleStart = sampleStart
        self.sampleEnd = sampleEnd
        self.meetingStartUS = meetingStartUS
        self.sampleRate = sampleRate
    }
}

public struct MappedInterval: Equatable, Sendable {
    public let sampleStart: Int64
    public let sampleEnd: Int64
    public let startUS: Int64
    public let endUS: Int64
}

public enum TimelineMapper {
    public static func map(startSample: Int64, endSample: Int64, pieces: [TimelinePiece]) throws -> [MappedInterval] {
        guard startSample >= 0, endSample >= startSample else { throw StoreError.invalid("Invalid model interval.") }
        var previousEnd: Int64 = 0
        var previousMeetingEnd: Int64 = 0
        var result: [MappedInterval] = []
        for piece in pieces {
            guard piece.sampleStart >= previousEnd, piece.sampleEnd > piece.sampleStart,
                  piece.meetingStartUS >= previousMeetingEnd, piece.sampleRate.isFinite,
                  piece.sampleRate > 0 else { throw StoreError.invalid("Invalid timeline mapping.") }
            func time(_ sample: Int64) throws -> Int64 {
                let value = Double(piece.meetingStartUS) + Double(sample - piece.sampleStart) * 1_000_000 / piece.sampleRate
                guard value >= 0, value < Double(Int64.max) else { throw StoreError.invalid("Timeline overflow.") }
                return Int64(value.rounded())
            }
            previousEnd = piece.sampleEnd
            previousMeetingEnd = try time(piece.sampleEnd)
            let start = max(startSample, piece.sampleStart)
            let end = min(endSample, piece.sampleEnd)
            if end > start {
                result.append(try MappedInterval(sampleStart: start, sampleEnd: end, startUS: time(start), endUS: time(end)))
            }
        }
        return result
    }
}
