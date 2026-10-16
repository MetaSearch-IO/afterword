import AVFoundation
import AfterwordCore
import CoreMedia
import ScreenCaptureKit
import XCTest
@testable import AfterwordApp

final class CaptureEngineTests: XCTestCase, @unchecked Sendable {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64 = 0
        func set(_ microseconds: Int64) { lock.withLock { value = microseconds } }
        func now() -> CMTime { lock.withLock { CMTime(value: value, timescale: 1_000_000) } }
    }

    private func temporaryStore() throws -> (URL, MeetingStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("afterword-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, MeetingStore(rootURL: directory))
    }

    private func sample(frames: Int = 16_000, value: Float = 0.25) throws -> CMSampleBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        pcm.frameLength = AVAudioFrameCount(frames)
        for frame in 0..<frames { pcm.floatChannelData![0][frame] = value }
        var description: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                       asbd: format.streamDescription, layoutSize: 0, layout: nil,
                       magicCookieSize: 0, magicCookie: nil, extensions: nil,
                       formatDescriptionOut: &description), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 16_000),
                                        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil,
                       dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                       formatDescription: description, sampleCount: frames,
                       sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                       sampleSizeEntryCount: 0, sampleSizeArray: nil,
                       sampleBufferOut: &buffer), noErr)
        let result = try XCTUnwrap(buffer)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(result,
                       blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
                       flags: 0, bufferList: pcm.audioBufferList), noErr)
        XCTAssertEqual(CMSampleBufferSetDataReady(result), noErr)
        return result
    }

    func testPauseResumeRejectsDelayedAndPausedAudioAndWritesSeparateSources() async throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock()
        let engine = try CaptureEngine(store: store, hostTime: clock.now) { _ in }
        let pcm = try sample()
        clock.set(1_000_000)
        engine.enqueue(pcm, source: .microphone, hostTimestamp: .zero)
        engine.enqueue(pcm, source: .system, hostTimestamp: .zero)
        try await engine.pause()
        clock.set(2_000_000)
        engine.enqueue(try sample(value: 0.75), source: .microphone, hostTimestamp: CMTime(value: 1, timescale: 1))
        try await engine.resume()
        engine.enqueue(try sample(value: 0.9), source: .microphone, hostTimestamp: .zero)
        clock.set(3_000_000)
        engine.enqueue(pcm, source: .microphone, hostTimestamp: CMTime(value: 2, timescale: 1))
        let meeting = try await engine.stop()
        XCTAssertEqual(meeting.captureState, .stopped)
        XCTAssertEqual(meeting.chunks.count, 3)
        XCTAssertEqual(meeting.chunks.filter { $0.source == .microphone }.map(\.startUS).sorted(), [0, 2_000_000])
        XCTAssertEqual(meeting.chunks.filter { $0.source == .system }.count, 1)
        XCTAssertEqual(meeting.intervals.count, 2)
        let repeatedStop = try await engine.stop()
        XCTAssertEqual(repeatedStop, meeting)
        for chunk in meeting.chunks {
            let url = try store.meetingURL(id: meeting.id).appendingPathComponent(chunk.relativePath)
            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(file.length, 16_000)
            XCTAssertEqual(file.fileFormat.streamDescription.pointee.mBitsPerChannel, 16)
            let data = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1))
            try file.read(into: data, frameCount: 1)
            XCTAssertEqual(data.floatChannelData![0][0], 0.25)
        }
    }

    func testStreamFailureWhilePausedIsReportedOnce() async throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let failure = expectation(description: "Paused stream error")
        failure.assertForOverFulfill = true
        let engine = try CaptureEngine(store: store) { event in
            if case .failed = event { failure.fulfill() }
        }
        try await engine.pause()
        engine.streamFailed(CaptureFailure(message: "disconnected"))
        engine.streamFailed(CaptureFailure(message: "duplicate"))
        await fulfillment(of: [failure], timeout: 1)
        let meeting = try await engine.stop()
        XCTAssertEqual(meeting.captureState, .interrupted)
        XCTAssertTrue(meeting.captureError?.contains("disconnected") == true)
    }

    func testResumeCannotClaimRecordingAfterDisplaySourceWasLost() async throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock()
        let engine = try CaptureEngine(store: store, hostTime: clock.now) { _ in }
        clock.set(1_000_000)
        let pcm = try sample()
        engine.enqueue(pcm, source: .microphone, hostTimestamp: .zero)
        engine.enqueue(pcm, source: .system, hostTimestamp: .zero)
        try await engine.pause()
        engine.streamFailed(NSError(domain: SCStreamErrorDomain, code: -3815,
            userInfo: [NSLocalizedDescriptionKey: "Failed to find any displays or windows to capture"]))
        clock.set(2_000_000)
        do {
            try await engine.resume()
            XCTFail("A failed capture stream must not report a successful resume.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("display"))
        }
        let meeting = try await engine.stop()
        XCTAssertEqual(meeting.captureState, .interrupted)
        XCTAssertEqual(meeting.intervals.count, 1)
        XCTAssertEqual(meeting.intervals.first?.endUS, 1_000_000)
        XCTAssertEqual(meeting.chunks.count, 2)
        XCTAssertEqual(Set(meeting.chunks.map(\.source)), Set(AudioSource.allSources))
    }

    func testStoppedCaptureCannotBePausedOrResumedAgain() async throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock()
        let engine = try CaptureEngine(store: store, hostTime: clock.now) { _ in }
        clock.set(1_000_000)
        engine.enqueue(try sample(), source: .microphone, hostTimestamp: .zero)
        let stopped = try await engine.stop()
        let path = try store.artifactURL(meetingID: stopped.id, relativePath: "meeting.json")
        let bytes = try Data(contentsOf: path)
        for pausing in [true, false] {
            do {
                if pausing { try await engine.pause() } else { try await engine.resume() }
                XCTFail("A stopped stream must not be reopened by a stale transition.")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("finished"))
            }
        }
        engine.streamFailed(NSError(domain: SCStreamErrorDomain, code: -3815))
        clock.set(3_000_000)
        engine.enqueue(try sample(), source: .system, hostTimestamp: CMTime(value: 2, timescale: 1))
        let repeated = try await engine.stop()
        XCTAssertEqual(repeated, stopped)
        XCTAssertEqual(try Data(contentsOf: path), bytes)
    }

    func testDuplicateResumeCannotCreateOverlappingRecordingIntervals() async throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock()
        let engine = try CaptureEngine(store: store, hostTime: clock.now) { _ in }
        clock.set(1_000_000)
        try await engine.pause()
        clock.set(2_000_000)
        try await engine.resume()
        do {
            try await engine.resume()
            XCTFail("Resume must not append a second open interval.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("already recording"))
        }
        clock.set(3_000_000)
        let stopped = try await engine.stop()
        XCTAssertEqual(stopped.captureState, .stopped)
        XCTAssertEqual(stopped.intervals, [CaptureInterval(generation: 0, startUS: 0, endUS: 1_000_000),
                                           CaptureInterval(generation: 1, startUS: 2_000_000, endUS: 3_000_000)])
    }

    func testDisplayLossPreservesCommittedAudioAndNativeFailureIdentity() async throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock()
        let failed = expectation(description: "Display loss reported once")
        failed.assertForOverFulfill = true
        let engine = try CaptureEngine(store: store, hostTime: clock.now) { event in
            if case .failed = event { failed.fulfill() }
        }
        clock.set(1_000_000)
        let pcm = try sample()
        for source in AudioSource.allSources { engine.enqueue(pcm, source: source, hostTimestamp: .zero) }
        clock.set(1_500_000)
        engine.streamFailed(NSError(domain: SCStreamErrorDomain, code: -3815,
            userInfo: [NSLocalizedDescriptionKey: "Failed to find any displays or windows to capture"]))
        engine.streamFailed(NSError(domain: SCStreamErrorDomain, code: -3818))
        clock.set(3_000_000)
        for source in AudioSource.allSources {
            engine.enqueue(pcm, source: source, hostTimestamp: CMTime(value: 2, timescale: 1))
        }
        await fulfillment(of: [failed], timeout: 1)
        let stopped = try await engine.stop(reason: "Later cleanup reason")
        XCTAssertEqual(stopped.captureState, .interrupted)
        XCTAssertEqual(stopped.intervals, [CaptureInterval(generation: 0, startUS: 0, endUS: 1_500_000)])
        XCTAssertEqual(stopped.chunks.count, 2)
        XCTAssertTrue(stopped.chunks.allSatisfy { $0.frameCount == 16_000 && $0.startUS == 0 })
        let message = try XCTUnwrap(stopped.captureError)
        XCTAssertTrue(message.contains("Restore an available display"))
        XCTAssertTrue(message.contains("Saved audio is preserved"))
        XCTAssertTrue(message.contains("[\(SCStreamErrorDomain) -3815]"))
        XCTAssertFalse(message.contains("-3818"))
        for chunk in stopped.chunks {
            let file = try AVAudioFile(forReading: store.artifactURL(meetingID: stopped.id, relativePath: chunk.relativePath))
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000))
            XCTAssertEqual(file.length, 16_000)
            var frames: Int64 = 0
            while frames < file.length {
                try file.read(into: pcm)
                guard pcm.frameLength > 0 else { XCTFail("Saved PCM ended before its declared frame count."); break }
                let values = UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength))
                XCTAssertTrue(values.allSatisfy { $0 == 0.25 })
                frames += Int64(pcm.frameLength)
            }
            XCTAssertEqual(frames, 16_000)
        }
    }

    func testNativeCaptureDescriptionsKeepDomainAndDoNotInferDisplayLossFromOtherErrors() {
        for code in [-3813, -3814, -3815] {
            let message = CaptureFailure.describe(NSError(domain: SCStreamErrorDomain, code: code))
            XCTAssertTrue(message.contains("Restore an available display"))
            XCTAssertTrue(message.contains("[\(SCStreamErrorDomain) \(code)]"))
        }
        for code in [-3817, -3821] {
            let message = CaptureFailure.describe(NSError(domain: SCStreamErrorDomain, code: code))
            XCTAssertFalse(message.contains("Restore an available display"))
            XCTAssertTrue(message.contains("[\(SCStreamErrorDomain) \(code)]"))
        }
        XCTAssertTrue(CaptureFailure.describe(NSError(domain: SCStreamErrorDomain, code: -3820)).contains("microphone is unavailable"))
        XCTAssertTrue(CaptureFailure.describe(NSError(domain: SCStreamErrorDomain, code: -3818)).contains("System audio capture could not start"))
        let other = CaptureFailure.describe(NSError(domain: "OtherCaptureDomain", code: -3815))
        XCTAssertFalse(other.contains("Restore an available display"))
        XCTAssertTrue(other.contains("[OtherCaptureDomain -3815]"))
        XCTAssertEqual(CaptureFailure.describe(CaptureFailure(message: "Existing actionable failure")), "Existing actionable failure")
    }

    func testQueueOverflowInterruptsWithoutSavingOversizedBuffer() async throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let failure = expectation(description: "Bounded write queue")
        let clock = Clock()
        let engine = try CaptureEngine(store: store, hostTime: clock.now) { event in
            if case .failed(let message) = event {
                XCTAssertTrue(message.contains("two seconds"))
                failure.fulfill()
            }
        }
        clock.set(3_000_000)
        engine.enqueue(try sample(frames: 48_000), source: .microphone, hostTimestamp: .zero)
        await fulfillment(of: [failure], timeout: 1)
        let meeting = try await engine.stop(reason: "overflow")
        XCTAssertTrue(meeting.chunks.isEmpty)
    }

    func testStraddlingBuffersAreTrimmedAtPauseAndResume() async throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock()
        let engine = try CaptureEngine(store: store, hostTime: clock.now) { _ in }
        let pcm = try sample()
        clock.set(1_000_000)
        engine.enqueue(pcm, source: .microphone, hostTimestamp: CMTime(value: 1, timescale: 2))
        try await engine.pause()
        clock.set(2_000_000)
        try await engine.resume()
        clock.set(3_000_000)
        engine.enqueue(pcm, source: .microphone, hostTimestamp: CMTime(value: 3, timescale: 2))
        let meeting = try await engine.stop()
        XCTAssertEqual(meeting.chunks.map(\.startUS).sorted(), [500_000, 2_000_000])
        XCTAssertEqual(meeting.chunks.map(\.frameCount), [8_000, 8_000])
    }

    func testSystemAudioGapsRemainSeparateChunks() async throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock()
        let engine = try CaptureEngine(store: store, hostTime: clock.now) { _ in }
        let pcm = try sample()
        clock.set(1_000_000)
        engine.enqueue(pcm, source: .system, hostTimestamp: .zero)
        clock.set(4_000_000)
        engine.enqueue(pcm, source: .system, hostTimestamp: CMTime(value: 3, timescale: 1))
        let meeting = try await engine.stop()
        XCTAssertEqual(meeting.captureState, .stopped)
        XCTAssertEqual(meeting.chunks.map(\.startUS).sorted(), [0, 3_000_000])
        XCTAssertEqual(meeting.chunks.map(\.frameCount), [16_000, 16_000])
    }

    func testMicrophoneGapKeepsRecordingAndPreservesMissingTime() async throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock()
        let warning = expectation(description: "Microphone gap warning")
        let engine = try CaptureEngine(store: store, hostTime: clock.now) { event in
            if case .warning(let detail) = event {
                XCTAssertTrue(detail.contains("500 ms"))
                warning.fulfill()
            }
        }
        let pcm = try sample()
        clock.set(3_000_000)
        engine.enqueue(pcm, source: .microphone, hostTimestamp: .zero)
        engine.enqueue(pcm, source: .microphone, hostTimestamp: CMTime(value: 3, timescale: 2))
        let meeting = try await engine.stop()
        await fulfillment(of: [warning], timeout: 1)
        XCTAssertEqual(meeting.captureState, .stopped)
        XCTAssertEqual(meeting.chunks.map(\.startUS).sorted(), [0, 1_500_000])
        XCTAssertTrue(meeting.captureError?.contains("500 ms") == true)
        XCTAssertEqual(try store.load(id: meeting.id).captureError, meeting.captureError)
        let preparedPath = try AudioPreparation.prepare(meeting: meeting, rootURL: directory, runID: UUID().uuidString)
        let prepared = try JSONDecoder().decode(PreparedAudio.self,
            from: Data(contentsOf: store.artifactURL(meetingID: meeting.id, relativePath: preparedPath)))
        XCTAssertEqual(prepared.sources.first?.pieces.map(\.meeting_start_us), [0, 1_500_000])
    }

    func testMicrophoneTimestampOverlapStillInterruptsCapture() async throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock()
        let engine = try CaptureEngine(store: store, hostTime: clock.now) { _ in }
        let pcm = try sample()
        clock.set(2_000_000)
        engine.enqueue(pcm, source: .microphone, hostTimestamp: .zero)
        engine.enqueue(pcm, source: .microphone, hostTimestamp: CMTime(value: 1, timescale: 2))
        let meeting = try await engine.stop()
        XCTAssertEqual(meeting.captureState, .interrupted)
        XCTAssertEqual(meeting.chunks.count, 1)
        XCTAssertTrue(meeting.captureError?.contains("moved backwards by 500000 microseconds") == true)
    }

    func testSmallTimestampOverlapDoesNotInvalidateNextChunk() async throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock()
        let engine = try CaptureEngine(store: store, hostTime: clock.now) { _ in }
        let pcm = try sample()
        for second in 0..<5 {
            clock.set(Int64(second + 1) * 1_000_000)
            engine.enqueue(pcm, source: .system, hostTimestamp: CMTime(value: Int64(second), timescale: 1))
            try await engine.rename(to: "Test")
        }
        clock.set(7_000_000)
        engine.enqueue(pcm, source: .system, hostTimestamp: CMTime(value: 4_999_950, timescale: 1_000_000))
        let meeting = try await engine.stop()
        XCTAssertEqual(meeting.captureState, .stopped)
        let chunks = meeting.chunks.sorted { $0.startUS < $1.startUS }
        XCTAssertEqual(chunks.count, 2)
        XCTAssertGreaterThanOrEqual(chunks[1].startUS, chunks[0].endUS - 2)
        XCTAssertEqual(chunks.map(\.frameCount), [80_000, 15_999])
    }

    func testCaptureSessionPersistsSelectedLanguageWithoutStartingHardware() async throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try CaptureEngine(store: store, asrLanguage: "zh") { _ in }
        XCTAssertEqual(try store.load(id: engine.meetingID).asrLanguage, "zh")
        let stopped = try await engine.stop()
        XCTAssertEqual(stopped.asrLanguage, "zh")
    }

    func testCaptureSessionPreservesSelectedCalendarTitleWithoutStartingHardware() async throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try CaptureEngine(store: store, title: "需求讨论") { _ in }
        XCTAssertEqual(try store.load(id: engine.meetingID).title, "需求讨论")
        let stopped = try await engine.stop()
        XCTAssertEqual(stopped.title, "需求讨论")
    }

    func testRenameSurvivesQueuedAudioPauseResumeAndFinalization() async throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock()
        let engine = try CaptureEngine(store: store, hostTime: clock.now) { _ in }
        let pcm = try sample()
        clock.set(1_000_000)
        engine.enqueue(pcm, source: .microphone, hostTimestamp: .zero)
        try await engine.rename(to: "  需求讨论  ")
        try await engine.pause()
        XCTAssertEqual(try store.load(id: engine.meetingID).title, "需求讨论")
        clock.set(2_000_000)
        try await engine.resume()
        clock.set(3_000_000)
        engine.enqueue(pcm, source: .microphone, hostTimestamp: CMTime(value: 2, timescale: 1))
        let stopped = try await engine.stop()
        XCTAssertEqual(stopped.title, "需求讨论")
        XCTAssertEqual(stopped.chunks.count, 2)
        XCTAssertEqual(try MeetingStore(rootURL: directory).load(id: stopped.id).title, "需求讨论")
    }
}
