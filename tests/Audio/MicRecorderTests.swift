import AVFoundation
import CoreAudio
import Foundation
import NarrariKit
import Testing

@MainActor
struct MicRecorderTests {
    private let folder = TemporaryFolder()
    private let settings = ThrowawaySettings()
    private let inputs = FakeInputs()

    private func recorder(microphone: AVAuthorizationStatus = .authorized, write: MicRecorder.Write? = nil) -> MicRecorder {
        let permissions = Permissions(settings: settings.store, access: .fixed(), microphoneStatus: { microphone })
        guard let write else { return MicRecorder(settings: settings.store, permissions: permissions, inputs: inputs) }
        return MicRecorder(settings: settings.store, permissions: permissions, inputs: inputs, write: write)
    }

    private func file() -> URL {
        folder.url.appending(path: "\(UUID().uuidString).caf")
    }

    @Test func each_dictation_opens_the_microphone_picked_at_its_start_and_closes_it_at_stop() throws {
        let recorder = recorder()
        try recorder.start(writingTo: file())
        inputs.current = 2
        _ = recorder.stop()
        try recorder.start(writingTo: file())

        #expect(inputs.builtFor == [1, 2])
        #expect(inputs.engines.map(\.isStarted) == [false, true])
    }

    @Test func a_dictations_audio_file_is_the_owners_alone() throws {
        let kept = file()
        try recorder().start(writingTo: kept)

        #expect(try FileManager.default.attributesOfItem(atPath: kept.path)[.posixPermissions] as? Int == 0o600)
    }

    @Test func a_write_the_disk_refuses_keeps_every_second_for_the_text_and_says_the_audio_is_short() throws {
        let recorder = recorder { _, _, _ in kAudioFileUnspecifiedError }
        try recorder.start(writingTo: file())
        inputs.engines.last?.play(seconds: 1)

        let recorded = recorder.stop()

        #expect(abs(recorded.samples.count - 16_000) < 100)
        #expect(recorded.problem == RecorderError.audioWriteFailed.problem)
    }

    @Test func start_with_microphone_access_off_opens_no_microphone() {
        let recorder = recorder(microphone: .denied)

        #expect(throws: RecorderError.microphoneDenied) { try recorder.start(writingTo: file()) }
        #expect(inputs.engines.isEmpty)
    }

    @Test func start_after_a_failed_start_works() throws {
        let recorder = recorder()
        inputs.failNextStart()

        #expect(throws: RecorderError.startFailed) { try recorder.start(writingTo: file()) }
        try recorder.start(writingTo: file())

        #expect(inputs.engines.last?.isStarted == true)
    }

    @Test func format_change_while_the_microphone_is_still_there_keeps_every_second_in_the_transcript_and_the_file() throws {
        let recorder = recorder()
        var interruptions = 0
        var switches: [String?] = []
        recorder.onInterruption = { interruptions += 1 }
        recorder.onSwitch = { switches.append($0) }
        let kept = file()
        try recorder.start(writingTo: kept)
        inputs.engines.last?.play(seconds: 1)

        inputs.sampleRate = 16_000
        inputs.engines.last?.hardwareChanged()
        inputs.engines.last?.play(seconds: 1)
        let recent = recorder.recentSamples(20_000)
        let samples = recorder.stop().samples

        #expect(interruptions == 0)
        #expect(switches.isEmpty)
        #expect(recent == Array(samples.suffix(20_000)))
        #expect(abs(samples.count - 32_000) < 100)
        #expect(try AVAudioFile(forReading: kept).length == AVAudioFramePosition(samples.count))
    }

    @Test func microphone_gone_with_another_connected_carries_on_from_it_and_says_so_once() throws {
        let recorder = recorder()
        var interruptions = 0
        var switches: [String?] = []
        recorder.onInterruption = { interruptions += 1 }
        recorder.onSwitch = { switches.append($0) }
        try recorder.start(writingTo: file())
        inputs.engines.last?.play(seconds: 1)

        inputs.current = 2
        inputs.engines.last?.hardwareChanged()
        inputs.engines.last?.play(seconds: 1)
        let samples = recorder.stop().samples

        #expect(interruptions == 0)
        #expect(switches == ["Microphone 2"])
        #expect(inputs.builtFor == [1, 2])
        #expect(abs(samples.count - 32_000) < 100)
    }

