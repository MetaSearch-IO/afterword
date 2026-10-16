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
        try withExclusiveLocks(id: id, store: store) { _ in
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

    static func removeAudio(id: String, rootURL: URL) throws {
        let store = MeetingStore(rootURL: rootURL)
        try withExclusiveLocks(id: id, store: store) { directoryFD in
            var meeting = try store.load(id: id)
            guard !isActive(meeting) else {
                throw CaptureFailure(message: "Finish recording or cancel this meeting's processing before deleting its audio.")
            }
            if meeting.audioRemovalStartedAt == nil && meeting.audioRemovedAt == nil {
                if let revision = meeting.activeRevisionID {
                    _ = try ReviewExport.snapshot(store: store, meetingID: id, expectedRevisionID: revision,
                                                  expectedSummaryID: meeting.activeSummaryID)
                } else if meeting.activeSummaryID != nil {
                    throw CaptureFailure(message: "The saved notes have no transcript. Audio was left unchanged.")
                }
                meeting.audioRemovalStartedAt = ISO8601DateFormatter().string(from: Date())
                try store.save(meeting)
            }

            if let audioFD = try openDirectory("audio", at: directoryFD) {
                defer { close(audioFD) }
                try removeTreeContents(in: audioFD)
                guard unlinkat(directoryFD, "audio", AT_REMOVEDIR) == 0 else { throw posixError() }
            }
            if let workFD = try openDirectory("work", at: directoryFD) {
                defer { close(workFD) }
                try removeWAVs(in: workFD)
            }
            guard try entryMode("audio", at: directoryFD) == nil,
                  try !workContainsWAV(in: directoryFD) else {
                throw CaptureFailure(message: "Some saved audio could not be removed. Try again.")
            }

            meeting.audioRemovedAt = meeting.audioRemovedAt ?? ISO8601DateFormatter().string(from: Date())
            meeting.audioRemovalStartedAt = nil
            try store.save(meeting)
        }
    }

    private static func withExclusiveLocks(id: String, store: MeetingStore, body: (Int32) throws -> Void) throws {
        let directory = try store.meetingURL(id: id)
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw CaptureFailure(message: "The meeting directory could not be opened safely.") }
        defer { close(directoryFD) }
        var descriptors: [Int32] = []
        defer { descriptors.forEach { close($0) } }
        for name in [".processing.lock", ".calendar-event.lock"] {
            let descriptor = openat(directoryFD, name, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw CaptureFailure(message: "The meeting could not be locked for deletion.") }
            descriptors.append(descriptor)
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw CaptureFailure(message: "This meeting is in use. Finish or cancel its processing, then try deleting it again.")
            }
        }
        try body(directoryFD)
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    private static func entryMode(_ name: String, at directoryFD: Int32) throws -> mode_t? {
        var info = stat()
        if fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return info.st_mode }
        if errno == ENOENT { return nil }
        throw posixError()
    }

    private static func openDirectory(_ name: String, at directoryFD: Int32) throws -> Int32? {
        let descriptor = openat(directoryFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor >= 0 { return descriptor }
        if errno == ENOENT { return nil }
        throw posixError()
    }

    private static func entries(in directoryFD: Int32) throws -> [String] {
        let iteratorFD = openat(directoryFD, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard iteratorFD >= 0 else { throw posixError() }
        guard let stream = fdopendir(iteratorFD) else {
            let error = posixError()
            close(iteratorFD)
            throw error
        }
        defer { closedir(stream) }
        var names: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let raw = withUnsafeBytes(of: entry.pointee.d_name) { Array($0.prefix(Int(entry.pointee.d_namlen))) }
            guard let name = String(bytes: raw, encoding: .utf8) else {
                throw CaptureFailure(message: "An audio filename could not be read safely.")
            }
            if name != "." && name != ".." { names.append(name) }
        }
        if errno != 0 { throw posixError() }
        return names
    }

    private static func removeTreeContents(in directoryFD: Int32) throws {
        for name in try entries(in: directoryFD) {
            guard let mode = try entryMode(name, at: directoryFD) else { continue }
            if mode & S_IFMT == S_IFDIR {
                guard let childFD = try openDirectory(name, at: directoryFD) else { continue }
                defer { close(childFD) }
                try removeTreeContents(in: childFD)
                guard unlinkat(directoryFD, name, AT_REMOVEDIR) == 0 else { throw posixError() }
            } else if unlinkat(directoryFD, name, 0) != 0 {
                throw posixError()
            }
        }
    }

    private static func removeWAVs(in directoryFD: Int32) throws {
        for name in try entries(in: directoryFD) {
            guard let mode = try entryMode(name, at: directoryFD) else { continue }
            if mode & S_IFMT == S_IFDIR {
                guard let childFD = try openDirectory(name, at: directoryFD) else { continue }
                defer { close(childFD) }
                try removeWAVs(in: childFD)
            } else if name.lowercased().hasSuffix(".wav") && unlinkat(directoryFD, name, 0) != 0 {
                throw posixError()
            }
        }
    }

    private static func workContainsWAV(in directoryFD: Int32) throws -> Bool {
        guard let workFD = try openDirectory("work", at: directoryFD) else { return false }
        defer { close(workFD) }
        return try containsWAV(in: workFD)
    }

    private static func containsWAV(in directoryFD: Int32) throws -> Bool {
        for name in try entries(in: directoryFD) {
            guard let mode = try entryMode(name, at: directoryFD) else { continue }
            if mode & S_IFMT == S_IFDIR {
                guard let childFD = try openDirectory(name, at: directoryFD) else { continue }
                defer { close(childFD) }
                if try containsWAV(in: childFD) { return true }
            } else if name.lowercased().hasSuffix(".wav") {
                return true
            }
        }
        return false
    }
}
