import AppKit
import NarrariKit
import SwiftUI

@main
struct NarrariApp: App {
    // With a command word in its arguments the executable is the narrari command; it prints and exits before any of the app starts.
    static func main() {
        guard let command = Command(arguments: Array(CommandLine.arguments.dropFirst())) else { return startApp() }
        Command.reopenInsideBundle()
        Task {
            let reply = await command.run(in: Command.Context(
                settings: .shared, models: .shared, history: HistoryStore(root: AppPaths.history),
                meetings: MeetingStore(root: AppPaths.meetings, trash: MeetingStore.moveToTrash), apps: .shared,
                dataFolder: AppPaths.applicationSupport, dictionary: .shared, prompts: .shared, modes: .shared,
                templates: AppDelegate.summaryTemplates, voices: VoiceMemory(folder: AppPaths.applicationSupport),
                announce: SettingsChanges.postOutside
            ))
            FileHandle.standardOutput.write(Data(reply.output.utf8))
            FileHandle.standardError.write(Data(reply.errors.utf8))
            exit(reply.status)
        }
        dispatchMain()
    }

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // The menu bar panel and every window are AppKit; a scene is still required, so an empty Settings with no menu item.
    var body: some Scene {
        Settings { EmptyView() }
            .commands { CommandGroup(replacing: .appSettings) {} }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotkeys: HotkeyMonitor
    private let session: DictationSession
    private let library: HistoryLibrary
    private let permissions: Permissions
    private let playback = AudioPlayback()
    private let meetings = MeetingStore(root: AppPaths.meetings, trash: MeetingStore.moveToTrash)
    private let fileJob: FileJob
    private let aboutPanel = AboutPanel()
    private var mainWindow: MainWindow?
    private let speechModels: SpeechModelControl
    private let cleanupEngines: CleanupEngineSlot
    private let vocabulary: Vocabulary
    private let vocabularyStatus = ModelStatus()
    private let retention: RetentionSchedule
    private let media: MediaControl
    private let history: HistoryStore
    private let sounds: Sounds
    private let motion = ReduceMotion.shared
    private let meeting: MeetingSession
    private lazy var meetingLibrary = MeetingLibrary(
        store: meetings, processor: meetingProcessing, models: meetingModels, progress: transcriptProgress, settings: .shared
    ) { [meeting] in
        meeting.recordingID
    }
    private let meetingProcessing: MeetingProcessing
    private let meetingModels: MeetingModels
    private let transcriptProgress = MeetingTranscript.Progress()
    private let voiceMemory = VoiceMemory(folder: AppPaths.applicationSupport)
    private let looks = PillLookModel(settings: .shared)
    private let settingsMirror = SettingsMirror(.shared)
    private var pill: RecorderPill?
    private var meetingChip: MeetingChip?
    private var callNotice: CallNotice?
    private var menuPanel: MenuPanelController?

    override init() {
        let permissions = Permissions.onThisMac(settings: .shared)
        let hotkeys = HotkeyMonitor(settings: .shared, permissions: permissions)
        let speechStatus = ModelStatus()
        let vocabulary = Vocabulary(store: .shared, settings: .shared, onStateChange: vocabularyStatus.report)
        let local = ParakeetTranscriber(store: .shared, settings: .shared, vocabulary: vocabulary, onStateChange: speechStatus.report)
        // Its own model instance, so a preview pass never queues in front of the final transcription.
        let livePreview = LivePreview(transcriber: ParakeetTranscriber(store: .shared, settings: .shared, downloadsIfMissing: false))
        let cleanupEngines = CleanupEngineSlot(settings: .shared, keychain: Keychain.narrari, store: .shared)
        let pipeline = TextPipeline(cleanup: CleanupService(slot: cleanupEngines, settings: .shared), prompts: .shared, dictionary: .shared, settings: .shared)
        let (summary, dictating) = Self.summaries(engines: cleanupEngines)
        meetingModels = Self.meetingModels(speech: local, status: speechStatus, cleanup: cleanupEngines)
        meetingProcessing = Self.meetingProcessing(
            store: meetings, pipeline: pipeline, memory: voiceMemory, summary: summary, models: meetingModels, progress: transcriptProgress
        )
        meeting = Self.meetingSession(store: meetings, permissions: permissions, processing: meetingProcessing)
        media = MediaControl(settings: .shared, meeting: meeting)
        history = HistoryStore(root: AppPaths.history)
        sounds = Sounds(settings: .shared)
        self.permissions = permissions
        self.hotkeys = hotkeys
        speechModels = SpeechModelControl(
            local: local, livePreview: livePreview, status: speechStatus, store: .shared, settings: .shared, vocabulary: vocabulary,
            dictionary: .shared
        )
        self.cleanupEngines = cleanupEngines
        self.vocabulary = vocabulary
        let session = DictationSession(
            hotkeys: hotkeys, recorder: MicRecorder(settings: .shared, permissions: permissions), transcriber: local,
            outsideTranscriber: {
                RemoteTranscriber(settings: .shared, keychain: Keychain.narrari, dictionary: .shared)
                    .map { FallbackTranscriber(primary: $0, fallback: local) }
            },
            modelStatus: speechStatus, livePreview: livePreview, pipeline: pipeline, paster: Paster(settings: .shared),
            media: media, sounds: sounds, history: history, modes: .shared, settings: .shared
        )
        self.session = session
        dictating.session = session
        let retranscription = Retranscription(
            history: history, pipeline: pipeline, transcription: FileTranscription(store: .shared, settings: .shared, dictionary: .shared),
            modes: .shared, settings: .shared
        )
        let library = HistoryLibrary(
            store: history, retranscription: retranscription, apps: .shared, activeDictation: { session.activeDictationID }
        )
        self.library = library
        retention = RetentionSchedule(
            store: history, meetings: meetings, settings: .shared,
            activeDictation: { session.activeDictationID }, onRemoved: { await library.refresh() }
        )
        fileJob = FileJob(library: library, retranscription: retranscription) { session.modelState == .ready }
        super.init()
    }

    private static let templatesURL = AppPaths.applicationSupport.appending(path: "Templates", directoryHint: .isDirectory)
    fileprivate static let summaryTemplates = SummaryTemplateFolder(url: templatesURL, builtIns: SummaryTemplateFolder.bundled)

    // The watch is handed the dictation session once that exists, because the session needs the meeting first.
    private static func summaries(engines: CleanupEngineSlot) -> (SummaryService, DictationWatch) {
        let dictating = DictationWatch()
        let service = SummaryService(
            templates: summaryTemplates,
            engines: CleanupSummaryEngines(slot: engines, settings: .shared, keychain: Keychain.narrari, store: .shared),
            dictation: dictating, settings: .shared, clock: ContinuousClock()
        )
        return (service, dictating)
    }

    private static func meetingSession(store: MeetingStore, permissions: Permissions, processing: MeetingProcessing) -> MeetingSession {
        let recorder = MeetingRecorder(
            settings: .shared, permissions: permissions, inputs: SystemAudioInputs(), system: SystemAudioCapture(),
            freeSpace: MeetingRecorder.volumeFreeSpace, hostNow: mach_absolute_time, clock: ContinuousClock()
        )
        return MeetingSession(
            store: store, recorder: recorder,
            calls: CallDetector(processes: SystemAudioProcesses(), settings: .shared, clock: ContinuousClock()),
            calendar: CalendarLink(source: EventKitCalendar()),
            screen: ScreenWatch(watcher: SkyLightScreenWatcher(), clock: ContinuousClock()),
            names: CallWindowNames(source: AccessibilityCallWindows(), settings: .shared, clock: ContinuousClock(), ownerName: NSFullUserName()),
            permissions: permissions, processor: processing,
            liveText: LiveTranscript(recorder: recorder, speech: ParakeetLiveSpeech(store: .shared, settings: .shared), settings: .shared),
            settings: .shared, clock: ContinuousClock(), appName: { AppDirectory.shared.name(for: $0) }
        )
    }

    // The speech and clean-up models are dictation's, so a step waiting for one shows the download their pages start.
    private static func meetingModels(speech: ParakeetTranscriber, status: ModelStatus, cleanup: CleanupEngineSlot) -> MeetingModels {
        MeetingModels(
            store: .shared, fetch: { model, progress in try await model.download(into: .shared, progress: progress) },
            speech: .speech(speech, status: status, store: .shared, settings: .shared), cleanup: .cleanup(cleanup, store: .shared)
        )
    }

    // Every step after a meeting, in one place; people.json sits in the data folder beside the meetings.
    private static func meetingProcessing(
        store: MeetingStore, pipeline: TextPipeline, memory: VoiceMemory, summary: SummaryService, models: MeetingModels,
        progress: MeetingTranscript.Progress
    ) -> MeetingProcessing {
        let transcription = FileTranscription(store: .shared, settings: .shared, dictionary: .shared)
        return MeetingProcessing(
            store: store, echo: EchoRemoval(models: .shared),
            transcript: MeetingTranscript(
                transcribe: { try await transcription.run($0, upTo: nil, progress: $1) }, pipeline: pipeline, ownerName: NSFullUserName(),
                modelName: { transcription.modelName }, progress: progress
            ),
            speakers: MeetingSpeakers(models: .shared, memory: memory, pipeline: pipeline, settings: .shared, ownerName: NSFullUserName()),
            summary: summary, models: models
        )
    }

    private func perform(_ action: MenuPanelAction) {
        switch action {
        case .toggleDictation: session.toggleFromMenu()
        case .toggleMeeting: Task { await meeting.toggle() }
        case .pauseOrResumeMeeting: meeting.state == .paused ? meeting.resume() : meeting.pause()
        case .openMain: showMain(mainWindow?.route.list ?? .history)
        case .transcribeFile: chooseFile()
        case .importRecording: chooseRecording()
        case .openSettings: showSettings()
        case .openPermissions: showMain(.settings(.permissions))
        case .showAbout: aboutPanel.show()
        case .quit: NSApplication.shared.terminate(nil)
        case .allowAccessibility: permissions.requestAccessibility()
        case .allowMicrophone: permissions.requestMicrophone()
        case .openSpeechSettings: showMain(.settings(.speech))
        case .open(.meeting(let id)): openMeeting(id)
        case .open(.dictation(let id)):
            library.selection = id
            showMain(.history)
        case .open(.dictations): showMain(.history)
        }
    }

    private func showMain(_ page: MainRoute.Page? = nil) {
        let window = mainWindow ?? makeMainWindow()
        mainWindow = window
        window.show(page)
    }

    // Settings opens on the page last shown there.
    private func showSettings() {
        showMain(.settings(mainWindow?.route.lastSettings ?? .general))
    }

    private func makeMainWindow() -> MainWindow {
        let settings = makeSettingsModels()
        let meetings = meetingPageContext()
        let content = { [weak self, library, fileJob, playback, permissions, aboutPanel, motion, session] (route: MainRoute) in
            MainView(
                route: route, library: library, meetings: meetings, fileJob: fileJob, playback: playback, permissions: permissions,
                settings: settings, speechModel: { session.modelState },
                onAbout: { aboutPanel.show() },
                onTranscribeFile: { self?.chooseFile() },
                onDropFiles: { [weak self] urls in self?.transcribe(urls) },
                onImport: { self?.chooseRecording() },
                onDropRecordings: { [weak self] urls in self?.importRecordings(urls) }
            )
            .followsMotion(motion)
        }
        return MainWindow(onClose: { [playback] in playback.stop() }, content: content)
    }

    private static var templateChoices: [(id: String, title: String)] {
        ((try? summaryTemplates.all()) ?? []).map { ($0.id, $0.name) }
    }

    private func meetingPageContext() -> MeetingPageContext {
        let renaming = SpeakerRenaming(store: meetings, memory: voiceMemory, settings: .shared)
        return MeetingPageContext(
            library: meetingLibrary, session: meeting, playback: playback, apps: .shared, templates: { Self.templateChoices },
            summaryModels: SummaryModels(settings: .shared, store: .shared),
            makePage: { [meetings, meetingProcessing, meetingModels, transcriptProgress, voiceMemory] meeting, query in
                MeetingPage(
                    meeting: meeting, store: meetings, processing: meetingProcessing, models: meetingModels, progress: transcriptProgress,
                    renaming: renaming, memory: voiceMemory, settings: .shared, query: query
                )
            }
        )
    }

    private func makeSettingsModels() -> SettingsModels {
        SettingsModels(
            general: GeneralPageModel(settings: settingsMirror),
            shortcuts: ShortcutsPageModel(
                settings: settingsMirror, suspendHotkeys: { [hotkeys] in hotkeys.suspend() }, sidedState: { [hotkeys] in hotkeys.sidedShortcuts }
            ),
            speech: SpeechPageModel(
                models: speechModels, microphones: Microphones(settings: .shared, source: SystemMicrophones()), settings: settingsMirror,
                keychain: Keychain.narrari,
                isTranscribing: { [session, fileJob] in session.phase != .idle || fileJob.isWorking }
            ),
            recorder: RecorderPageModel(
                settings: settingsMirror, canMute: { [media] in media.canMuteOutput() }, preview: { [sounds] in await sounds.preview($0) }
            ),
            cleanup: CleanupPageModel(engines: cleanupEngines, settings: settingsMirror, keychain: Keychain.narrari),
            prompts: PromptsPageModel(store: .shared),
            dictionary: DictionaryPageModel(store: .shared, settings: settingsMirror, listenerStatus: vocabularyStatus, models: .shared),
            modes: ModesPageModel(store: .shared, prompts: .shared, settings: settingsMirror, apps: .shared),
            history: HistoryPageModel(
                store: history,
                meetings: meetings,
                settings: settingsMirror,
                activeDictation: { [session] in session.activeDictationID },
                stopPlayback: { [playback] in playback.stop() },
                onDeleted: { [library] in await library.refresh() }
            ),
            recording: RecordingPageModel(settings: settingsMirror, apps: .shared),
            summaries: SummariesPageModel(
                folder: Self.summaryTemplates, settings: settingsMirror, summaryModels: SummaryModels(settings: .shared, store: .shared)
            ),
            people: PeoplePageModel(
                settings: settingsMirror, memory: voiceMemory, renaming: SpeakerRenaming(store: meetings, memory: voiceMemory, settings: .shared)
            ),
            looks: looks,
            meetingModels: meetingModels,
            permissions: permissions
        )
    }

    private func chooseFile() {
        guard fileJob.canStart() else { return showMain(.history) }
        showMain()
        mainWindow?.chooseFile { [weak self] url in self?.transcribe([url]) }
    }

    private func chooseRecording() {
        showMain(.meetings)
        mainWindow?.chooseFile { [weak self] url in self?.importRecordings([url]) }
    }

    private func openMeeting(_ id: UUID) {
        meetingLibrary.selection = .meeting(id)
        showMain(.meetings)
    }

    // Each recording becomes a meeting, in turn; they show in the meetings.
    private func importRecordings(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        mainWindow?.show(.meetings)
        Task { [meetingLibrary] in await meetingLibrary.importRecordings(urls) }
    }

    // The file shows in the dictations, so a start from a settings page goes back to them.
    private func transcribe(_ urls: [URL]) {
        mainWindow?.show(.history)
        fileJob.offer(urls)
    }

    // Everything Narrari draws outside its window: the recorder pill, the meeting chip, the call notice and the menu bar panel.
    private func makeSurfaces() {
        let surfaces = MeetingSurfaces(session: meeting, dictation: session, settings: .shared, clock: ContinuousClock())
        surfaces.onOpenMeeting = { [weak self] id in self?.openMeeting(id) }
        pill = RecorderPill(session: session, meeting: meeting, surfaces: surfaces, looks: looks, motion: motion)
        meetingChip = MeetingChip(meeting: meeting, surfaces: surfaces, looks: looks, motion: motion)
        callNotice = CallNotice(meeting: meeting, surfaces: surfaces, looks: looks, motion: motion) { AppDirectory.shared.app(for: $0) }
        menuPanel = MenuPanelController(
            model: MenuPanel(
                session: session, meetings: meeting, meetingLibrary: meetingLibrary,
                workNews: WorkNews(meetings: meetingLibrary, files: fileJob),
                microphones: Microphones(settings: .shared, source: SystemMicrophones()),
                library: library, permissions: permissions, settings: settingsMirror, appName: { AppDirectory.shared.name(for: $0) }
            ),
            surfaces: surfaces, motion: motion
        ) { [weak self] action in self?.perform(action) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let running = otherRunningCopy() {
            running.activate()
            NSApplication.shared.terminate(nil)
            return
        }
        Task { [media] in await media.restoreOutput() }
        hotkeys.onShortcut = { [weak self, session, library, meeting] live in
            switch live {
            case .mode: session.cycleMode()
            case .openWindow: self?.showMain()
            case .pasteLast: Task { await session.pasteLast(library.lastDictation?.finalText) }
            case .meeting: Task { await meeting.toggle() }
            case .openSettings: self?.showSettings()
            }
        }
        hotkeys.start()
        makeSurfaces()
        meeting.follow()
        session.frontmostAppChanged()
        permissions.start()
        if !permissions.isComplete { showMain(.settings(.permissions)) }
        Task { [library, session] in
            await library.refresh()
            await library.follow(session.historyChanges)
        }
        Task { [meetingLibrary] in
            await meetingLibrary.refresh()
            await meetingLibrary.follow()
        }
        Task { [meetingProcessing] in await meetingProcessing.resume() }
        meetingModels.whenLanded { [meetingProcessing] in await meetingProcessing.carryOn() }
        Task { @MainActor [session] in
            for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didActivateApplicationNotification) {
                session.frontmostAppChanged()
            }
        }
        retention.start()
        SettingsChanges.followOutsideWrites()
        speechModels.start()
        cleanupEngines.start()
        Task { [vocabulary] in
            await vocabulary.follow(.shared)
        }
        if let seconds = ProcessClock.secondsSinceProcessStart() {
            Log.timing("cold-start", seconds: seconds)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            async let dictation: Void = session.shutdown()
            async let recording: Void = meeting.shutdown()
            _ = await (dictation, recording)
            await cleanupEngines.current?.unload()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func otherRunningCopy() -> NSRunningApplication? {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { $0 != .current }
    }
}

extension App {
    // Called from a protocol extension, main() is SwiftUI's own, not the one NarrariApp declares above.
    fileprivate static func startApp() { main() }
}
