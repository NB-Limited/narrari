import Foundation

// Without headphones the microphone hears the speakers, so the far side would be written twice and given to the owner.
// When the check finds the system track in the microphone track, a cleaned microphone track is written for the transcript.
public struct EchoRemoval: MeetingStep {
    public typealias FindSpeech = @Sendable (URL) async throws -> [Bool]
    public typealias Cancel = @Sendable (_ microphone: URL, _ reference: URL, _ output: URL) async throws -> Void

    private let findSpeech: FindSpeech
    private let cancel: Cancel

    public init(findSpeech: @escaping FindSpeech, cancel: @escaping Cancel) {
        self.findSpeech = findSpeech
        self.cancel = cancel
    }

    public init(models: ModelStore) {
        let detector = SpeechDetector(store: models)
        let canceller = EchoCanceller(store: models)
        self.init(findSpeech: detector.speech(in:), cancel: { try await canceller.clean($0, reference: $1, to: $2) })
    }

    public func run(_ id: UUID, in store: MeetingStore) async throws {
        let microphone = try await store.audio(.microphone, of: id)
        let system = try await store.audio(.system, of: id)
        let cleaned = try await store.audio(.cleanedMicrophone, of: id)
        try? FileManager.default.removeItem(at: cleaned)
        guard FileManager.default.fileExists(atPath: system.path) else {
            Log.event("meeting-echo-no-system")
            return
        }
        do {
            let share = try await echoShare(microphone: microphone, system: system)
            Log.count("meeting-echo-percent", Int((share * 100).rounded()))
            guard share >= EchoCheck.removalShare else {
                Log.event("meeting-echo-none")
                return
            }
            try await cancel(microphone, system, cleaned)
            Log.event("meeting-echo-removed")
        } catch AudioModelError.notDownloaded {
            throw MeetingStepWaiting.echoModels
        } catch {
            try? FileManager.default.removeItem(at: cleaned)
            throw error
        }
    }

    public func echoShare(microphone: URL, system: URL) async throws -> Double {
        let check = EchoCheck(
            microphoneSpeech: try await findSpeech(microphone), systemSpeech: try await findSpeech(system),
            microphoneLevels: try EchoCheck.levels(of: microphone), systemLevels: try EchoCheck.levels(of: system)
        )
        return check.share
    }
}

// The share of microphone speech time during which the system track also speaks and the microphone's loudness follows
// the system's, a little later. Loudness rather than the waveform, so a room's colour and reverb don't hide the echo.
struct EchoCheck {
    // Fixed 22-Nov-26 from say-made cases: blocks with echo followed at 0.88 to 0.98, two voices over each other at
    // most 0.31; echo from -6 to -30 dB gave shares of 0.20 to 0.48, no echo gave 0.
    static let removalShare = 0.05
    static let following: Float = 0.6

    private static let levelSeconds = 0.01
    private static let windowLevels = 100
    // The microphone hears the speakers after the output and input latencies; a little either way covers clock skew.
    private static let lags = -5...50

    let microphoneSpeech: [Bool]
    let systemSpeech: [Bool]
    let microphoneLevels: [Float]
    let systemLevels: [Float]

    var share: Double {
        let spoken = microphoneSpeech.filter(\.self).count
        guard spoken > 0 else { return 0 }
        let echoed = microphoneSpeech.indices.filter { block in
            guard microphoneSpeech[block], systemSpeech.indices.contains(block), systemSpeech[block] else { return false }
            let middle = Int((Double(block) + 0.5) * SpeechDetector.blockSeconds / Self.levelSeconds)
            return bestFollowing(around: middle) >= Self.following
        }
        return Double(echoed.count) / Double(spoken)
    }

    // Loudness every 10 ms, as root mean square.
    static func levels(of track: URL) throws -> [Float] {
        let reader = try TrackReader(track)
        let size = Int(levelSeconds * SpeechAudio.sampleRate)
        var levels: [Float] = []
        while let block = try reader.next(100 * size) {
            for start in stride(from: 0, to: block.count, by: size) {
                let part = block[start..<min(start + size, block.count)]
                levels.append((part.reduce(0) { $0 + $1 * $1 } / Float(part.count)).squareRoot())
            }
        }
        return levels
    }

    private func bestFollowing(around middle: Int) -> Float {
        Self.lags.map { lag in
            let times = (middle - Self.windowLevels...middle + Self.windowLevels).filter { time in
                systemLevels.indices.contains(time) && microphoneLevels.indices.contains(time + lag)
            }
            return Self.correlation(times.map { microphoneLevels[$0 + lag] }, times.map { systemLevels[$0] })
        }
        .max() ?? 0
    }

    private static func correlation(_ first: [Float], _ second: [Float]) -> Float {
        guard first.count > 1 else { return 0 }
        let count = Float(first.count)
        let meanFirst = first.reduce(0, +) / count
        let meanSecond = second.reduce(0, +) / count
        var product: Float = 0
        var spreadFirst: Float = 0
        var spreadSecond: Float = 0
        for (a, b) in zip(first, second) {
            product += (a - meanFirst) * (b - meanSecond)
            spreadFirst += (a - meanFirst) * (a - meanFirst)
            spreadSecond += (b - meanSecond) * (b - meanSecond)
        }
        let spread = (spreadFirst * spreadSecond).squareRoot()
        return spread > 0 ? product / spread : 0
    }
}
