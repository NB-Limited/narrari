import AVFoundation
import CoreAudio
import Synchronization

// Plays recorded audio into a recorder as a device would, stamped with host times from a clock the caller moves.
// `audio` is what the room sounded like, at the speech rate, looped; a device whose clock runs fast delivers more samples per second.
public final class ReplayInput: InputEngine, Sendable {
    public let sampleRate: Double?
    // What the device truly delivers per second of host time, against the rate it reports.
    private let deliveredRate: Double
    private let audio: [Float]
    private let clock: ReplayClock
    // A struct, not a tuple: a tuple in the lock wraps the closure again on every write, and the chain overflows the stack.
    private struct Playback {
        var feed: (@Sendable (UnsafeBufferPointer<Float>, UInt64) -> Void)?
        var started = 0.0
        var delivered = 0
    }

    private let state = Mutex(Playback())

    public init(audio: [Float], clock: ReplayClock, sampleRate: Double = SpeechAudio.sampleRate, partsPerMillionFast: Double = 0) {
        self.audio = audio.isEmpty ? [0] : audio
        self.clock = clock
        self.sampleRate = sampleRate
        deliveredRate = sampleRate * (1 + partsPerMillionFast / 1_000_000)
    }

    public func start(feeding feed: @escaping @Sendable (UnsafeBufferPointer<Float>, UInt64) -> Void) {
        let now = clock.seconds
        state.withLock { $0 = Playback(feed: feed, started: now) }
    }

    public func stop() {
        state.withLock { $0.feed = nil }
    }

    // Delivers, in parts of at most 100 ms, every sample due by the clock's time.
    public func catchUp() {
        let rate = deliveredRate
        let part = Int(rate / 10)
        var buffer = [Float](repeating: 0, count: part)
        while true {
            let next = state.withLock { state -> (feed: @Sendable (UnsafeBufferPointer<Float>, UInt64) -> Void, from: Int, count: Int, at: Double)? in
                guard let feed = state.feed else { return nil }
                let due = Int((clock.seconds - state.started) * rate) - state.delivered
                guard due > 0 else { return nil }
                let count = min(due, part)
                defer { state.delivered += count }
                return (feed, state.delivered, count, state.started + Double(state.delivered) / rate)
            }
            guard let next else { return }
            // The device hears the room at its own rate, so sample i is the room at i / rate seconds.
            for index in 0..<next.count {
                let roomIndex = Int((Double(next.from + index) / rate * SpeechAudio.sampleRate).rounded())
                buffer[index] = audio[roomIndex % audio.count]
            }
            buffer.withUnsafeBufferPointer { next.feed(UnsafeBufferPointer(rebasing: $0[..<next.count]), ReplayClock.hostTime(next.at)) }
        }
    }
}

// Host time that moves only when told, so an hour of meeting replays in seconds.
public final class ReplayClock: Sendable {
    private let now = Mutex<Double>(1)

    public init() {}

    public var seconds: Double { now.withLock { $0 } }

    public var hostTime: UInt64 { Self.hostTime(seconds) }

    public func advance(by seconds: Double) {
        now.withLock { $0 += seconds }
    }

    static func hostTime(_ seconds: Double) -> UInt64 {
        AVAudioTime.hostTime(forSeconds: seconds)
    }
}

// A meeting's two inputs from replayed audio, behind the same boundaries the microphone and the system tap use.
public final class Replay: AudioInputs, SystemSoundSource, Sendable {
    public let clock = ReplayClock()
    public let microphone: ReplayInput
    public let system: ReplayInput

    public init(microphone: [Float], system: [Float], microphonePartsPerMillionFast: Double = 0) {
        self.microphone = ReplayInput(audio: microphone, clock: clock, partsPerMillionFast: microphonePartsPerMillionFast)
        self.system = ReplayInput(audio: system, clock: clock)
    }

    // Moves the clock in 100 ms steps, the inputs delivering as it goes.
    public func play(seconds: Double) {
        var left = seconds
        while left > 1e-9 {
            let step = min(left, 0.1)
            clock.advance(by: step)
            microphone.catchUp()
            system.catchUp()
            left -= step
        }
    }

    public func current(chosenUID: String, prefersBuiltIn: Bool) -> AudioObjectID? { 1 }

    public func name(of device: AudioObjectID) -> String? { "Replay" }

    public func makeEngine(for device: AudioObjectID, onChange: @escaping @Sendable () -> Void) -> any InputEngine { microphone }

    public func makeEngine(onChange: @escaping @Sendable () -> Void) -> any InputEngine { system }
}
