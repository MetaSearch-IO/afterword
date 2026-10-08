import Foundation
import ScreenCaptureKit

enum RecordingPermissionIssue: Error, LocalizedError, Equatable {
    case microphone, screenAndSystemAudio

    var errorDescription: String? {
        switch self {
        case .microphone:
            "Microphone access is required. Quit Afterword, enable it in System Settings → Privacy & Security → Microphone, then reopen it."
        case .screenAndSystemAudio:
            "Screen & System Audio Recording access is required for system audio. If Afterword is already enabled, quit it before turning access off and on. If access still fails, remove the old entry and add this copy again, then reopen Afterword. macOS may close a running app when this permission changes."
        }
    }

    var settingsURL: URL {
        let pane = self == .microphone ? "Privacy_Microphone" : "Privacy_ScreenCapture"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }

    static func identify(_ error: Error) -> Self? {
        if let issue = error as? Self { return issue }
        let native = error as NSError
        return native.domain == SCStreamErrorDomain && native.code == SCStreamError.Code.userDeclined.rawValue
            ? .screenAndSystemAudio : nil
    }
}
