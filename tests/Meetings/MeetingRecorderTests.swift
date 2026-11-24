import AVFoundation
import NarrariKit
import Synchronization
import Testing

@MainActor
struct MeetingRecorderTests {
    private let folder = TemporaryFolder()
    private let settings = ThrowawaySettings()
    private let disk = Disk()
    private let clock = TestClock()

    private func recorder(_ replay: Replay, system: (any SystemSoundSource)? = nil) -> MeetingRecorder {
        let permissions = Permissions(settings: settings.store, access: .fixed(), microphoneStatus: { .authorized })
        return MeetingRecorder(
            settings: settings.store, permissions: permissions, inputs: replay, system: system ?? replay,
            freeSpace: { [disk] _ in disk.free.load(ordering: .relaxed) }, hostNow: { replay.clock.hostTime }, clock: clock
        )
    }

    private var mic: URL { folder.url.appending(path: "mic.caf") }
    private var system: URL { folder.url.appending(path: "system.caf") }

    @Test(arguments: [true, false])
    func both_tracks_are_written_at_the_meetings_length_and_a_silent_system_track_is_reported_not_failed(isSystemPlaying: Bool) throws {
        let replay = Replay(microphone: speech(seconds: 3), system: isSystemPlaying ? speech(seconds: 2) : [0])
        let recorder = recorder(replay)

        try recorder.start(in: folder.url)
        replay.play(seconds: 30)
        let levels = (recorder.microphoneLevel, recorder.systemLevel)
        let recording = try #require(recorder.stop())

        #expect(abs(recording.duration / .seconds(1) - 30) < 0.001)
        #expect(recording.heardSystemSound == isSystemPlaying)
        #expect(levels.0 > 0 && (levels.1 > 0) == isSystemPlaying)
        #expect(try length(of: mic) == 30 * 16_000)
        #expect(try length(of: system) == 30 * 16_000)
    }

    @Test func a_track_that_starts_late_is_padded_with_silence_so_both_stay_on_one_clock() throws {
        let replay = Replay(microphone: speech(seconds: 1), system: speech(seconds: 1))
        let late = LateSystem(replay.system)
        let recorder = recorder(replay, system: late)

        try recorder.start(in: folder.url)
        replay.play(seconds: 5)
        late.arrive()
        replay.play(seconds: 10)
        _ = recorder.stop()

        #expect(try length(of: system) == 15 * 16_000)
        #expect(try samples(of: system, from: 0, seconds: 4.9).allSatisfy { $0 == 0 })
        #expect(try samples(of: system, from: 5.1, seconds: 9.8).contains { $0 != 0 })
    }

    @Test func paused_time_is_left_out_of_both_files_and_the_duration() throws {
        let replay = Replay(microphone: speech(seconds: 1), system: speech(seconds: 1))
        let recorder = recorder(replay)

        try recorder.start(in: folder.url)
        replay.play(seconds: 10)
        recorder.pause()
        replay.play(seconds: 7)
        recorder.resume()
        replay.play(seconds: 10)
        let recording = try #require(recorder.stop())

        #expect(abs(recording.duration / .seconds(1) - 20) < 0.001)
        #expect(try length(of: mic) == 20 * 16_000)
        #expect(try length(of: system) == 20 * 16_000)
    }

    // A clap heard by both, the microphone's clock running 100 parts per million fast: 360 ms over the hour if nothing held it.
    @Test func a_fast_microphone_stays_within_30_ms_of_the_system_track_over_an_hour() async throws {
        let minute = Int(60 * 16_000)
        let clapAt = 59.5
        let room = (0..<minute).map { index -> Float in abs(Double(index) / 16_000 - clapAt) < 0.002 ? 0.9 : 0 }
        let replay = Replay(microphone: room, system: room, microphonePartsPerMillionFast: 100)
        let recorder = recorder(replay)

        try recorder.start(in: folder.url)
        // Off the main actor, so the hour of replay never holds up other tests waiting on main.
        await Task.detached { replay.play(seconds: 3_600) }.value
        _ = recorder.stop()

        let lastClap = 59 * 60 + clapAt
        let heardByMicrophone = try clap(in: mic, near: lastClap)
        let heardBySystem = try clap(in: system, near: lastClap)
        #expect(abs(heardByMicrophone - lastClap) < 0.03)
        #expect(abs(heardBySystem - lastClap) < 0.03)
        #expect(abs(heardByMicrophone - heardBySystem) < 0.03)
    }

