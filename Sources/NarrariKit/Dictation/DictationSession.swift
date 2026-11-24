import AppKit
import Foundation
import Observation

@MainActor
@Observable
public final class DictationSession {
    public enum Phase: Sendable, Equatable {
        case idle
        case recording
        case transcribing
        case cleaning
        case pasting
    }

    public internal(set) var phase = Phase.idle
    public internal(set) var isListening = false
    public internal(set) var notice: Notice?
    public internal(set) var liveText = ""
    // The microphone's name while it has delivered nothing since the dictation started.
    public internal(set) var silentMicrophone: String?
    public internal(set) var isDone = false
    public internal(set) var modeChoice = ModeChoice(app: "", modes: [], current: .dictation)
    public var modelState: ModelState { modelStatus.state }
    // Yields once a dictation's open line and its final line are on disk, so history views can read them.
    public let historyChanges: AsyncStream<Void>

    public var isModelLoading: Bool {
        if case .preparing = modelState { return true }
        return false
    }

    // What the dictation does once its recording stops.
    public var work: WorkState {
        switch phase {
        case .transcribing where isModelLoading: .waiting(.speechModel)
        case .transcribing, .pasting: .working(.transcribing)
        case .cleaning: .working(.cleaningUp)
        case .idle, .recording: isDone ? .done : .idle
        }
    }

    // From the press until the dictation ends; history deletions leave this one alone.
    public var activeDictationID: UUID? { dictation?.id }

    // Not observed: the pill samples these on its own beat while recording.
    public var inputLevel: Float { recorder.level }
    public var recordingSeconds: TimeInterval { dictation.map { now() - $0.began } ?? 0 }

    public var showsPill: Bool {
        isListening || notice != nil || isDone || (phase != .idle && phase != .recording)
    }

    enum StartSource {
        case hotkey
        case menu
    }

    enum Outcome {
        case pasted
        case copied
        case discarded
        case failed
    }

    struct Dictation {
        let id: UUID
        let startedAt: Date
        let app: String
        let modeName: String
        let began: TimeInterval
        let prompt: Prompt
        let isCleanupOn: Bool
        let transcriber: any Transcriber
        var isCleanupFlipped = false
        var isConfirmed = false
        var isHandsFree = false
        var durationMs = 0
        var audioProblem: Problem?

        var cleanup: CleanupSwitch {
            if isCleanupOn != isCleanupFlipped { return .on }
            return .off(isCleanupFlipped ? .hotkey : .switchedOff)
        }
    }

    @ObservationIgnored var gesture: HotkeyGesture
    @ObservationIgnored let hotkeys: any HotkeySource
    @ObservationIgnored let recorder: any AudioCapture
    @ObservationIgnored let transcriber: any Transcriber
    // Built for each dictation that uses it, so a changed address, model or key applies at once.
    @ObservationIgnored let outsideTranscriber: @MainActor () -> (any Transcriber)?
    @ObservationIgnored let modelStatus: ModelStatus
    @ObservationIgnored let livePreview: LivePreview
    @ObservationIgnored let pipeline: TextPipeline
    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored let paster: Paster
    @ObservationIgnored let media: any OutputMuting
    @ObservationIgnored let sounds: any SoundPlaying
    @ObservationIgnored let history: HistoryStore
    @ObservationIgnored let modes: ModeStore
    @ObservationIgnored let now: () -> TimeInterval
    @ObservationIgnored let clock: any Clock<Duration>
    @ObservationIgnored let frontmostApp: @MainActor () -> String?
    @ObservationIgnored let ownApp: String?
    @ObservationIgnored var lastOutsideApp: String?
    @ObservationIgnored let timing: @MainActor () -> HotkeyGesture.Timing
    @ObservationIgnored var resolver = ModeResolver()
    @ObservationIgnored var dictation: Dictation?
    @ObservationIgnored var delivery: Task<Void, Never>?
    @ObservationIgnored var stopStep: (@MainActor () -> Void)?
    @ObservationIgnored var historyWrites: Task<Void, Never>?
    @ObservationIgnored var feedback: Task<Void, Never>?
    @ObservationIgnored var noticeExpiry: Task<Void, Never>?
    @ObservationIgnored var doneExpiry: Task<Void, Never>?
    @ObservationIgnored var silenceWatch: Task<Void, Never>?
    @ObservationIgnored let historyChangeSink: AsyncStream<Void>.Continuation

