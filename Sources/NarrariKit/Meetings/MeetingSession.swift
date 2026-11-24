import AppKit
import Foundation
import Observation

// Takes a meeting once its recording has stopped: transcript, speakers, summary.
public protocol MeetingProcessor: Sendable {
    // Gets ready while a meeting records or a recording is read, so processing does not wait for downloads.
    func prepare() async
    func process(_ meeting: UUID) async
}

extension MeetingProcessing: MeetingProcessor {}

// The one owner of meeting state. A detected call is offered, or started when the setting says so; a recorded call
// stops 10 seconds after it ends unless the user keeps it. A meeting started by hand stops only by hand or when the Mac sleeps;
// a call's recording stopped by sleep is raised again on wake while the call goes on, as a new meeting.
@MainActor
@Observable
public final class MeetingSession: MeetingPresence {
    public enum State: Sendable, Equatable {
        case idle
        case offered(app: String)
        case recording
        case paused
        // Nothing live, a stopped meeting still being processed. A new call can still be offered and recorded.
        case processing
    }

    // Seconds left before a call that ended stops recording; nil when no countdown runs.
    public private(set) var stopCountdown: Int?
    public private(set) var startError: (any Error)?
    // The last meeting stopped by itself because the disk ran nearly full.
    public private(set) var stoppedForLowDisk = false
    // A track of the meeting recording now that is going wrong.
    public private(set) var trouble: RecordingTrouble?
    public private(set) var offeredTitle: String?
    // The meeting being recorded or paused.
    public private(set) var recordingID: UUID?
    // The meeting live text's lines are of; they outlast its recording until the next one starts.
    public private(set) var liveTextMeetingID: UUID?

    private var live = State.idle {
        didSet {
            screen.ask(live != .idle)
            if case .offered = live {} else { offeredTitle = nil }
        }
    }
    private var processing = 0

    @ObservationIgnored private let store: MeetingStore
    @ObservationIgnored private let recorder: MeetingRecorder
    @ObservationIgnored private let calls: CallDetector
    @ObservationIgnored private let calendar: CalendarLink
    @ObservationIgnored private let screen: ScreenWatch
    @ObservationIgnored private let names: CallWindowNames
    @ObservationIgnored private let permissions: Permissions
    @ObservationIgnored private let processor: (any MeetingProcessor)?
    // The meeting's words as spoken, while it records; nil when the app runs without live text.
    @ObservationIgnored public let liveText: LiveTranscript?
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let appName: @MainActor (String) -> String
    @ObservationIgnored private var meeting: Meeting?
    @ObservationIgnored private var countdown: Task<Void, Never>?
    // From Start until the recorder runs; a call's end or a Stop in that time waits for it instead of being lost.
    @ObservationIgnored private var starting: Task<Void, Never>?
    @ObservationIgnored private var following: [Task<Void, Never>] = []
    @ObservationIgnored private var sleptThroughCall = false

    private static let countdownSeconds = 10
    private static let shutdownLimit: Duration = .seconds(5)

    public init(
        store: MeetingStore, recorder: MeetingRecorder, calls: CallDetector, calendar: CalendarLink, screen: ScreenWatch, names: CallWindowNames,
        permissions: Permissions, processor: (any MeetingProcessor)?, liveText: LiveTranscript?, settings: SettingsStore,
        clock: any Clock<Duration>, appName: @escaping @MainActor (String) -> String
    ) {
        self.store = store
        self.recorder = recorder
        self.calls = calls
        self.calendar = calendar
        self.screen = screen
        self.names = names
        self.permissions = permissions
        self.processor = processor
        self.liveText = liveText
        self.settings = settings
        self.clock = clock
        self.appName = appName
        recorder.onLowDisk = { [weak self] recording in
            guard let self, let meeting else { return }
            stoppedForLowDisk = true
            Task { await self.finish(meeting, recording, stop: .lowDisk) }
        }
        recorder.onTrouble = { [weak self] in self?.trouble = $0 }
    }

    isolated deinit {
        following.forEach { $0.cancel() }
        countdown?.cancel()
    }

    public var state: State {
        live == .idle && processing > 0 ? .processing : live
    }

    // The app whose call the notice offers; nil while the screen is watched, so the offer waits until the watching stops.
    public var shownOffer: String? {
        guard case .offered(let app) = live, !isScreenWatched else { return nil }
        return app
    }

    public var isScreenWatched: Bool { live != .idle && screen.state == .watched }

    public var isMeetingUnderWay: Bool { live == .recording || live == .paused }

    public var recordedSeconds: Double { recorder.elapsed }

    // The microphone and the call's sound together.
    public var level: Float { max(recorder.microphoneLevel, recorder.systemLevel) }

    // Starts listening for calls and for the Mac going to sleep and waking.
    public func follow() {
        guard following.isEmpty else { return }
        let sleeps = NSWorkspace.shared.notificationCenter.updates(of: NSWorkspace.willSleepNotification)
        let wakes = NSWorkspace.shared.notificationCenter.updates(of: NSWorkspace.didWakeNotification)
        following = [
            Task { [weak self, calls] in
                await calls.start()
                for await call in calls.events { await self?.handle(call) }
            },
            Task { [weak self] in
                for await _ in sleeps { await self?.sleep() }
            },
            Task { [weak self] in
                for await _ in wakes { await self?.wake() }
            }
        ]
    }

