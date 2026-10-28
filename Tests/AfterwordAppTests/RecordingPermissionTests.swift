import AfterwordCore
import Foundation
import ScreenCaptureKit
import XCTest
@testable import AfterwordApp

final class RecordingPermissionTests: XCTestCase {
    @MainActor
    func testOnlySelectedMicrophoneDisconnectInterruptsRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("afterword-device-disconnect-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = MeetingController(rootURL: root)
        let deadline = Date().addingTimeInterval(3)
        while controller.isLoading && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(controller.isLoading)
        controller.activity = .recording
        controller.activeMicrophoneID = "selected-microphone"
        controller.audioDeviceDisconnected(id: "other-audio-device")
        XCTAssertEqual(controller.activity, .recording)
        controller.audioDeviceDisconnected(id: "selected-microphone")
        XCTAssertEqual(controller.activity, .finalizing)
    }

    func testSystemPermissionDenialExplainsEnabledButStaleGrantWithoutRawTCCError() {
        let error = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue,
                            userInfo: [NSLocalizedDescriptionKey: "The user declined TCCs for application, window, display capture"])
        let text = CaptureFailure.describe(error)
        XCTAssertTrue(text.contains("already enabled"))
        XCTAssertTrue(text.contains("quit it before"))
        XCTAssertFalse(text.contains("TCCs"))
        XCTAssertFalse(text.contains("Restore an available display"))
        XCTAssertEqual(RecordingPermissionIssue.identify(error), .screenAndSystemAudio)
        XCTAssertNil(RecordingPermissionIssue.identify(NSError(domain: "unrelated", code: -3801)))
    }

    @MainActor
    func testDeniedMicrophoneCreatesNoMeetingAndSettingsWaitForSuccessfulQuit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("afterword-permission-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var quitRequests = 0
        var opened: [URL] = []
        let controller = MeetingController(rootURL: root, requestMicrophoneAccess: { false },
            requestAppQuit: { quitRequests += 1 }, openPrivacySettings: { opened.append($0) })
        let deadline = Date().addingTimeInterval(3)
        while controller.isLoading && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(controller.canRecord)
        controller.record()
        while controller.activity != .idle && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.permissionIssue, .microphone)
        XCTAssertTrue(try controller.store.list().isEmpty)
        XCTAssertTrue(controller.canRecord)
        controller.openPermissionSettingsAfterQuit()
        XCTAssertEqual(quitRequests, 1)
        XCTAssertTrue(opened.isEmpty)
        controller.finishPermissionSettingsQuit(ready: false)
        controller.finishPermissionSettingsQuit(ready: true)
        XCTAssertTrue(opened.isEmpty)
        controller.openPermissionSettingsAfterQuit()
        let ready = await controller.prepareToQuit()
        XCTAssertTrue(ready)
        controller.finishPermissionSettingsQuit(ready: true)
        XCTAssertEqual(opened, [RecordingPermissionIssue.microphone.settingsURL])
        controller.finishPermissionSettingsQuit(ready: true)
        XCTAssertEqual(opened.count, 1)
    }
}
