import AfterwordCore
import Darwin
import Foundation

enum StorageReport {
    struct MeetingUsage: Encodable {
        let id: String
        let title: String
        let startedAt: String
        let captureState: String
        let processingStatus: String
        let hasTranscript: Bool
        let hasNotes: Bool
        let audioRemovalStarted: Bool
        let audioRemoved: Bool
        let audioAllocatedBytes: Int64
        let workWAVAllocatedBytes: Int64
        let deleteAudioReclaimableBytes: Int64
        let workWAVReclaimableBytes: Int64
    }

    private struct Inode: Hashable {
        let device: dev_t
        let number: ino_t
    }

    private struct FileBlocks {
        let bytes: Int64
        let linksOnDisk: UInt64
        var linksHere: UInt64
    }

    static func collect(store: MeetingStore) throws -> [MeetingUsage] {
        let meetings = try store.list()
        if FileManager.default.fileExists(atPath: store.rootURL.path) {
            let directories = try FileManager.default.contentsOfDirectory(at: store.rootURL,
                includingPropertiesForKeys: [.isDirectoryKey]).filter {
                    try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                }
            guard Set(directories.map(\.lastPathComponent)) == Set(meetings.map(\.id)) else {
                throw StoreError.invalid("Some meeting metadata could not be read; the storage inventory is incomplete.")
            }
        }
        return try meetings.map { meeting in
            var audio: [Inode: FileBlocks] = [:]
            var workWAVs: [Inode: FileBlocks] = [:]
            try scan(store.artifactURL(meetingID: meeting.id, relativePath: "audio"),
                     include: { _ in true }, into: &audio)
            try scan(store.artifactURL(meetingID: meeting.id, relativePath: "work"),
                     include: { $0.pathExtension.lowercased() == "wav" }, into: &workWAVs)
            var removedTogether = audio
            for (inode, file) in workWAVs {
                if var existing = removedTogether[inode] {
                    existing.linksHere += file.linksHere
                    removedTogether[inode] = existing
                } else {
                    removedTogether[inode] = file
                }
            }
            return MeetingUsage(id: meeting.id, title: meeting.title, startedAt: meeting.startedAt,
                captureState: meeting.captureState.rawValue, processingStatus: meeting.processingStatus,
                hasTranscript: meeting.activeRevisionID != nil, hasNotes: meeting.activeSummaryID != nil,
                audioRemovalStarted: meeting.audioRemovalStartedAt != nil,
                audioRemoved: meeting.audioRemovedAt != nil,
                audioAllocatedBytes: allocated(audio), workWAVAllocatedBytes: allocated(workWAVs),
                deleteAudioReclaimableBytes: reclaimable(removedTogether),
                workWAVReclaimableBytes: reclaimable(workWAVs))
        }
    }

    private static func allocated(_ files: [Inode: FileBlocks]) -> Int64 {
        files.values.reduce(0) { $0 + $1.bytes }
    }

    private static func reclaimable(_ files: [Inode: FileBlocks]) -> Int64 {
        files.values.reduce(0) { $0 + ($1.linksHere == $1.linksOnDisk ? $1.bytes : 0) }
    }

    private static func scan(_ url: URL, include: (URL) -> Bool,
                             into files: inout [Inode: FileBlocks]) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if info.st_mode & S_IFMT == S_IFDIR {
            let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard let stream = fdopendir(descriptor) else {
                let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                close(descriptor)
                throw error
            }
            defer { closedir(stream) }
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    if errno != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    break
                }
                let bytes = withUnsafeBytes(of: entry.pointee.d_name) {
                    Array($0.prefix(Int(entry.pointee.d_namlen)))
                }
                guard let name = String(bytes: bytes, encoding: .utf8) else {
                    throw StoreError.invalid("A storage filename is not UTF-8.")
                }
                if name == "." || name == ".." { continue }
                try scan(url.appendingPathComponent(name), include: include, into: &files)
            }
        } else if info.st_mode & S_IFMT == S_IFREG && include(url) {
            let inode = Inode(device: info.st_dev, number: info.st_ino)
            if var existing = files[inode] {
                existing.linksHere += 1
                files[inode] = existing
            } else {
                files[inode] = FileBlocks(bytes: max(0, Int64(info.st_blocks)) * 512,
                    linksOnDisk: UInt64(info.st_nlink), linksHere: 1)
            }
        }
    }
}
