import Testing
@testable import AfterwordCore

struct TimelineTests {
    @Test func boundaryStraddlingBuffersAreClippedAndOldGenerationRejected() {
        let timeline = CaptureTimeline(intervals: [
            CaptureInterval(generation: 0, startUS: 0, endUS: 1_000_000),
            CaptureInterval(generation: 1, startUS: 2_000_000)
        ])
        #expect(timeline.intersections(bufferStartUS: 990_000, frameCount: 960, sampleRate: 48_000, generation: 0)
                == [SampleSlice(offset: 0, count: 480, startUS: 990_000)])
        #expect(timeline.intersections(bufferStartUS: 1_990_000, frameCount: 960, sampleRate: 48_000, generation: 1)
                == [SampleSlice(offset: 480, count: 480, startUS: 2_000_000)])
        #expect(timeline.intersections(bufferStartUS: 2_000_000, frameCount: 960, sampleRate: 48_000, generation: 0).isEmpty)
        #expect(timeline.intersections(bufferStartUS: 1_500_000, frameCount: 960, sampleRate: 48_000, generation: 1).isEmpty)
    }

    @Test func fractionalSampleBoundaryNeverIncludesPausedSample() {
        let timeline = CaptureTimeline(intervals: [CaptureInterval(generation: 0, startUS: 11, endUS: 99)])
        #expect(timeline.intersections(bufferStartUS: 0, frameCount: 10, sampleRate: 48_000, generation: 0)
                == [SampleSlice(offset: 1, count: 3, startUS: 21)])
    }

    @Test func modelIntervalSplitsAcrossPauseAndSourceGap() throws {
        let pieces = [
            TimelinePiece(sampleStart: 0, sampleEnd: 16_000, meetingStartUS: 500_000, sampleRate: 16_000),
            TimelinePiece(sampleStart: 16_000, sampleEnd: 32_000, meetingStartUS: 3_000_000, sampleRate: 16_000)
        ]
        let mapped = try TimelineMapper.map(startSample: 8_000, endSample: 24_000, pieces: pieces)
        #expect(mapped == [
            MappedInterval(sampleStart: 8_000, sampleEnd: 16_000, startUS: 1_000_000, endUS: 1_500_000),
            MappedInterval(sampleStart: 16_000, sampleEnd: 24_000, startUS: 3_000_000, endUS: 3_500_000)
        ])
        #expect(throws: (any Error).self) { try TimelineMapper.map(startSample: 0, endSample: 10, pieces: pieces.reversed()) }
    }
}
