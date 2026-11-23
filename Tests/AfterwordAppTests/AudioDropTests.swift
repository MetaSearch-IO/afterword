import AVFoundation
import AfterwordCore
import Foundation
import XCTest
@testable import AfterwordApp

final class AudioDropTests: XCTestCase {
    @MainActor
    func testDropImportsVisibleMeetingWithoutLocalProcessing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("afterword-drop-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("from-finder.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        buffer.floatChannelData![0].initialize(repeating: 0.25, count: 4_800)
        do {
            let file = try AVAudioFile(forWriting: input, settings: format.settings)
            try file.write(from: buffer)
        }
        let controller = MeetingController(rootURL: directory.appendingPathComponent("meetings"),
                                           shouldProcessImportedAudio: { false })
        let deadline = Date().addingTimeInterval(10)
        while controller.isLoading && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(controller.isLoading)
        XCTAssertTrue(controller.importAudioFiles([input]))
        XCTAssertFalse(controller.canRecord)
        while controller.isImportingAudio && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(controller.isImportingAudio)
        let meeting = try XCTUnwrap(controller.meetings.first)
        XCTAssertEqual(meeting.title, "from-finder")
        XCTAssertEqual(controller.selectedID, meeting.id)
        XCTAssertEqual(try controller.store.load(id: meeting.id).processingStatus, "idle")
        XCTAssertFalse(controller.processing.isBusy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: input.path))

        controller.activity = .recording
        XCTAssertFalse(controller.importAudioFiles([input]))
        controller.activity = .idle
        let unsupported = directory.appendingPathComponent("not-audio.txt")
        XCTAssertFalse(controller.importAudioFiles([unsupported]))
        XCTAssertEqual(controller.meetings.count, 1)
    }
}
