import AVFoundation

/// A score belongs to one presentation, and may only accompany a bundled animation.
@MainActor final class StartupSoundtrack {
    private let player: AVAudioPlayer
    private var fadeTask: Task<Void, Never>?
    private(set) var started = false
    var isPlaying: Bool { player.isPlaying }
    var volume: Float { player.volume }
    var currentTime: TimeInterval { player.currentTime }
    var duration: TimeInterval { player.duration }

    init?(url: URL) {
        guard let player = try? AVAudioPlayer(contentsOf: url), player.prepareToPlay() else { return nil }
        self.player = player
        player.volume = 0.65
        player.numberOfLoops = 0
    }

    static func url(for animation: URL) -> URL? {
        for theme in StartupTheme.allCases {
            guard let bundled = StartupMediaStore.defaultURL(for: theme),
                  bundled.standardizedFileURL == animation.standardizedFileURL else { continue }
            let name = theme == .light ? "StartupSacredLight" : "StartupSacredDark"
            return bundled.deletingLastPathComponent().appendingPathComponent(name + ".wav")
        }
        return nil
    }

    func play() {
        guard !started else { return }
        started = true
        player.play()
    }

    func fadeOut(duration: TimeInterval) {
        fadeTask?.cancel()
        guard duration > 0, player.isPlaying else { stop(); return }
        player.setVolume(0, fadeDuration: duration)
        fadeTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000)) }
            catch { return }
            self?.stop()
        }
    }

    func stop() {
        fadeTask?.cancel(); fadeTask = nil
        player.stop()
    }
}
