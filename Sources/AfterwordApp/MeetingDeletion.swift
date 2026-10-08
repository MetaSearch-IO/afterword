import AfterwordCore
import Darwin
import Foundation

enum MeetingDeletion {
    static func isActive(_ meeting: Meeting) -> Bool {
        meeting.captureState.isActive || ["running", "processing", "cancelling", "queued", "paused"].contains(meeting.processingStatus)
    }

    static func remove(id: String, rootURL: URL) throws {
        let store = MeetingStore(rootURL: rootURL)
        let directory = try store.meetingURL(id: id)
        var descriptors: [Int32] = []
        defer { descriptors.forEach { close($0) } }
        for name in [".processing.lock", ".calendar-event.lock"] {
            let url = try store.artifactURL(meetingID: id, relativePath: name)
            let descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw CaptureFailure(message: "The meeting could not be locked for deletion.") }
            descriptors.append(descriptor)
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw CaptureFailure(message: "This meeting is in use. Finish or cancel its processing, then try deleting it again.")
            }
        }
        let current = try store.load(id: id)
        guard !isActive(current) else {
            throw CaptureFailure(message: "Finish recording or cancel this meeting's processing before deleting it.")
        }
        let retained = Set(["meeting.json", ".processing.lock", ".calendar-event.lock"])
        // Keep the manifest until the content is gone so a failed deletion can be retried from the list.
        for item in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where !retained.contains(item.lastPathComponent) {
            try FileManager.default.removeItem(at: item)
        }
        try FileManager.default.removeItem(at: directory)
    }
}
