import AfterwordCore
import Foundation

enum VoiceProfileLabels {
    private struct CorrectionLineage: Decodable {
        let speaker_corrections: [SpeakerCorrection]?
    }

    private struct Manifest: Decodable {
        let schema_version: Int
        let meeting_id: String
        let revision_id: String
        let run_id: String
        let profiles: [Profile]
    }

    private struct Profile: Decodable {
        let speaker_id: String
        let voice_id: String
    }

    static func load(store: MeetingStore, meetingID: String, transcript: Transcript) throws -> [String: String] {
        let url = try store.artifactURL(meetingID: meetingID, relativePath: "voice_profiles.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try Artifacts.require(size <= 1_048_576, "Voice profiles exceed their size limit.")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        try Artifacts.require(Artifacts.identifier(manifest.revision_id) && Artifacts.identifier(manifest.run_id),
                              "Voice profile identity is invalid.")
        if manifest.revision_id != transcript.revision_id || manifest.run_id != transcript.run_id {
            let provenance = try Artifacts.read(CorrectionLineage.self, store: store, meetingID: meetingID,
                                                path: "revisions/\(transcript.revision_id)/provenance.json")
            guard let first = provenance.speaker_corrections?.first,
                  first.parent_revision_id == manifest.revision_id else { return [:] }
            let parent = try Artifacts.read(Transcript.self, store: store, meetingID: meetingID,
                                            path: "revisions/\(manifest.revision_id)/transcript.json")
            guard parent.run_id == manifest.run_id else { return [:] }
        }
        try Artifacts.require(manifest.schema_version == 1 && manifest.meeting_id == meetingID
                              && manifest.profiles.count <= 64, "Voice profiles do not match this meeting.")
        let remoteIDs = Set(transcript.speakers.filter { $0.source == .system }.map(\.id))
        var labels: [String: String] = [:]
        var seenVoices = Set<String>()
        for profile in manifest.profiles {
            try Artifacts.require(profile.voice_id.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil
                                  && seenVoices.insert(profile.voice_id).inserted,
                                  "Voice profile identity is invalid.")
            guard remoteIDs.contains(profile.speaker_id) else { continue }
            try Artifacts.require(labels[profile.speaker_id] == nil, "Voice profile speaker is duplicated.")
            labels[profile.speaker_id] = "Voice " + profile.voice_id.prefix(8).uppercased()
        }
        return labels
    }
}
