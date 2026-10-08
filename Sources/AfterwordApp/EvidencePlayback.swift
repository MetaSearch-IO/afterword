import AVFoundation
import Foundation

@MainActor
final class EvidencePlayback: NSObject, AVAudioPlayerDelegate {
    struct Part {
        let url: URL
        let offset: TimeInterval
        let duration: TimeInterval
    }

    private var parts: [Part] = []
    private var index = 0
    private var player: AVAudioPlayer?
    private var boundary: Task<Void, Never>?
    private let ended: (String?) -> Void

    init(ended: @escaping (String?) -> Void) { self.ended = ended }

    func play(_ parts: [Part]) throws {
        stop()
        self.parts = parts
        do { try next() }
        catch { stop(); throw error }
    }

    func stop() {
        boundary?.cancel()
        boundary = nil
        player?.stop()
        player = nil
        parts = []
        index = 0
    }

    private func next() throws {
        boundary?.cancel()
        player?.stop()
        guard index < parts.count else { stop(); ended(nil); return }
        let part = parts[index]
        index += 1
        let audio = try AVAudioPlayer(contentsOf: part.url)
        audio.delegate = self
        audio.currentTime = part.offset
        player = audio
        guard audio.play() else { throw CaptureFailure(message: "Unable to play retained evidence audio.") }
        boundary = Task {
            do { try await Task.sleep(for: .seconds(part.duration)) }
            catch { return }
            if self.player === audio { advance() }
        }
    }

    private func advance() {
        do { try next() }
        catch { stop(); ended(error.localizedDescription) }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let playerID = ObjectIdentifier(player)
        Task { @MainActor in
            guard self.player.map(ObjectIdentifier.init) == playerID else { return }
            if flag { advance() }
            else { stop(); ended("Saved audio playback stopped unexpectedly.") }
        }
    }
}
