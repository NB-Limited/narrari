import AVFoundation
import CoreAudio
import Foundation
import Synchronization

public enum MeetingRecorderError: Error, Equatable {
    case lowDisk
}

public struct MeetingRecording: Sendable, Equatable {
    public let duration: Duration
    // False when the system track got only silence: nothing played, or recording other apps' sound is not allowed.
    public let heardSystemSound: Bool
    // False when no tap delivered anything all meeting, because none could be built or started.
    public let systemDelivered: Bool
    // The share of each track padded or cut to hold it to the meeting's clock: sound lost, or sent at a rate not reported.
    public let microphoneLost: Double
    public let systemLost: Double
}

// Records a meeting into its folder as mic.caf, from the microphone dictation would use, and system.caf, from every
// sound the Mac plays but Narrari's own. Both tracks run on one clock, so a moment sits at the same place in each.
@MainActor
public final class MeetingRecorder: MeetingPresence {
    public typealias FreeSpace = @Sendable (URL) -> Int64?
    // Gets each track's audio as it is written, at 16 kHz, with its place in the meeting; runs on the recording's queue.
    public typealias Listener = @Sendable (TranscriptSegment.Track, UnsafeBufferPointer<Float>, Double) -> Void

    public static let volumeFreeSpace: FreeSpace = { url in
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    nonisolated static let startingFreeBytes: Int64 = 1_000_000_000
    nonisolated static let stoppingFreeBytes: Int64 = 200_000_000

    // Called after the disk ran low and the recording stopped by itself, its files kept.
    public var onLowDisk: ((MeetingRecording) -> Void)?
    // Called when a track goes wrong while recording and cannot be repaired, and with nil once it is healthy again.
    public var onTrouble: ((RecordingTrouble?) -> Void)?

    private let settings: SettingsStore
    private let permissions: Permissions
    private let inputs: any AudioInputs
    private let system: any SystemSoundSource
    private let freeSpace: FreeSpace
    private let hostNow: @Sendable () -> UInt64
    // Runs the track checks once a second.
    private let clock: any Clock<Duration>
    private var capture: Capture?
    private var listener: Listener?
    private var engines: [Track.Side: any InputEngine] = [:]
    private var watchdog: Task<Void, Never>?
    private var told: RecordingTrouble?

    public init(
        settings: SettingsStore, permissions: Permissions, inputs: any AudioInputs, system: any SystemSoundSource,
        freeSpace: @escaping FreeSpace, hostNow: @escaping @Sendable () -> UInt64, clock: any Clock<Duration>
    ) {
        self.settings = settings
        self.permissions = permissions
        self.inputs = inputs
        self.system = system
        self.freeSpace = freeSpace
        self.hostNow = hostNow
        self.clock = clock
    }

    // True from start to stop, paused or not.
    public var isMeetingUnderWay: Bool { capture != nil }

    public var microphoneLevel: Float { capture?.track(.microphone).level ?? 0 }

    public var systemLevel: Float { capture?.track(.system).level ?? 0 }

    // Seconds recorded so far, paused time left out; 0 when nothing records.
    public var elapsed: Double {
        guard let capture else { return 0 }
        let now = Self.seconds(hostNow())
        return capture.timeline.withLock { $0.recorded(at: now) }
    }

    public func listen(_ listener: Listener?) {
        self.listener = listener
        guard let capture else { return }
        capture.queue.async { capture.listener = listener }
    }

    public func start(in folder: URL) throws {
        guard capture == nil else { throw RecorderError.startFailed }
        try permissions.requireMicrophone()
        guard freeSpace(folder).map({ $0 >= Self.startingFreeBytes }) ?? true else {
            Log.event("meeting-refused-low-disk")
            throw MeetingRecorderError.lowDisk
        }
        guard let microphone = makeEngine(.microphone), let microphoneRate = microphone.sampleRate else {
            Log.failure("meeting-microphone-none")
            throw RecorderError.noInput
        }
        let capture = try Capture(
            folder: folder, start: Self.seconds(hostNow()), microphoneRate: microphoneRate, freeSpace: freeSpace,
            listener: listener, onLowDisk: Self.lowDisk(to: self)
        )
        do {
            try microphone.start(feeding: Self.feed(capture, .microphone, hostNow))
        } catch {
            Log.failure("meeting-microphone-start", error: error)
            capture.discard()
            throw RecorderError.startFailed
        }
        self.capture = capture
        engines[.microphone] = microphone
        begin(makeEngine(.system), for: .system, in: capture)
        watch(capture)
        Log.event("meeting-recording-started")
    }

    public func pause() {
        capture?.timeline.withLock { $0.pause(at: Self.seconds(hostNow())) }
    }

    public func resume() {
        capture?.timeline.withLock { $0.resume(at: Self.seconds(hostNow())) }
    }

    // Nil when nothing was recording.
    @discardableResult
    public func stop() -> MeetingRecording? {
        guard let capture else { return nil }
        let duration = capture.timeline.withLock { $0.end(at: Self.seconds(hostNow())) }
        watchdog?.cancel()
        watchdog = nil
        told = nil
        engines.values.forEach { $0.stop() }
        engines = [:]
        let recording = capture.queue.sync { capture.finish(at: duration) }
        self.capture = nil
        Log.event("meeting-recording-stopped")
        return recording
    }

    private func makeEngine(_ side: Track.Side) -> (any InputEngine)? {
        let onChange = Self.changed(side, to: self)
        switch side {
        case .microphone:
            let device = inputs.current(
                chosenUID: settings.value(DictationSettings.microphoneUID),
                prefersBuiltIn: settings.value(DictationSettings.prefersBuiltInOverBluetooth)
            )
            return device.map { inputs.makeEngine(for: $0, onChange: onChange) }
        case .system:
            return system.makeEngine(onChange: onChange)
        }
    }

    // A track whose input fails is kept as silence, so a meeting goes on with what it still hears, and its checks build it again.
    private func begin(_ engine: (any InputEngine)?, for side: Track.Side, in capture: Capture) {
        let now = Self.seconds(hostNow())
        var started: Double?
        if let engine, let rate = engine.sampleRate {
            capture.queue.async { capture.track(side).retarget(to: rate) }
            do {
                try engine.start(feeding: Self.feed(capture, side, hostNow))
                engines[side] = engine
                started = rate
            } catch {
                Log.failure("meeting-input-start", error: error)
            }
        } else if engine != nil {
            Log.failure("meeting-input-no-format")
        }
        capture.queue.async { [started] in capture.restarted(side, at: now, rate: started) }
    }

    // The microphone or the output changed, or a check found it failing: carry on from whichever is current now, as a dictation does.
    private func reconnect(_ side: Track.Side) {
        guard let capture else { return }
        engines.removeValue(forKey: side)?.stop()
        let engine = makeEngine(side)
        if engine == nil { Log.failure("meeting-input-lost") }
        begin(engine, for: side, in: capture)
        if engines[side] != nil { Log.event("meeting-input-reconnected") }
    }

    private func watch(_ capture: Capture) {
        watchdog = Task { [weak self, clock] in
            while (try? await clock.sleep(for: .seconds(1))) != nil {
                guard let self, self.capture === capture else { return }
                checkHealth(of: capture)
            }
        }
    }

    // Builds again what a rebuild may fix, and tells the first trouble left, stopped before poor, microphone before system.
    private func checkHealth(of capture: Capture) {
        let now = Self.seconds(hostNow())
        let (repairs, troubles) = capture.queue.sync { capture.checkHealth(at: now) }
        for side in repairs {
            Log.event(side == .microphone ? "meeting-microphone-rebuilt" : "meeting-system-rebuilt")
            reconnect(side)
        }
        let first = troubles.first { $0.kind == .stopped } ?? troubles.first
        guard first != told else { return }
        told = first
        if let first { Log.event(first.logName) }
        onTrouble?(first)
    }

    private func stopForLowDisk(_ flagged: Capture) {
        guard capture === flagged, let recording = stop() else { return }
        Log.event("meeting-stopped-low-disk")
        onLowDisk?(recording)
    }

    private nonisolated static func seconds(_ hostTime: UInt64) -> Double {
        AVAudioTime.seconds(forHostTime: hostTime)
    }

    // Built outside the main actor: the feed runs on the IO thread, and a closure made here would assert it is on main.
    private nonisolated static func feed(
        _ capture: Capture, _ side: Track.Side, _ hostNow: @escaping @Sendable () -> UInt64
    ) -> @Sendable (UnsafeBufferPointer<Float>, UInt64) -> Void {
        { samples, hostTime in
            let time = seconds(hostTime != 0 ? hostTime : hostNow())
            let copy = Array(samples)
            capture.queue.async { capture.take(copy, at: time, into: side) }
        }
    }

    private nonisolated static func changed(_ side: Track.Side, to recorder: MeetingRecorder) -> @Sendable () -> Void {
        { [weak recorder] in MainActor.assumeIsolated { recorder?.reconnect(side) } }
    }

    private nonisolated static func lowDisk(to recorder: MeetingRecorder) -> @Sendable (Capture) -> Void {
        { [weak recorder] capture in
            DispatchQueue.main.async { MainActor.assumeIsolated { recorder?.stopForLowDisk(capture) } }
        }
    }
}

extension RecordingTrouble {
    fileprivate var logName: StaticString {
        switch (track, kind) {
        case (.mic, .stopped): "meeting-microphone-told-stopped"
        case (.mic, .poor): "meeting-microphone-told-poor"
        case (.system, .stopped): "meeting-system-told-stopped"
        case (.system, .poor): "meeting-system-told-poor"
        }
    }
}

// One recording's tracks. The timeline is shared with main; everything else is touched on `queue` only.
private final class Capture: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.nb-limited.narrari.meeting")
    let timeline: Mutex<Timeline>
    var listener: MeetingRecorder.Listener?
    private let microphone: Track
    private let system: Track
    private let folder: URL
    private let freeSpace: MeetingRecorder.FreeSpace
    private let onLowDisk: @Sendable (Capture) -> Void
    private var nextDiskCheck = 0.0
    private var isLowOnDisk = false
    private var health: [Track.Side: TrackHealth]

