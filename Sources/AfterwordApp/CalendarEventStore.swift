import AfterwordCore
import Darwin
import Foundation

struct CalendarEventStore {
    static let maximumBytes = 512 * 1_024
    private let store: MeetingStore

    init(store: MeetingStore) { self.store = store }

    func read(meetingID: String) throws -> CalendarEventSnapshot? {
        _ = try store.load(id: meetingID)
        let url = try store.artifactURL(meetingID: meetingID, relativePath: "calendar-event.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= Self.maximumBytes else { throw CalendarDataError(message: "Saved calendar context exceeds its size limit.") }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= Self.maximumBytes else { throw CalendarDataError(message: "Saved calendar context exceeds its size limit.") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let snapshot = try decoder.decode(CalendarEventSnapshot.self, from: bytes)
        try snapshot.validate(meetingID: meetingID)
        return snapshot
    }

    func save(_ snapshot: CalendarEventSnapshot) throws {
        try snapshot.validate(meetingID: snapshot.meetingID)
        try withLock(meetingID: snapshot.meetingID) {
            _ = try store.load(id: snapshot.meetingID)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let bytes = try encoder.encode(snapshot)
            guard bytes.count <= Self.maximumBytes else { throw CalendarDataError(message: "Calendar context exceeds its size limit.") }
            let destination = try store.artifactURL(meetingID: snapshot.meetingID, relativePath: "calendar-event.json")
            let temporary = try store.artifactURL(meetingID: snapshot.meetingID,
                relativePath: ".calendar-event-\(UUID().uuidString.lowercased()).partial")
            let descriptor = open(temporary.path, O_CREAT | O_WRONLY | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw CalendarDataError(message: "Unable to stage the calendar context.") }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer {
                try? handle.close()
                try? FileManager.default.removeItem(at: temporary)
            }
            try handle.write(contentsOf: bytes)
            try handle.synchronize()
            try handle.close()
            guard Darwin.rename(temporary.path, destination.path) == 0 else {
                throw CalendarDataError(message: "Unable to replace the saved calendar context.")
            }
        }
    }

    func unlink(meetingID: String) throws {
        try withLock(meetingID: meetingID) {
            _ = try store.load(id: meetingID)
            let url = try store.artifactURL(meetingID: meetingID, relativePath: "calendar-event.json")
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    private func withLock<T>(meetingID: String, _ body: () throws -> T) throws -> T {
        let url = try store.artifactURL(meetingID: meetingID, relativePath: ".calendar-event.lock")
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CalendarDataError(message: "Unable to lock the calendar context.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw CalendarDataError(message: "Calendar context is being changed. Try again.")
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