    static let noticeDuration: Duration = .milliseconds(2500)
    public nonisolated static let doneHold: Duration = .milliseconds(700)
    private static let shutdownDeliveryLimit: Duration = .seconds(5)

    public init(
        hotkeys: any HotkeySource,
        recorder: any AudioCapture,
        transcriber: any Transcriber,
        outsideTranscriber: @escaping @MainActor () -> (any Transcriber)? = { nil },
        modelStatus: ModelStatus = ModelStatus(),
        livePreview: LivePreview,
        pipeline: TextPipeline,
        paster: Paster,
        media: any OutputMuting,
        sounds: any SoundPlaying,
        history: HistoryStore,
        modes: ModeStore,
        settings: SettingsStore,
        timing: (@MainActor () -> HotkeyGesture.Timing)? = nil,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        clock: any Clock<Duration> = ContinuousClock(),
        frontmostApp: @escaping @MainActor () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
        ownApp: String? = Bundle.main.bundleIdentifier
    ) {
        let timing = timing ?? { HotkeyGesture.Timing(settings: settings) }
        self.timing = timing
        gesture = HotkeyGesture(timing: timing())
        (historyChanges, historyChangeSink) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.hotkeys = hotkeys
        self.recorder = recorder
        self.transcriber = transcriber
        self.outsideTranscriber = outsideTranscriber
        self.modelStatus = modelStatus
        self.livePreview = livePreview
        self.pipeline = pipeline
        self.settings = settings
        self.paster = paster
        self.media = media
        self.sounds = sounds
        self.history = history
        self.modes = modes
        self.now = now
        self.clock = clock
        self.frontmostApp = frontmostApp
        self.ownApp = ownApp
        hotkeys.onInput = { [weak self] input, time in self?.handle(input, at: time) }
        recorder.onInterruption = { [weak self] in self?.microphoneLost() }
        recorder.onSwitch = { [weak self] name in self?.microphoneSwitched(to: name) }
        recorder.onFirstSound = { [weak self] in self?.soundArrived() }
    }

    public func handle(_ input: HotkeyGesture.Input, at time: TimeInterval) {
        if input == .escape, let stopStep { return stopStep() }
        if case .hotkeyDown = input { readTimingIfIdle() }
        perform(gesture.handle(input, at: time), at: time, from: .hotkey)
        noteHandsFree()
    }

    public func toggleFromMenu() {
        if work == .waiting(.speechModel), let stopStep { return stopStep() }
        readTimingIfIdle()
        let time = now()
        perform(gesture.toggle(at: time), at: time, from: .menu)
        noteHandsFree()
    }

    private func noteHandsFree() {
        guard gesture.isHandsFree, dictation?.isHandsFree == false else { return }
        dictation?.isHandsFree = true
    }

    // A changed timing waits for the next dictation; the one in progress keeps the timing it started with.
    private func readTimingIfIdle() {
        guard phase == .idle else { return }
        gesture.timing = timing()
    }

    public func shutdown() async {
        if phase == .recording {
            gesture.reset()
            hotkeys.setRecordingKeys(.off)
            _ = stopRecorder()
            markRecordingEnded()
            endFeedback(playingStopSound: false)
            finish(.failed)
        }
        if let delivery {
            do {
                try await withTimeLimit(Self.shutdownDeliveryLimit, clock: clock) { await delivery.value }
            } catch {
                Log.event("shutdown-delivery-timed-out")
            }
        }
        await feedback?.value
        await historyWrites?.value
        await paster.finishRestore()
    }

    private func perform(_ actions: [HotkeyGesture.Action], at time: TimeInterval, from source: StartSource) {
        for action in actions {
            switch action {
            case .begin: begin(from: source)
            case .confirm: confirm()
            case .stop: stop(releasedAt: time)
            case .discard(let cause): discard(cause)
            case .toggleCleanup: toggleCleanup()
            }
        }
    }