    private static let diskCheckSeconds = 5.0

    init(
        folder: URL, start: Double, microphoneRate: Double, freeSpace: @escaping MeetingRecorder.FreeSpace,
        listener: MeetingRecorder.Listener?, onLowDisk: @escaping @Sendable (Capture) -> Void
    ) throws {
        microphone = try Track(writingTo: folder.appending(path: MeetingStore.Audio.microphone.rawValue), rate: microphoneRate)
        do {
            system = try Track(writingTo: folder.appending(path: MeetingStore.Audio.system.rawValue), rate: SpeechAudio.sampleRate)
        } catch {
            microphone.discard()
            throw error
        }
        self.folder = folder
        self.freeSpace = freeSpace
        self.listener = listener
        self.onLowDisk = onLowDisk
        timeline = Mutex(Timeline(start: start))
        health = [.microphone: TrackHealth(at: start, rate: microphoneRate), .system: TrackHealth(at: start, rate: nil)]
    }

    func track(_ side: Track.Side) -> Track {
        switch side {
        case .microphone: microphone
        case .system: system
        }
    }

    func take(_ samples: [Float], at time: Double, into side: Track.Side) {
        health[side]?.delivered(samples.count, at: time)
        let track = track(side)
        guard let part = timeline.withLock({ $0.place(time, frames: samples.count, rate: track.rate) }) else { return }
        let listener = listener
        samples[part.frames].withUnsafeBufferPointer { samples in
            track.write(samples, at: part.position) { listener?(side.segmentTrack, $0, part.position) }
        }
        checkDisk(at: part.position)
    }

