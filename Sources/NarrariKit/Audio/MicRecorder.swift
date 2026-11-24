import AudioToolbox
import AVFoundation
import CoreAudio
import Synchronization

public enum RecorderError: ProblemError, Equatable {
    case microphoneDenied
    case microphoneAccessRequested
    case noInput
    case startFailed

    public var problem: Problem {
        switch self {
        case .microphoneDenied: Problem("recorder.denied", "Microphone access is off. Allow it in System Settings.", canRetry: true)
        case .microphoneAccessRequested: Problem("recorder.asked", "Allow microphone access, then try again.", canRetry: true)
        case .noInput: Problem("recorder.no-input", Self.couldNotStart, canRetry: true)
        case .startFailed: Problem("recorder.start-failed", Self.couldNotStart, canRetry: true)
        }
    }

    private static let couldNotStart = "The microphone could not start. Try again, or choose another in Settings, Speech."
}

@MainActor
public protocol AudioCapture: AnyObject {
    var onInterruption: (() -> Void)? { get set }
    // Called with the new microphone's name when recording carries on from another one.
    var onSwitch: ((String?) -> Void)? { get set }
    // Called on main once per dictation, when hasHeardSound turns true.
    var onFirstSound: (() -> Void)? { get set }
    var level: Float { get }
    // True once the microphone has delivered anything louder than a dead input since this dictation started.
    var hasHeardSound: Bool { get }
    var microphoneName: String? { get }
    func start(writingTo file: URL) throws
    func stop() -> [Float]
    func recentSamples(_ count: Int) -> [Float]
}

public protocol AudioInputs: Sendable {
    func current(chosenUID: String, prefersBuiltIn: Bool) -> AudioObjectID?
    func name(of device: AudioObjectID) -> String?
    // `onChange` is called on main once the engine no longer delivers, because the device went away or changed format.
    func makeEngine(for device: AudioObjectID, onChange: @escaping @Sendable () -> Void) -> any InputEngine
}

// A meeting's second track: the sound the Mac plays. `onChange` is called on main once the engine no longer delivers.
public protocol SystemSoundSource: Sendable {
    func makeEngine(onChange: @escaping @Sendable () -> Void) -> any InputEngine
}

public protocol InputEngine: AnyObject, Sendable {
    var sampleRate: Double? { get }
    // `feed` runs on the device's IO thread with mono samples at `sampleRate` and their host time, 0 when unknown.
    func start(feeding feed: @escaping @Sendable (UnsafeBufferPointer<Float>, UInt64) -> Void) throws
    func stop()
}

// Each dictation opens the microphone it starts with and closes it when it stops.
@MainActor
public final class MicRecorder: AudioCapture {
    public var onInterruption: (() -> Void)?
    public var onSwitch: ((String?) -> Void)?
    public var onFirstSound: (() -> Void)?

    private let settings: SettingsStore
    private let permissions: Permissions
    private let inputs: any AudioInputs
    private var engine: (any InputEngine)?
    private var device: AudioObjectID?
    private var sink: CaptureSink?
    private var began: TimeInterval = 0
    // Counts dictations, so a first sound handed to main late never lands in the next one.
    private var dictations = 0

    public init(settings: SettingsStore, permissions: Permissions, inputs: any AudioInputs = SystemAudioInputs()) {
        self.settings = settings
        self.permissions = permissions
        self.inputs = inputs
    }

    public var level: Float { sink?.level ?? 0 }

    public var hasHeardSound: Bool { sink?.hasHeardSound ?? false }

    public var microphoneName: String? { device.flatMap(inputs.name(of:)) }

    public func start(writingTo file: URL) throws {
        guard sink == nil else { throw RecorderError.startFailed }
        try permissions.requireMicrophone()
        began = ProcessInfo.processInfo.systemUptime
        dictations += 1

        guard let device = currentInput() else {
            Log.failure("microphone-no-device")
            throw RecorderError.noInput
        }
        let engine = makeEngine(for: device)
        guard let sampleRate = engine.sampleRate else {
            Log.failure("microphone-no-format")
            throw RecorderError.noInput
        }
        let sink: CaptureSink
        do {
            sink = try CaptureSink(writingTo: file, sampleRate: sampleRate, onFirstSound: Self.firstSound(of: dictations, to: self))
        } catch {
            Log.failure("audio-file-create", error: error)
            throw RecorderError.startFailed
        }
        do {
            try engine.start(feeding: Self.feed(into: sink))
        } catch {
            _ = sink.finish()
            Self.delete(file)
            Log.failure("microphone-engine-start", error: error)
            throw RecorderError.startFailed
        }
        self.engine = engine
        self.device = device
        self.sink = sink
        Log.timing("microphone-start", seconds: ProcessInfo.processInfo.systemUptime - began)
    }