    private func begin(from source: StartSource) {
        guard phase == .idle else {
            gesture.reset()
            Task { await sounds.play(.ignored) }
            return
        }
        isDone = false
        let id = UUID()
        let audioFile = history.audioURL(for: id)
        do {
            try recorder.start(writingTo: audioFile)
        } catch {
            gesture.reset()
            microphoneFailed(error)
            return
        }
        switch source {
        case .hotkey: Log.event("dictation-start-hotkey")
        case .menu: Log.event("dictation-start-menu")
        }
        let app = dictatedApp()
        let mode = modeChoices(for: app)
        dictation = Dictation(
            id: id, startedAt: Date(), app: app, modeName: mode.name, began: now(),
            prompt: mode.prompt, isCleanupOn: mode.isCleanupOn, transcriber: mode.transcriber
        )
        phase = .recording
        watchForSilence()
        settings.value(PillSettings.look).logForDictation()
        hotkeys.setRecordingKeys(.escapeAndCleanupToggle)
        pipeline.holdCleanupModel()

        let window = gesture.timing.shortcutWindow
        Task { [weak self, clock] in
            try? await clock.sleep(for: .seconds(window))
            guard let self else { return }
            handle(.tick, at: now())
        }
    }

    private func confirm() {
        guard phase == .recording, !isListening else { return }
        isListening = true
        dictation?.isConfirmed = true
        clearError()
        if let dictation {
            record(entry(for: dictation, audioFile: HistoryEntry.audioFileName(for: dictation.id)))
            announceHistoryChange()
        }
        if case .failed = modelState { show(.speech(.modelUnavailable)) }
        paster.saveClipboard()
        startLivePreview()
        queueFeedback { [sounds, media] in
            await sounds.play(.start)
            // An output Narrari could not mute is said on the General page, never in the pill.
            await media.muteOutput()
        }
    }

    // Always the speech model on this Mac, also when an outside service makes the final transcript.
    private func startLivePreview() {
        guard settings.value(DictationSettings.showsLiveText), modelState == .ready else { return }
        livePreview.start(reading: { [recorder] in recorder.recentSamples($0) }, publish: { [weak self] window in
            guard let self else { return }
            liveText = Caption.merge(liveText, window: window)
        })
    }

    private func toggleCleanup() {
        guard phase == .recording, dictation != nil else { return }
        dictation?.isCleanupFlipped.toggle()
        show(dictation?.cleanup == .on ? .cleanupOn : .cleanupOff)
    }

    private func stop(releasedAt time: TimeInterval) {
        guard phase == .recording, let dictation else { return }
        if dictation.isHandsFree { Log.event("dictation-stop-hands-free") } else { Log.event("dictation-stop-held") }
        hotkeys.setRecordingKeys(.off)
        let samples = stopRecorder()
        markRecordingEnded()
        endFeedback(playingStopSound: true)
        phase = .transcribing
        delivery = Task { await deliver(samples, for: dictation, releasedAt: time) }
    }

    private func discard(_ cause: HotkeyGesture.DiscardCause) {
        guard phase == .recording, let dictation else { return }
        switch cause {
        case .escape: Log.event("discard-escape")
        case .shortcutKey: Log.event("discard-shortcut-key")
        case .shortcut: Log.event("discard-shortcut")
        case .keyWhileHeld: Log.event("discard-key-while-held")
        case .tooShort: Log.event("discard-too-short")
        }
        hotkeys.setRecordingKeys(.off)
        _ = stopRecorder()
        markRecordingEnded()
        endFeedback(playingStopSound: false)
        // A Narrari shortcut pressed with the dictation key is what the user meant, so it ends without a word or a sound.
        if dictation.isConfirmed, cause != .shortcut {
            show(.discarded)
            queueFeedback { [sounds] in await sounds.play(.ignored) }
        }
        finish(.discarded)
    }

    private func microphoneLost() {
        guard phase == .recording else { return }
        show(.microphoneDisconnected)
        gesture.reset()
        stop(releasedAt: now())
    }

    private func microphoneSwitched(to name: String?) {
        guard phase == .recording else { return }
        show(.microphoneSwitched(name))
        if !recorder.hasHeardSound { watchForSilence() }
    }

    // Every sample goes to the transcript; a kept file the disk cut short is marked on the dictation.
    private func stopRecorder() -> [Float] {
        let recorded = recorder.stop()
        dictation?.audioProblem = recorded.problem
        return recorded.samples
    }

    private func markRecordingEnded() {
        livePreview.stop()
        endSilenceWatch()
        guard let began = dictation?.began else { return }
        dictation?.durationMs = Int((now() - began) * 1000)
    }
}