    func restarted(_ side: Track.Side, at time: Double, rate: Double?) {
        health[side]?.restarted(at: time, rate: rate)
    }

    // The tracks whose engine should be built again, and the trouble each track has now.
    func checkHealth(at now: Double) -> (repairs: [Track.Side], troubles: [RecordingTrouble]) {
        var repairs: [Track.Side] = []
        for side in [Track.Side.microphone, .system] {
            let writer = track(side).writer
            if health[side]?.check(at: now, length: writer.length, corrected: writer.corrected) == true { repairs.append(side) }
        }
        let troubles = [Track.Side.microphone, .system].compactMap { side in
            health[side]?.trouble.map { RecordingTrouble(track: side.segmentTrack, kind: $0) }
        }
        return (repairs, troubles)
    }

    func finish(at duration: Double) -> MeetingRecording {
        [microphone, system].forEach { $0.writer.finish(at: duration) }
        let lost = (microphone: microphone.writer.correctedShare, system: system.writer.correctedShare)
        Log.count("meeting-microphone-corrected-percent", Int((100 * lost.microphone).rounded()))
        Log.count("meeting-system-corrected-percent", Int((100 * lost.system).rounded()))
        return MeetingRecording(
            duration: .seconds(duration), heardSystemSound: system.hasHeardSound, systemDelivered: health[.system]?.hasDelivered == true,
            microphoneLost: lost.microphone, systemLost: lost.system
        )
    }