    public func stop() -> [Float] {
        guard let sink else { return [] }
        self.sink = nil
        engine?.stop()
        engine = nil
        device = nil
        let samples = sink.finish()
        if let first = sink.firstSampleTime {
            Log.timing("microphone-first-sample", seconds: first - began)
        }
        return samples
    }

    public func recentSamples(_ count: Int) -> [Float] {
        sink?.recentSamples(count) ?? []
    }

    private func makeEngine(for device: AudioObjectID) -> any InputEngine {
        inputs.makeEngine(for: device) { [weak self] in
            MainActor.assumeIsolated { self?.hardwareChanged() }
        }
    }

    private func hardwareChanged() {
        guard let sink else { return }
        let previous = device
        guard let device = resume(into: sink) else {
            Log.failure("microphone-lost")
            onInterruption?()
            return
        }
        if device == previous {
            Log.event("microphone-resumed")
        } else {
            Log.event("microphone-switched")
            onSwitch?(inputs.name(of: device))
        }
    }

    // Picks the microphone again: a Bluetooth headset changes format just after it opens, or the one in use went away.
    private func resume(into sink: CaptureSink) -> AudioObjectID? {
        engine?.stop()
        engine = nil
        device = nil
        guard let device = currentInput() else { return nil }
        let fresh = makeEngine(for: device)
        guard let sampleRate = fresh.sampleRate, sink.retarget(to: sampleRate) else { return nil }
        do {
            try fresh.start(feeding: Self.feed(into: sink))
        } catch {
            Log.failure("microphone-resume", error: error)
            return nil
        }
        engine = fresh
        self.device = device
        return device
    }

    private func currentInput() -> AudioObjectID? {
        inputs.current(
            chosenUID: settings.value(DictationSettings.microphoneUID),
            prefersBuiltIn: settings.value(DictationSettings.prefersBuiltInOverBluetooth)
        )
    }

    private static func delete(_ file: URL) {
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            Log.failure("audio-file-delete", error: error)
        }
    }

    // Built outside the main actor: the feed runs on the IO thread, and a closure made here would assert it is on main.
    private nonisolated static func feed(into sink: CaptureSink) -> @Sendable (UnsafeBufferPointer<Float>, UInt64) -> Void {
        { samples, hostTime in sink.consume(samples, hostTime: hostTime) }
    }

    private nonisolated static func firstSound(of dictation: Int, to recorder: MicRecorder) -> @Sendable () -> Void {
        { [weak recorder] in
            DispatchQueue.main.async { [weak recorder] in
                MainActor.assumeIsolated { recorder?.soundArrived(in: dictation) }
            }
        }
    }

    private func soundArrived(in dictation: Int) {
        guard dictation == dictations, sink != nil else { return }
        onFirstSound?()
    }
}

public struct SystemAudioInputs: AudioInputs {
    public init() {}

    public func current(chosenUID uid: String, prefersBuiltIn: Bool) -> AudioObjectID? {
        guard let pick = MicrophonePick.current(chosenUID: uid, prefersBuiltIn: prefersBuiltIn) else { return nil }
        switch pick {
        case .chosen: Log.event("microphone-chosen")
        case .systemDefault: Log.event("microphone-system-default")
        case .builtInOverBluetooth: Log.event("microphone-built-in-over-bluetooth")
        }
        MicrophoneTransport(AudioDevices.transport(of: pick.device)).log()
        return pick.device
    }

    public func name(of device: AudioObjectID) -> String? {
        AudioDevices.name(of: device)
    }

    public func makeEngine(for device: AudioObjectID, onChange: @escaping @Sendable () -> Void) -> any InputEngine {
        DeviceInputEngine(device: device, onChange: onChange)
    }
}

private final class CaptureSink: Sendable {
    private struct State {
        var file: ExtAudioFileRef?
        var resampler: Resampler
        var samples = SampleBlocks()
        // Kept to dispose at finish, because disposing waits on the disk.
        var failedFile: ExtAudioFileRef?
        var isOpen = true
        var firstSampleTime: TimeInterval?
    }

