import AVFoundation
import Foundation

/// Plays a meeting's saved mic + system WAV files in sync so playback sounds
/// like the original call.
@MainActor
final class PlaybackController: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private var players: [AVAudioPlayer] = []
    private var ticker: Task<Void, Never>?

    var hasAudio: Bool { !players.isEmpty }

    func load(urls: [URL]) {
        stop()
        players = urls.compactMap { try? AVAudioPlayer(contentsOf: $0) }
        players.forEach { $0.prepareToPlay() }
        duration = players.map(\.duration).max() ?? 0
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard hasAudio else { return }
        if currentTime >= duration - 0.1 { currentTime = 0 }
        for player in players {
            player.currentTime = min(currentTime, player.duration)
            player.play()
        }
        isPlaying = true
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                self.currentTime = self.players.map(\.currentTime).max() ?? self.currentTime
                if self.players.allSatisfy({ !$0.isPlaying }) {
                    self.isPlaying = false
                    return
                }
            }
        }
    }

    func pause() {
        players.forEach { $0.pause() }
        isPlaying = false
        ticker?.cancel()
        ticker = nil
    }

    func stop() {
        players.forEach { $0.stop() }
        players = []
        isPlaying = false
        currentTime = 0
        duration = 0
        ticker?.cancel()
        ticker = nil
    }

    func seek(to time: TimeInterval) {
        currentTime = max(0, min(time, duration))
        for player in players {
            player.currentTime = min(currentTime, player.duration)
        }
    }
}
