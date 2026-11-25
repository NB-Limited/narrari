import AVFoundation
import Observation

@MainActor
@Observable
public final class AudioPlayback {
    // Stretches of the audio heard alone, in order, such as one speaker's lines.
    public struct Part: Sendable, Equatable {
        public let id: String
        public let stretches: [Range<TimeInterval>]

        public init(id: String, stretches: [Range<TimeInterval>]) {
            self.id = id
            self.stretches = stretches
        }

        // The stretch to hear from this position: the one it is in, or the next; nil after the last.
        public func stretch(at position: TimeInterval) -> Range<TimeInterval>? {
            stretches.first { position < $0.upperBound }
        }
    }

    public private(set) var isPlaying = false
    public private(set) var position: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    // Set while a part plays or is paused; every other control plays the whole audio again.
    public private(set) var part: Part?

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
        part = nil
        resume()
    }

    // The same part pauses and resumes where it was; another one starts at its first stretch.
    public func toggle(_ part: Part) {
        if self.part?.id == part.id {
            self.part = part
            return isPlaying ? halt() : resume()
        }
        guard let first = part.stretches.first, openedPlayer() != nil else { return }
        self.part = part
        move(to: first.lowerBound)
        resume()
    }

    public func pause() {
        part = nil
        halt()
    }

    public func stop() {
        part = nil
        players.forEach {
            $0.stop()
            $0.currentTime = 0
        }
        isPlaying = false
        ticker?.cancel()
        position = 0
    }

    public func seek(to fraction: Double) {
        part = nil
        guard let player = openedPlayer() else { return }
        move(to: min(max(fraction, 0), 1) * player.duration)
    }

    public func skip(by seconds: TimeInterval) {
        guard duration > 0 else { return }
        seek(to: (position + seconds) / duration)
    }

    private func resume() {
        guard let player = openedPlayer() else { return }
        if player.currentTime >= player.duration { players.forEach { $0.currentTime = 0 } }
        guard start() else { return }
        isPlaying = true
        startTicking()
    }

    // Every track starts on the same sample, also after a jump while playing.
    private func start() -> Bool {
        guard let player else { return false }
        let start = player.deviceCurrentTime + Self.startDelay
        guard players.allSatisfy({ $0.play(atTime: start) }) else {
            Log.failure("audio-play")
            return false
        }
        return true
    }

    private func halt() {
        players.forEach { $0.pause() }
        isPlaying = false
        ticker?.cancel()
        syncPosition()
    }

    private func move(to seconds: TimeInterval) {
        players.forEach { $0.currentTime = seconds }
        syncPosition()
    }

    // At the end of a stretch the part jumps to the next one, and after the last it pauses and the whole plays again.
    private func followPart() {
        guard let part else { return }
        guard let next = part.stretch(at: position) else {
            halt()
            self.part = nil
            return
        }
        guard position < next.lowerBound else { return }
        players.forEach { $0.pause() }
        move(to: next.lowerBound)
        if !start() { halt() }
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
                    part = nil
                    return
                }
                followPart()
            }
        }
    }

    private func syncPosition() {
        position = player?.currentTime ?? 0
    }
}
