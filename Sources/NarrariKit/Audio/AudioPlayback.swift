import AVFoundation
import Observation

@MainActor
@Observable
public final class AudioPlayback {
    public private(set) var isPlaying = false
    public private(set) var position: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0

    @ObservationIgnored private var urls: [URL] = []
    // A meeting's tracks play together; the first leads the position.
    @ObservationIgnored private var players: [AVAudioPlayer] = []
    @ObservationIgnored private var ticker: Task<Void, Never>?

    private static let tick: Duration = .milliseconds(50)
    // Enough for every track to be ready to start on the same sample.
    private static let startDelay: TimeInterval = 0.05

    private var player: AVAudioPlayer? { players.first }

    public init() {}

    // The entry's own duration shows until the files are opened on the first play or seek.
    public func load(_ urls: [URL], expectedDuration: TimeInterval) {
        guard urls != self.urls else { return }
        stop()
        self.urls = urls
        players = []
        position = 0
        duration = expectedDuration
    }

    public func play(from seconds: TimeInterval) {
        guard duration > 0 else { return }
        seek(to: seconds / duration)
        play()
    }

    public func toggle() {
        isPlaying ? pause() : play()
    }

    public func play() {
        guard let player = openedPlayer() else { return }
        if player.currentTime >= player.duration { players.forEach { $0.currentTime = 0 } }
        let start = player.deviceCurrentTime + Self.startDelay
        guard players.allSatisfy({ $0.play(atTime: start) }) else {
            Log.failure("audio-play")
            return
        }
        isPlaying = true
        startTicking()
    }

    public func pause() {
        players.forEach { $0.pause() }
        isPlaying = false
        ticker?.cancel()
        syncPosition()
    }

    public func stop() {
        players.forEach {
            $0.stop()
            $0.currentTime = 0
        }
        isPlaying = false
        ticker?.cancel()
        position = 0
    }

    public func seek(to fraction: Double) {
        guard let player = openedPlayer() else { return }
        let time = min(max(fraction, 0), 1) * player.duration
        players.forEach { $0.currentTime = time }
        syncPosition()
    }

    public func skip(by seconds: TimeInterval) {
        guard duration > 0 else { return }
        seek(to: (position + seconds) / duration)
    }

    private func openedPlayer() -> AVAudioPlayer? {
        if let player { return player }
        guard !urls.isEmpty else { return nil }
        do {
            players = try urls.map(AVAudioPlayer.init(contentsOf:))
            players.forEach { $0.prepareToPlay() }
            duration = players.map(\.duration).max() ?? 0
            return player
        } catch {
            Log.failure("audio-open", error: error)
            return nil
        }
    }

    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while (try? await Task.sleep(for: Self.tick)) != nil {
                guard let self else { return }
                syncPosition()
                if self.player?.isPlaying != true {
                    isPlaying = false
                    position = duration
                    return
                }
            }
        }
    }

    private func syncPosition() {
        position = player?.currentTime ?? 0
    }
}