    private let state: Mutex<State>
    // Read many times a second from the main thread, so it never waits on the lock the audio thread holds.
    private let levelBits = Atomic<UInt32>(0)
    private let heardSound = Atomic<Bool>(false)
    private let onFirstSound: @Sendable () -> Void

    init(writingTo url: URL, sampleRate: Double, onFirstSound: @escaping @Sendable () -> Void) throws {
        guard let resampler = Resampler(from: sampleRate) else { throw RecorderError.noInput }

        state = Mutex(State(file: try Self.file(at: url), resampler: resampler))
        self.onFirstSound = onFirstSound
    }

    // Written with async writes, which the header says are safe from the IO thread; a plain write blocks on the disk.
    private static func file(at url: URL) throws -> ExtAudioFileRef {
        let file = try SpeechAudio.createKeptFile(at: url)
        guard ExtAudioFileWriteAsync(file, 0, nil) == noErr else {
            ExtAudioFileDispose(file)
            try? FileManager.default.removeItem(at: url)
            throw RecorderError.startFailed
        }
        return file
    }

    func retarget(to sampleRate: Double) -> Bool {
        state.withLock { $0.resampler.retarget(to: sampleRate) }
    }

    func consume(_ samples: UnsafeBufferPointer<Float>, hostTime: UInt64) {
        state.withLock { state in
            guard state.isOpen else { return }
            if state.firstSampleTime == nil {
                state.firstSampleTime = hostTime != 0
                    ? AVAudioTime.seconds(forHostTime: hostTime) : ProcessInfo.processInfo.systemUptime
            }
            guard let target = state.resampler.input(frames: samples.count) else { return }
            for (index, sample) in samples.enumerated() { target[index] = sample }
            guard let output = state.resampler.convert(), let channel = output.floatChannelData?[0] else { return }
            if let file = state.file, ExtAudioFileWriteAsync(file, output.frameLength, output.audioBufferList) != noErr {
                state.failedFile = file
                state.file = nil
                Log.failure("audio-file-write")
            }
            let converted = UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
            state.samples.append(contentsOf: converted)
            let decibels = SoundLevel.decibels(of: converted)
            levelBits.store(SoundLevel.meter(decibels).bitPattern, ordering: .relaxed)
            if SoundLevel.isSound(decibels), heardSound.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged {
                onFirstSound()
            }
        }
    }

    var level: Float {
        Float(bitPattern: levelBits.load(ordering: .relaxed))
    }

    var hasHeardSound: Bool {
        heardSound.load(ordering: .relaxed)
    }

    func recentSamples(_ count: Int) -> [Float] {
        state.withLock { $0.samples.suffix(count) }
    }

    var firstSampleTime: TimeInterval? {
        state.withLock { $0.firstSampleTime }
    }

    func finish() -> [Float] {
        state.withLock { state in
            state.isOpen = false
            for file in [state.file, state.failedFile].compactMap(\.self) { ExtAudioFileDispose(file) }
            state.file = nil
            state.failedFile = nil
            return state.samples
        }.all
    }
}

// Fixed one-second blocks: one array growing by doubling copied everything it held on the IO thread, up to 14 ms at 26 minutes.
private struct SampleBlocks {
    private static let blockSize = Int(SpeechAudio.sampleRate)
    private var blocks: [[Float]] = []

    mutating func append(contentsOf samples: UnsafeBufferPointer<Float>) {
        var rest = samples[...]
        while !rest.isEmpty {
            if blocks.last.map({ $0.count == Self.blockSize }) ?? true {
                blocks.append([])
                blocks[blocks.count - 1].reserveCapacity(Self.blockSize)
            }
            let taken = rest.prefix(Self.blockSize - blocks[blocks.count - 1].count)
            blocks[blocks.count - 1].append(contentsOf: taken)
            rest = rest.dropFirst(taken.count)
        }
    }

    func suffix(_ count: Int) -> [Float] {
        guard count > 0, var start = blocks.indices.last else { return [] }
        var held = blocks[start].count
        while start > 0, held < count {
            start -= 1
            held += blocks[start].count
        }
        var tail: [Float] = []
        tail.reserveCapacity(min(held, count))
        tail.append(contentsOf: blocks[start].dropFirst(max(held - count, 0)))
        for block in blocks[(start + 1)...] { tail.append(contentsOf: block) }
        return tail
    }

    var all: [Float] { suffix(.max) }
}
