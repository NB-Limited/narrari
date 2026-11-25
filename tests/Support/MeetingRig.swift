import Foundation
import NarrariKit
import Synchronization
import Testing

// A meeting session on replayed audio, a fake screen watcher and test clocks, with no calendar event unless given and no processing.
@MainActor
final class MeetingRig {
    static let zoom = "us.zoom.xos"

    let folder = TemporaryFolder()
    let settings = ThrowawaySettings()
    let clock = TestClock()
    let screenClock = TestClock()
    let recorderClock = TestClock()
    let watcher = FakeScreenWatcher()
    let replay: Replay
    let disk: Disk
    let session: MeetingSession

    init(
        freeBytes: Int64 = 10_000_000_000, calendar: any CalendarSource = FakeCalendar(events: []),
        replay: Replay = Replay(microphone: speech(seconds: 1), system: [0]), system: (any SystemSoundSource)? = nil
    ) {
        self.replay = replay
        let disk = Disk(free: freeBytes)
        self.disk = disk
        let permissions = Permissions.fixed(settings: settings.store)
        session = MeetingSession(
            store: MeetingStore(root: folder.url, trash: { try FileManager.default.removeItem(at: $0) }),
            recorder: MeetingRecorder(
                settings: settings.store, permissions: permissions, inputs: replay, system: system ?? replay,
                freeSpace: { _ in disk.free.load(ordering: .relaxed) }, hostNow: { [replay] in replay.clock.hostTime },
                clock: recorderClock
            ),
            calls: CallDetector(processes: FakeProcesses(), settings: settings.store, clock: clock),
            calendar: CalendarLink(source: calendar, ownerName: "Mila Novak", settings: settings.store),
            screen: ScreenWatch(watcher: watcher, clock: screenClock),
            names: CallWindowNames(source: FakeCallWindows(), settings: settings.store, clock: clock, ownerName: "Mila Novak"),
            permissions: permissions, processor: nil, liveText: nil, settings: settings.store, clock: clock,
            appName: { _ in "zoom.us" }
        )
    }

    // The fake watcher's answer reaches the session at its next once-a-second look.
    func screen(isWatched: Bool) async {
        watcher.answer.withLock { $0 = isWatched }
        await screenClock.waitForSleepers(1)
        screenClock.advance(by: .seconds(1))
    }
}

// Plays a meeting through `output` in 100 ms steps, the recorder's checks on `clock` running at each second as they do live.
@MainActor
func record(_ seconds: Double, _ replay: Replay, _ output: FaultyOutput, checkedBy clock: TestClock) async {
    for _ in 0..<Int((seconds * 10).rounded()) {
        let second = Int(replay.clock.seconds)
        output.play(replay, seconds: 0.1)
        guard Int(replay.clock.seconds) > second else { continue }
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(1))
        await clock.waitForSleepers(1)
    }
}

// The free space a recorder sees; a test lowers it while recording.
final class Disk: Sendable {
    let free: Atomic<Int64>

    init(free: Int64 = 50_000_000_000) {
        self.free = Atomic(free)
    }
}

// The output device's tap gone wrong in the ways a real one can: frozen, so it delivers nothing, or reporting one rate and
// delivering another. Each engine it builds starts the way the source is set at that moment.
final class FaultyOutput: SystemSoundSource, Sendable {
    private struct State {
        var isFrozen = false
        var isSilent = false
        var hasFormat = true
        var reportedRate = 16_000.0
        var deliveredRate = 16_000.0
        var builds = 0
        var engine: FaultyEngine?
        var onChange: (@Sendable () -> Void)?
    }

    private let audio: [Float]
    private let clock: ReplayClock
    private let state = Mutex(State())

    init(audio: [Float], clock: ReplayClock) {
        self.audio = audio
        self.clock = clock
    }

    var builds: Int { state.withLock { $0.builds } }

    func makeEngine(onChange: @escaping @Sendable () -> Void) -> any InputEngine {
        state.withLock { state in
            let fast = (state.deliveredRate / state.reportedRate - 1) * 1_000_000
            let input = ReplayInput(audio: state.isSilent ? [0] : audio, clock: clock, sampleRate: state.reportedRate, partsPerMillionFast: fast)
            let engine = FaultyEngine(input, isFrozen: state.isFrozen, hasFormat: state.hasFormat)
            state.builds += 1
            state.engine = engine
            state.onChange = onChange
            return engine
        }
    }

    // Engines built from now on deliver at `delivered` per second while reporting `reported`.
    func run(reporting reported: Double, delivering delivered: Double? = nil) {
        state.withLock {
            $0.reportedRate = reported
            $0.deliveredRate = delivered ?? reported
        }
    }

    // Engines built from now on play silence, as a tap does when nothing plays or other apps' sound may not be recorded.
    func silence(_ isSilent: Bool) {
        state.withLock { $0.isSilent = isSilent }
    }

    // Engines built from now on have no format, as when no tap can be made.
    func failToBuild() {
        state.withLock { $0.hasFormat = false }
    }

    // The device changes rate, as a Bluetooth headset does when a call opens its microphone: the recorder is told at once.
    func change(to rate: Double) {
        run(reporting: rate)
        state.withLock { $0.onChange }?()
    }

    // The engine running now stops delivering; with `all`, every one built after it too, until thawed.
    func freeze(all: Bool = false) {
        state.withLock { state in
            state.isFrozen = all
            return state.engine
        }?.freeze()
    }

    func thaw() {
        state.withLock { state in
            state.isFrozen = false
            return state.engine
        }?.thaw()
    }

    // Plays the meeting's inputs and this output together, in 100 ms steps.
    func play(_ replay: Replay, seconds: Double) {
        for _ in 0..<Int((seconds * 10).rounded()) {
            replay.play(seconds: 0.1)
            state.withLock { $0.engine }?.input.catchUp()
        }
    }
}

final class FaultyEngine: InputEngine, Sendable {
    let input: ReplayInput
    private let feed = Mutex<(@Sendable (UnsafeBufferPointer<Float>, UInt64) -> Void)?>(nil)
    private let isFrozen: Atomic<Bool>
    private let hasFormat: Bool

    init(_ input: ReplayInput, isFrozen: Bool, hasFormat: Bool) {
        self.input = input
        self.isFrozen = Atomic(isFrozen)
        self.hasFormat = hasFormat
    }

    var sampleRate: Double? { hasFormat ? input.sampleRate : nil }

    func start(feeding feed: @escaping @Sendable (UnsafeBufferPointer<Float>, UInt64) -> Void) {
        self.feed.withLock { $0 = feed }
        if !isFrozen.load(ordering: .relaxed) { input.start(feeding: feed) }
    }

    func stop() {
        feed.withLock { $0 = nil }
        input.stop()
    }

    func freeze() {
        isFrozen.store(true, ordering: .relaxed)
        input.stop()
    }

    // Delivers again from now on, as a device does once its IO runs again.
    func thaw() {
        isFrozen.store(false, ordering: .relaxed)
        if let feed = feed.withLock({ $0 }) { input.start(feeding: feed) }
    }
}