    public func handle(_ call: CallEvent) async {
        await starting?.value
        switch (call, live) {
        case (.started(let app), .idle):
            if settings.value(MeetingsSettings.startsByItself) { await begin(.call, app: app) } else { await offer(app) }
        case (.started, .recording), (.started, .paused):
            keepRecording()
        case (.ended, .offered):
            live = .idle
        case (.ended, .recording), (.ended, .paused):
            guard meeting?.source == .call, settings.value(MeetingsSettings.stopsWithCall), countdown == nil else { return }
            startCountdown()
        default:
            break
        }
    }

    // Takes up the offered call, or records with no call at all.
    public func start() async {
        switch live {
        case .offered(let app): await begin(.call, app: app)
        case .idle: await begin(.manual, app: "")
        default: break
        }
    }

    public func toggle() async {
        if isMeetingUnderWay { await stop() } else { await start() }
    }

    public func dismissOffer() {
        guard case .offered = live else { return }
        live = .idle
    }

    public func pause() {
        guard live == .recording else { return }
        recorder.pause()
        live = .paused
    }

    public func resume() {
        guard live == .paused else { return }
        recorder.resume()
        live = .recording
    }

    public func keepRecording() {
        countdown?.cancel()
        countdown = nil
        stopCountdown = nil
    }

    public func stop() async {
        await stop(.asked)
    }

    private func stop(_ reason: Meeting.Stop) async {
        await starting?.value
        guard let meeting, let recording = recorder.stop() else { return }
        await finish(meeting, recording, stop: reason)
    }

    private func sleep() async {
        await starting?.value
        sleptThroughCall = meeting?.source == .call
        await stop(.sleep)
    }

    private func wake() async {
        guard sleptThroughCall else { return }
        sleptThroughCall = false
        await calls.lookAgain()
    }

    // On quit: the meeting is stopped and saved, waiting at most a few seconds so quitting never hangs.
    public func shutdown() async {
        do {
            try await withTimeLimit(Self.shutdownLimit, clock: clock) { await self.stop() }
        } catch {
            Log.event("shutdown-meeting-timed-out")
        }
    }

    private func offer(_ app: String) async {
        live = .offered(app: app)
        let title = await calendar.event(at: .now)?.title
        if live == .offered(app: app) { offeredTitle = title }
    }

    private func begin(_ source: Meeting.Source, app: String) async {
        live = .recording
        startError = nil
        stoppedForLowDisk = false
        let start = Task { await open(source, app: app) }
        starting = start
        await start.value
        starting = nil
    }

    private func open(_ source: Meeting.Source, app: String) async {
        let now = Date.now
        let event = await calendar.event(at: now)
        var meeting = Meeting(
            title: event?.title ?? "", startedAt: now, app: app, source: source,
            template: settings.value(MeetingsSettings.summaryTemplate), state: .recording
        )
        meeting.addAttendees(event?.attendees ?? [], from: .calendar)
        do {
            let folder = try await store.create(meeting, appName: app.isEmpty ? "" : appName(app))
            do {
                try recorder.start(in: folder)
            } catch {
                do {
                    try await store.delete(meeting.id)
                } catch {
                    Log.failure("meeting-start-discard", error: error)
                }
                throw error
            }
            if live == .paused { recorder.pause() }
            self.meeting = meeting
            recordingID = meeting.id
            if let processor { Task { await processor.prepare() } }
            liveTextMeetingID = meeting.id
            liveText?.start()
            names.start(app: app) { [weak self] found in await self?.heard(found) }
        } catch {
            Log.failure("meeting-start", error: error)
            startError = error
            live = .idle
        }
    }

    private func finish(_ started: Meeting, _ recording: MeetingRecording, stop: Meeting.Stop) async {
        keepRecording()
        meeting = nil
        recordingID = nil
        trouble = nil
        live = .idle
        await liveText?.stop()
        await names.stop()
        var done = started
        done.keep(recording, systemAudioWasAllowed: permissions.systemAudio == .allowed)
        if recording.heardSystemSound {
            permissions.record(.allowed)
        } else if started.source == .call {
            permissions.record(.silent)
        }
        done.state = .ready
        done.stop = stop
        // Calendar access given, or the event begun, while recording: the store renames the folder now it has stopped.
        if done.title.isEmpty, let event = await calendar.event(at: .now) {
            done.title = event.title
            done.addAttendees(event.attendees, from: .calendar)
        }
        do {
            try await store.save(done)
        } catch {
            Log.failure("meeting-save", error: error)
        }
        guard let processor else { return }
        processing += 1
        Task {
            await processor.process(done.id)
            processing -= 1
        }
    }

    private func heard(_ found: [String]) async {
        guard var meeting, meeting.addAttendees(found, from: .callWindow) else { return }
        self.meeting = meeting
        do {
            try await store.save(meeting)
        } catch {
            Log.failure("meeting-names-save", error: error)
        }
    }

    private func startCountdown() {
        stopCountdown = Self.countdownSeconds
        countdown = Task { [weak self, clock] in
            for left in stride(from: Self.countdownSeconds - 1, through: 0, by: -1) {
                guard (try? await clock.sleep(for: .seconds(1))) != nil else { return }
                self?.stopCountdown = left
            }
            self?.countdown = nil
            await self?.stop()
        }
    }
}
