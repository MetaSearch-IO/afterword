import AVFoundation
import AfterwordCore
import CoreMedia
import ScreenCaptureKit

struct CaptureFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    static func describe(_ error: Error) -> String {
        if let issue = RecordingPermissionIssue.identify(error) { return issue.localizedDescription }
        if let failure = error as? CaptureFailure { return failure.message }
        let native = error as NSError
        let details = "\(native.localizedDescription) [\(native.domain) \(native.code)]"
        guard native.domain == SCStreamErrorDomain else { return details }
        switch SCStreamError.Code(rawValue: native.code) {
        case .noCaptureSource, .noDisplayList, .noWindowList:
            return "The display source for system audio is unavailable. Restore an available display before recording again. \(details)"
        case .failedToStartMicrophoneCapture:
            return "The microphone is unavailable. Check its connection and microphone permission before recording again. \(details)"
        case .failedToStartAudioCapture:
            return "System audio capture could not start. Check screen/system-audio permission before recording again. \(details)"
        default:
            return details
        }
    }
}

final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case level(AudioSource, Float)
        case warning(String)
        case failed(String)
    }

    private final class Writer {
        let id: String
        let source: AudioSource
        let generation: Int
        let startUS: Int64
        let format: AVAudioFormat
        var file: AVAudioFile?
        var frames: Int64 = 0

        init(id: String, source: AudioSource, generation: Int, startUS: Int64,
             format: AVAudioFormat, file: AVAudioFile) {
            self.id = id
            self.source = source
            self.generation = generation
            self.startUS = startUS
            self.format = format
            self.file = file
        }
    }

    private final class Packet: @unchecked Sendable {
        let sample: CMSampleBuffer
        let source: AudioSource
        let startUS: Int64
        let generation: Int
        let duration: Double
        let receivedUS: Int64
        init(sample: CMSampleBuffer, source: AudioSource, startUS: Int64,
             generation: Int, duration: Double, receivedUS: Int64) {
            self.sample = sample
            self.source = source
            self.startUS = startUS
            self.generation = generation
            self.duration = duration
            self.receivedUS = receivedUS
        }
    }

    private let queue = DispatchQueue(label: "local.afterword.audio-writer", qos: .userInitiated)
    private let callbacks = DispatchQueue(label: "local.afterword.audio-callback", qos: .userInteractive)
    private let lock = NSLock()
    private let store: MeetingStore
    private var meeting: Meeting
    private var writers: [AudioSource: Writer] = [:]
    private var formats: [AudioSource: AVAudioFormat] = [:]
    private var lastEnd: [AudioSource: Int64] = [:]
    private var microphoneGapCount = 0
    private var largestMicrophoneGapUS: Int64 = 0
    private var intervals: [CaptureInterval] = []
    private var pending: [AudioSource: Double] = [:]
    private var accepting = true
    private var failureSent = false
    private var failureReason: String?
    private var finalized = false
    private var stopping = false
    private var stream: SCStream?
    private let origin: CMTime
    private let hostTime: @Sendable () -> CMTime
    private let event: @Sendable (Event) -> Void
    let meetingID: String

    init(store: MeetingStore, asrLanguage: String = "auto", title: String = "Meeting",
         hostTime: @escaping @Sendable () -> CMTime = { CMClockGetTime(CMClockGetHostTimeClock()) },
         event: @escaping @Sendable (Event) -> Void) throws {
        self.store = store
        self.event = event
        self.hostTime = hostTime
        origin = hostTime()
        meeting = try store.create(title: title)
        meeting.asrLanguage = asrLanguage
        meetingID = meeting.id
        super.init()
        intervals = [CaptureInterval(generation: 0, startUS: 0, endUS: nil)]
        meeting.intervals = intervals
        try store.save(meeting)
    }

    func start(display: SCDisplay, microphoneID: String) async throws {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = true
        config.microphoneCaptureDeviceID = microphoneID
        config.sampleRate = 16_000
        config.channelCount = 1
        let capture = SCStream(filter: filter, configuration: config, delegate: self)
        try lock.withLock {
            try requireActiveLocked()
            guard stream == nil else { throw CaptureFailure(message: "Capture has already started.") }
            stream = capture
        }
        try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: callbacks)
        try capture.addStreamOutput(self, type: .microphone, sampleHandlerQueue: callbacks)
        try await capture.startCapture()
        try await perform {
            try self.lock.withLock {
                try self.requireActiveLocked()
                self.meeting.captureState = .recording
            }
            try self.store.save(self.meeting)
        }
    }

    func pause() async throws {
        closeInterval()
        try await perform {
            try self.lock.withLock {
                try self.requireActiveLocked()
                self.meeting.intervals = self.intervals
                self.meeting.captureState = .paused
            }
            try self.store.save(self.meeting)
            try self.finishWriters()
        }
    }

    func rename(to title: String) async throws {
        try await perform {
            guard !self.finalized else { throw CaptureFailure(message: "Recording finished. Save the meeting name again.") }
            self.meeting = try self.store.rename(id: self.meeting.id, title: title)
        }
    }

    func resume() async throws {
        try await perform {
            try self.lock.withLock {
                try self.requireActiveLocked()
                guard self.intervals.last?.endUS != nil else {
                    throw CaptureFailure(message: "Capture is already recording.")
                }
                let next = (self.intervals.last?.generation ?? -1) + 1
                self.intervals.append(CaptureInterval(generation: next, startUS: self.nowUS(), endUS: nil))
                self.accepting = true
                self.meeting.intervals = self.intervals
                self.meeting.captureState = .recording
            }
            self.lastEnd = [:]
            try self.store.save(self.meeting)
        }
    }

    func stop(reason: String? = nil) async throws -> Meeting {
        lock.withLock { stopping = true }
        closeInterval()
        var stopError: String?
        if let stream {
            do { try await stream.stopCapture() }
            catch { stopError = error.localizedDescription }
            self.stream = nil
        }
        let externalReason = reason ?? stopError
        return try await perform {
            if self.finalized { return self.meeting }
            self.finalized = true
            self.meeting.intervals = self.snapshotIntervals()
            self.meeting.captureState = .finalizing
            try self.store.save(self.meeting)
            do { try self.finishWriters() }
            catch {
                self.meeting.captureState = .interrupted
                self.meeting.captureError = error.localizedDescription
                try? self.store.save(self.meeting)
                throw error
            }
            let finalReason = self.lock.withLock { self.failureReason } ?? externalReason
            self.meeting.captureState = finalReason == nil ? .stopped : .interrupted
            let gapLabel = self.microphoneGapCount == 1 ? "gap" : "gaps"
            let gapWarning = self.microphoneGapCount == 0 ? nil
                : "Microphone audio was missing in \(self.microphoneGapCount) \(gapLabel), largest \(self.largestMicrophoneGapUS / 1_000) ms. Recording continued; speech during missing audio was not captured."
            self.meeting.captureError = finalReason ?? gapWarning
            self.meeting.processingStatus = "idle"
            try self.store.save(self.meeting)
            return self.meeting
        }
    }

    func elapsedUS() -> Int64 { nowUS() }

    func retainedUS() -> Int64 {
        let now = nowUS()
        return lock.withLock { intervals.reduce(0) { $0 + (($1.endUS ?? now) - $1.startUS) } }
    }

    private func nowUS() -> Int64 {
        CMTimeConvertScale(CMTimeSubtract(hostTime(), origin),
                           timescale: 1_000_000, method: .roundTowardZero).value
    }

    private func closeInterval() {
        lock.withLock {
            accepting = false
            if let last = intervals.indices.last, intervals[last].endUS == nil {
                intervals[last].endUS = nowUS()
            }
        }
    }

    private func snapshotIntervals() -> [CaptureInterval] { lock.withLock { intervals } }

    private func requireActiveLocked() throws {
        if let failureReason { throw CaptureFailure(message: failureReason) }
        guard !stopping else {
            throw CaptureFailure(message: "Recording has finished. Start a new recording to capture more audio.")
        }
    }

    private func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        let source: AudioSource
        switch type {
        case .audio: source = .system
        case .microphone: source = .microphone
        default: return
        }
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer),
              let description = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              asbd.pointee.mSampleRate > 0 else { fail("Capture delivered invalid audio data.", fromStream: true); return }
        guard let clock = stream.synchronizationClock else {
            fail("Capture did not provide a synchronization clock.", fromStream: true); return
        }
        let timestamp = CMSyncConvertTime(sampleBuffer.presentationTimeStamp, from: clock,
                                          to: CMClockGetHostTimeClock())
        guard timestamp.isNumeric else { fail("Capture delivered an invalid audio timestamp.", fromStream: true); return }
        enqueue(sampleBuffer, source: source, hostTimestamp: timestamp)
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer, source: AudioSource, hostTimestamp: CMTime) {
        guard let description = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              asbd.pointee.mSampleRate > 0 else { fail("Capture delivered invalid PCM audio.", fromStream: true); return }
        let startUS = CMTimeConvertScale(CMTimeSubtract(hostTimestamp, origin), timescale: 1_000_000,
                                        method: .roundTowardZero).value
        let duration = Double(sampleBuffer.numSamples) / asbd.pointee.mSampleRate
        lock.lock()
        guard accepting, let interval = intervals.last, !failureSent else { lock.unlock(); return }
        guard startUS + Int64(duration * 1_000_000) > interval.startUS else { lock.unlock(); return }
        guard (pending[source] ?? 0) + duration <= 10 else {
            lock.unlock(); fail("Audio writing fell more than ten seconds behind on the \(source.rawValue) track. Recording was interrupted."); return
        }
        pending[source, default: 0] += duration
        let packet = Packet(sample: sampleBuffer, source: source, startUS: startUS,
                            generation: interval.generation, duration: duration, receivedUS: nowUS())
        queue.async {
            defer { self.lock.withLock { self.pending[source, default: 0] -= duration } }
            do { try self.write(packet) }
            catch { self.fail(error.localizedDescription) }
        }
        lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        streamFailed(error)
    }

    func streamFailed(_ error: Error) {
        fail("Capture stopped: \(CaptureFailure.describe(error)) Saved audio is preserved.", fromStream: true)
    }

    private func fail(_ message: String, fromStream: Bool = false) {
        let notify = lock.withLock {
            guard !failureSent, !fromStream || !stopping else { return false }
            failureSent = true
            failureReason = message
            accepting = false
            if let last = intervals.indices.last, intervals[last].endUS == nil { intervals[last].endUS = nowUS() }
            return true
        }
        if notify { event(.failed(message)) }
    }

    private func write(_ packet: Packet) throws {
        guard !finalized, let description = packet.sample.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        if let previous = formats[packet.source], previous != format {
            throw CaptureFailure(message: "The \(packet.source.rawValue) audio format changed. Recording was interrupted.")
        }
        formats[packet.source] = format
        var allowed = snapshotIntervals()
        for index in allowed.indices where allowed[index].generation == packet.generation {
            allowed[index].endUS = min(allowed[index].endUS ?? packet.receivedUS, packet.receivedUS)
        }
        let timeline = CaptureTimeline(intervals: allowed)
        for slice in timeline.intersections(bufferStartUS: packet.startUS, frameCount: packet.sample.numSamples,
                                            sampleRate: format.sampleRate, generation: packet.generation) {
            var offset = slice.offset
            var remaining = slice.count
            var sliceStartUS = slice.startUS
            if let last = lastEnd[packet.source] {
                let gap = sliceStartUS - last
                guard gap >= -100 else {
                    throw CaptureFailure(message: "The \(packet.source.rawValue) audio timeline moved backwards by \(-gap) microseconds. Recording stopped to avoid overlapping saved audio.")
                }
                if gap < -2 {
                    let skipped = Int(ceil(Double(-gap) * format.sampleRate / 1_000_000))
                    guard skipped < remaining else { continue }
                    offset += skipped
                    remaining -= skipped
                    sliceStartUS += Int64((Double(skipped) * 1_000_000 / format.sampleRate).rounded())
                }
                if packet.source == .microphone, gap > 250_000 {
                    microphoneGapCount += 1
                    largestMicrophoneGapUS = max(largestMicrophoneGapUS, gap)
                    if microphoneGapCount == 1 {
                        event(.warning("Microphone audio was missing for \(gap / 1_000) ms. Recording continues, but speech in that gap was not captured."))
                    }
                }
                if abs(sliceStartUS - last) > Int64(2_000_000 / format.sampleRate) { try finishWriter(packet.source) }
            }
            let firstOffset = offset
            let acceptedCount = remaining
            while remaining > 0 {
                let startUS = sliceStartUS + Int64(Double(offset - firstOffset) * 1_000_000 / format.sampleRate)
                if writers[packet.source] == nil {
                    let id = UUID().uuidString.lowercased()
                    let directory = try store.beginChunk(meetingID: meeting.id, chunkID: id)
                    var settings = format.settings
                    settings[AVLinearPCMBitDepthKey] = 16
                    settings[AVLinearPCMIsFloatKey] = false
                    settings[AVLinearPCMIsNonInterleaved] = false
                    let file = try AVAudioFile(forWriting: directory.appendingPathComponent("audio.caf"),
                                              settings: settings, commonFormat: format.commonFormat,
                                              interleaved: format.isInterleaved)
                    writers[packet.source] = Writer(id: id, source: packet.source, generation: packet.generation,
                                                    startUS: startUS, format: format, file: file)
                }
                guard let writer = writers[packet.source] else { return }
                let count = min(remaining, Int(format.sampleRate * 5) - Int(writer.frames))
                guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
                    throw CaptureFailure(message: "Unable to allocate the audio write buffer.")
                }
                pcm.frameLength = AVAudioFrameCount(count)
                let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(packet.sample, at: Int32(offset),
                                                                          frameCount: Int32(count), into: pcm.mutableAudioBufferList)
                guard status == noErr else { throw CaptureFailure(message: "Unable to copy captured PCM audio (\(status)).") }
                try writer.file?.write(from: pcm)
                writer.frames += Int64(count)
                offset += count
                remaining -= count
                event(.level(packet.source, Self.level(pcm)))
                if writer.frames >= Int64(format.sampleRate * 5) { try finishWriter(packet.source) }
            }
            lastEnd[packet.source] = sliceStartUS + Int64(Double(acceptedCount) * 1_000_000 / format.sampleRate)
        }
    }

    private static func level(_ pcm: AVAudioPCMBuffer) -> Float {
        guard let channels = pcm.floatChannelData, pcm.frameLength > 0 else { return 0 }
        var peak: Float = 0
        for channel in 0..<Int(pcm.format.channelCount) {
            for frame in stride(from: 0, to: Int(pcm.frameLength), by: 16) {
                peak = max(peak, abs(channels[pcm.format.isInterleaved ? 0 : channel][frame * pcm.stride + (pcm.format.isInterleaved ? channel : 0)]))
            }
        }
        return min(1, peak)
    }

    private func finishWriters() throws {
        for source in [AudioSource.microphone, .system] { try finishWriter(source) }
    }

    private func finishWriter(_ source: AudioSource) throws {
        guard let writer = writers[source] else { return }
        writer.file = nil
        let descriptor = ChunkDescriptor(id: writer.id, source: source, generation: writer.generation,
                                         startUS: writer.startUS, frameCount: writer.frames,
                                         sampleRate: writer.format.sampleRate, channelCount: Int(writer.format.channelCount),
                                         format: "pcm", relativePath: "audio/\(writer.id)/audio.caf")
        meeting = try store.commitChunk(meetingID: meeting.id, descriptor: descriptor)
        writers.removeValue(forKey: source)
    }
}