    // A Bluetooth headset drops from 48 to 16 kHz when a call opens its microphone; the tap is built again at the new rate.
    @Test func the_system_track_keeps_its_sound_in_place_when_the_output_device_changes_rate() throws {
        let clapAt = 0.55
        let room = (0..<32_000).map { index -> Float in abs(Double(index) / 16_000 - clapAt) < 0.002 ? 0.9 : 0 }
        let replay = Replay(microphone: room, system: [0])
        let output = ChangingOutput(audio: room, clock: replay.clock, rate: 48_000)
        let recorder = recorder(replay, system: output)

        try recorder.start(in: folder.url)
        replay.play(seconds: 5)
        output.catchUp()
        output.change(to: 16_000)
        replay.play(seconds: 5)
        output.catchUp()
        _ = recorder.stop()

        #expect(try length(of: system) == 10 * 16_000)
        #expect(abs(try clap(in: system, near: 2.55) - 2.55) < 0.005)
        #expect(abs(try clap(in: system, near: 7.55) - 7.55) < 0.005)
    }

    @Test func a_disk_under_1_gb_refuses_the_start_and_under_200_mb_stops_the_recording_keeping_its_files() async throws {
        let replay = Replay(microphone: speech(seconds: 1), system: speech(seconds: 1))
        let recorder = recorder(replay)
        disk.free.store(900_000_000, ordering: .relaxed)
        #expect(throws: MeetingRecorderError.lowDisk) { try recorder.start(in: folder.url) }
        #expect(folder.files(withExtension: "caf").isEmpty)

        disk.free.store(2_000_000_000, ordering: .relaxed)
        try recorder.start(in: folder.url)
        replay.play(seconds: 12)
        disk.free.store(150_000_000, ordering: .relaxed)
        let recording = await withCheckedContinuation { continuation in
            recorder.onLowDisk = { continuation.resume(returning: $0) }
            replay.play(seconds: 8)
        }

        #expect(!recorder.isMeetingUnderWay)
        #expect(recording.duration >= .seconds(12) && recording.duration <= .seconds(20))
        #expect(try length(of: mic) == Int((recording.duration / .seconds(1) * 16_000).rounded()))
    }

    private func faultyRecording(reporting: Double = 16_000, delivering: Double = 16_000) throws -> (Replay, FaultyOutput, MeetingRecorder, Told) {
        let replay = Replay(microphone: speech(seconds: 1), system: [0])
        let output = FaultyOutput(audio: speech(seconds: 1), clock: replay.clock)
        output.run(reporting: reporting, delivering: delivering)
        let recorder = recorder(replay, system: output)
        let told = Told()
        recorder.onTrouble = { told.all.append($0) }
        try recorder.start(in: folder.url)
        return (replay, output, recorder, told)
    }

    // The shape the audit once saw after a rate change: the engine delivers nothing from then on.
    @Test func a_track_that_freezes_is_built_again_untold_and_one_that_stays_frozen_is_told_until_its_sound_comes_back() async throws {
        let (replay, output, recorder, told) = try faultyRecording()
        await record(5, replay, output, checkedBy: clock)
        output.change(to: 48_000)
        output.freeze()
        await record(6, replay, output, checkedBy: clock)
        #expect(output.builds == 3)
        #expect(told.all.isEmpty)

        output.freeze(all: true)
        await record(7, replay, output, checkedBy: clock)
        #expect(told.all == [RecordingTrouble(track: .system, kind: .stopped)])

        output.thaw()
        await record(2, replay, output, checkedBy: clock)
        #expect(told.all.last == .some(nil))
        let recording = try #require(recorder.stop())
        #expect(recording.systemLost > 0.3 && recording.microphoneLost < 0.02)
    }