    @Test func digital_silence_and_noise_under_a_quiet_room_floor_count_as_no_sound() async throws {
        let recorder = recorder()
        var announced = 0
        recorder.onFirstSound = { announced += 1 }
        try recorder.start(writingTo: file())

        inputs.engines.last?.play(seconds: 1) { _ in 0 }
        inputs.engines.last?.play(seconds: 1) { _ in noise(decibels: -120) }
        #expect(!recorder.hasHeardSound)
        #expect(recorder.microphoneName == "Microphone 1")

        inputs.engines.last?.play(seconds: 0.1) { _ in noise(decibels: -90) }
        inputs.engines.last?.play(seconds: 0.1) { _ in noise(decibels: -90) }
        #expect(recorder.hasHeardSound)
        await mainQueueCaughtUp()
        #expect(announced == 1)
        _ = recorder.stop()
        try recorder.start(writingTo: file())
        #expect(!recorder.hasHeardSound)
    }

    @Test func a_first_sound_that_reaches_main_after_its_dictation_stopped_is_dropped() async throws {
        let recorder = recorder()
        var announced = 0
        recorder.onFirstSound = { announced += 1 }
        try recorder.start(writingTo: file())

        inputs.engines.last?.play(seconds: 0.1) { _ in noise(decibels: -90) }
        _ = recorder.stop()
        try recorder.start(writingTo: file())
        await mainQueueCaughtUp()

        #expect(announced == 0)
    }

    // The audio thread hands the first sound to the main queue, which runs in order, so this returns after it.
    private func mainQueueCaughtUp() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    @Test func microphone_lost_while_recording_stops_the_dictation_and_the_next_one_starts() throws {
        let recorder = recorder()
        var interruptions = 0
        recorder.onInterruption = { interruptions += 1 }
        try recorder.start(writingTo: file())

        inputs.current = nil
        inputs.engines.last?.hardwareChanged()
        inputs.current = 1
        _ = recorder.stop()
        try recorder.start(writingTo: file())

        #expect(interruptions == 1)
        #expect(inputs.engines.last?.isStarted == true)
    }
}

// Used on the main actor only; FakeEngine's start and stop run there too.
private final class FakeInputs: AudioInputs, @unchecked Sendable {
    var current: AudioObjectID? = 1
    var sampleRate: Double = 48_000
    private(set) var builtFor: [AudioObjectID] = []
    private(set) var engines: [FakeEngine] = []
    private var failsNextStart = false

    func failNextStart() { failsNextStart = true }

    func current(chosenUID: String, prefersBuiltIn: Bool) -> AudioObjectID? { current }

    func name(of device: AudioObjectID) -> String? { "Microphone \(device)" }

    func makeEngine(for device: AudioObjectID, onChange: @escaping @Sendable () -> Void) -> any InputEngine {
        builtFor.append(device)
        let engine = FakeEngine(sampleRate: sampleRate, onChange: onChange) { [weak self] in
            guard let self else { return false }
            defer { failsNextStart = false }
            return failsNextStart
        }
        engines.append(engine)
        return engine
    }
}

private final class FakeEngine: InputEngine, @unchecked Sendable {
    let sampleRate: Double?
    private let onChange: @Sendable () -> Void
    private let fails: () -> Bool

    init(sampleRate: Double, onChange: @escaping @Sendable () -> Void, fails: @escaping () -> Bool) {
        self.sampleRate = sampleRate
        self.onChange = onChange
        self.fails = fails
    }

    private(set) var isStarted = false
    private var feed: (@Sendable (UnsafeBufferPointer<Float>, UInt64) -> Void)?

    func start(feeding feed: @escaping @Sendable (UnsafeBufferPointer<Float>, UInt64) -> Void) throws {
        if fails() { throw CocoaError(.featureUnsupported) }
        self.feed = feed
        isStarted = true
    }

    func stop() {
        feed = nil
        isStarted = false
    }

    // A tone unless told otherwise, in 10 ms buffers, the way a device delivers it.
    func play(seconds: Double, sample: ((Int) -> Float)? = nil) {
        guard let feed, let sampleRate else { return }
        let tone: (Int) -> Float = { index in Float(sin(Double(index) * 2 * .pi * 440 / sampleRate) * 0.25) }
        let audio: [Float] = (0..<Int(seconds * sampleRate)).map(sample ?? tone)
        for start in stride(from: 0, to: audio.count, by: Int(sampleRate / 100)) {
            audio[start..<min(start + Int(sampleRate / 100), audio.count)].withUnsafeBufferPointer { feed($0, 0) }
        }
    }

    func hardwareChanged() {
        onChange()
    }
}

// White noise at this RMS level, the hiss a live microphone delivers with nobody speaking.
private func noise(decibels: Double) -> Float {
    let uniform = Double.random(in: Double.ulpOfOne..<1)
    let normal = sqrt(-2 * log(uniform)) * cos(2 * .pi * Double.random(in: 0..<1))
    return Float(normal * pow(10, decibels / 20))
}