    func discard() {
        [microphone, system].forEach { $0.discard() }
    }

    private func checkDisk(at position: Double) {
        guard position >= nextDiskCheck, !isLowOnDisk else { return }
        nextDiskCheck = position + Self.diskCheckSeconds
        guard let free = freeSpace(folder), free < MeetingRecorder.stoppingFreeBytes else { return }
        isLowOnDisk = true
        onLowDisk(self)
    }
}

// One track's file and readings. `rate` and the writer belong to the capture's queue; the readings are read from main.
private final class Track: @unchecked Sendable {
    enum Side: Hashable, Sendable {
        case microphone
        case system

        var segmentTrack: TranscriptSegment.Track {
            switch self {
            case .microphone: .mic
            case .system: .system
            }
        }
    }

    let writer: TrackWriter
    private(set) var rate: Double
    private let url: URL
    private let levelBits = Atomic<UInt32>(0)
    private let heardSound = Atomic<Bool>(false)

    init(writingTo url: URL, rate: Double) throws {
        do {
            writer = try TrackWriter(writingTo: url, sourceRate: rate)
        } catch {
            Log.failure("meeting-track-create", error: error)
            throw RecorderError.startFailed
        }
        self.rate = rate
        self.url = url
    }

    var level: Float { Float(bitPattern: levelBits.load(ordering: .relaxed)) }

    var hasHeardSound: Bool { heardSound.load(ordering: .relaxed) }

    func retarget(to rate: Double) {
        guard rate != self.rate else { return }
        do {
            try writer.retarget(to: rate)
            self.rate = rate
        } catch {
            Log.failure("meeting-track-retarget", error: error)
        }
    }

    func write(_ samples: UnsafeBufferPointer<Float>, at position: Double, then hear: (UnsafeBufferPointer<Float>) -> Void) {
        writer.append(samples, at: position, then: hear)
        let decibels = SoundLevel.decibels(of: samples)
        levelBits.store(SoundLevel.meter(decibels).bitPattern, ordering: .relaxed)
        if SoundLevel.isSound(decibels) { heardSound.store(true, ordering: .relaxed) }
    }

    func discard() {
        writer.finish(at: 0)
        try? FileManager.default.removeItem(at: url)
    }
}

// The meeting's clock, in host seconds. Paused spans are cut out, so a track's position is time recorded, not time passed.
private struct Timeline {
    let start: Double
    private var spans: [ClosedRange<Double>] = []
    // Set while paused and from the stop on; a buffer reaching past it is cut there.
    private var closedAt: Double?

    init(start: Double) {
        self.start = start
    }

    // Where a buffer stamped `time` lands, and which of its frames are kept; nil when none are.
    func place(_ time: Double, frames: Int, rate: Double) -> (position: Double, frames: Range<Int>)? {
        let first = time < start ? min(Int(((start - time) * rate).rounded(.up)), frames) : 0
        let end = closedAt.map { min(frames, Int((($0 - time) * rate).rounded())) } ?? frames
        guard end > first else { return nil }
        let at = time + Double(first) / rate
        var cut = 0.0
        for span in spans {
            if at >= span.upperBound {
                cut += span.upperBound - span.lowerBound
            } else if at >= span.lowerBound {
                return nil
            }
        }
        return (at - start - cut, first..<end)
    }

    mutating func pause(at time: Double) {
        guard closedAt == nil else { return }
        closedAt = time
    }

    mutating func resume(at time: Double) {
        guard let closedAt else { return }
        spans.append(closedAt...max(time, closedAt))
        self.closedAt = nil
    }

    func recorded(at time: Double) -> Double {
        max(0, (closedAt ?? time) - start - spans.reduce(0) { $0 + $1.upperBound - $1.lowerBound })
    }

    // The seconds recorded, paused time left out.
    mutating func end(at time: Double) -> Double {
        let seconds = recorded(at: time)
        closedAt = closedAt ?? time
        return seconds
    }
}