    // The call that was lost: a tap reporting 48 kHz and delivering 16 kHz. A rebuild at the same rate does not help.
    @Test func a_track_at_a_rate_other_than_its_own_is_built_again_once_then_told_and_clears_once_the_rate_is_right() async throws {
        let (replay, output, recorder, told) = try faultyRecording(reporting: 48_000, delivering: 16_000)
        await record(25, replay, output, checkedBy: clock)
        #expect(output.builds == 2)
        #expect(told.all == [RecordingTrouble(track: .system, kind: .poor)])

        output.change(to: 16_000)
        await record(14, replay, output, checkedBy: clock)
        #expect(told.all.last == .some(nil))
        recorder.stop()
    }

    // Six changes in 12 s, each pausing the device 0.6 s as BlackHole does: the rig's worst normal case.
    @Test func normal_device_changes_are_never_told_and_what_they_cost_is_kept() async throws {
        let (replay, output, recorder, told) = try faultyRecording()
        await record(3, replay, output, checkedBy: clock)
        for rate in [16_000.0, 44_100, 16_000, 48_000, 8_000, 48_000] {
            output.change(to: rate)
            output.freeze()
            await record(0.6, replay, output, checkedBy: clock)
            output.thaw()
            await record(1.4, replay, output, checkedBy: clock)
        }
        await record(25, replay, output, checkedBy: clock)
        let recording = try #require(recorder.stop())

        #expect(output.builds == 7)
        #expect(told.all.isEmpty)
        #expect(recording.systemLost > 3.6 / 40 && recording.systemLost < 5.0 / 40)
    }

    private func length(of url: URL) throws -> Int {
        Int(try AVAudioFile(forReading: url).length)
    }

    private func samples(of url: URL, from start: Double, seconds: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        file.framePosition = AVAudioFramePosition(start * 16_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(seconds * 16_000)))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    // Seconds into the file of the loudest sample within a second of `near`.
    private func clap(in url: URL, near: Double) throws -> Double {
        let window = try samples(of: url, from: near - 1, seconds: 2)
        let loudest = try #require(window.indices.max { abs(window[$0]) < abs(window[$1]) })
        return near - 1 + Double(loudest) / 16_000
    }
}

@MainActor
private final class Told {
    var all: [RecordingTrouble?] = []
}

// System sound that arrives only once told, the way a tap starts late.
private final class LateSystem: SystemSoundSource, InputEngine, @unchecked Sendable {
    private let input: ReplayInput
    private var feed: (@Sendable (UnsafeBufferPointer<Float>, UInt64) -> Void)?

    init(_ input: ReplayInput) {
        self.input = input
    }

    var sampleRate: Double? { input.sampleRate }

    func makeEngine(onChange: @escaping @Sendable () -> Void) -> any InputEngine { self }

    func start(feeding feed: @escaping @Sendable (UnsafeBufferPointer<Float>, UInt64) -> Void) {
        self.feed = feed
    }

    func stop() {
        input.stop()
    }

    func arrive() {
        if let feed { input.start(feeding: feed) }
    }
}

// The output device's tap, which the recorder builds again at the new rate once told the device changed.
private final class ChangingOutput: SystemSoundSource, @unchecked Sendable {
    private let audio: [Float]
    private let clock: ReplayClock
    private var rate: Double
    private var engine: ReplayInput?
    private var onChange: (@Sendable () -> Void)?

    init(audio: [Float], clock: ReplayClock, rate: Double) {
        self.audio = audio
        self.clock = clock
        self.rate = rate
    }

    func makeEngine(onChange: @escaping @Sendable () -> Void) -> any InputEngine {
        self.onChange = onChange
        let engine = ReplayInput(audio: audio, clock: clock, sampleRate: rate)
        self.engine = engine
        return engine
    }

    func change(to rate: Double) {
        self.rate = rate
        onChange?()
    }

    func catchUp() {
        engine?.catchUp()
    }
}
