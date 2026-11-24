import Carbon.HIToolbox
import Foundation
import NarrariKit
import Testing

@MainActor
private final class Rig {
    let folder = TemporaryFolder()
    let settings = ThrowawaySettings()
    let clock = TestClock()
    let pasteboard = FakePasteboard()
    let history: HistoryStore
    let modes: ModeStore
    let session: DictationSession
    let library: HistoryLibrary
    let microphones: FakeMicrophones
    let meetings = MeetingRig()
    let meetingStore: MeetingStore
    let meetingLibrary: MeetingLibrary
    let fileJob: FileJob
    let panel: MenuPanel
    static let builtIn = Microphone(id: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
    static let airPods = Microphone(id: "AirPods-input", name: "AirPods Pro")
    static let noon = HistoryStore.localCalendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!

    init(accessibility: Bool = true, microphones: [Microphone] = [Rig.builtIn]) {
        self.microphones = FakeMicrophones(microphones)
        history = HistoryStore(root: folder.url.appending(path: "History", directoryHint: .isDirectory))
        modes = ModeStore(root: folder.url)
        let transcriber = FakeTranscriber(text: "unused")
        let pipeline = TextPipeline(
            cleanup: CleanupService(engine: nil, settings: settings.store, clock: clock),
            prompts: PromptStore(root: folder.url), dictionary: DictionaryStore(root: folder.url), settings: settings.store
        )
        let access = InputAccess.fixed(accessibility: accessibility)
        session = DictationSession(
            hotkeys: FakeHotkeys(), recorder: FakeRecorder(), transcriber: transcriber,
            livePreview: LivePreview(transcriber: transcriber, clock: clock), pipeline: pipeline,
            paster: Paster(pasteboard: pasteboard, access: access, settings: settings.store, clock: clock),
            media: FakeMuting(), sounds: FakeSounds(), history: history, modes: modes, settings: settings.store,
            clock: clock, frontmostApp: { "com.apple.mail" }, ownApp: "com.nb-limited.narrari"
        )
        let retranscription = Retranscription(
            history: history, pipeline: pipeline,
            transcription: FileTranscription(
                store: ModelStore(root: folder.url), settings: settings.store, dictionary: DictionaryStore(root: folder.url)
            ),
            modes: modes, settings: settings.store
        )
        library = HistoryLibrary(store: history, retranscription: retranscription, apps: AppDirectory())
        meetingStore = MeetingStore(root: folder.url.appending(path: "Meetings"), trash: { try FileManager.default.removeItem(at: $0) })
        let modelStore = ModelStore(root: folder.url.appending(path: "Models"))
        meetingLibrary = MeetingLibrary(
            store: meetingStore, processor: StartedProcessor(), models: MeetingModels(store: modelStore, fetch: FakeModelFetch(store: modelStore).fetch),
            progress: MeetingTranscript.Progress(), settings: settings.store, recording: { nil }
        )
        fileJob = FileJob(library: library, retranscription: retranscription) { true }
        let permissions = Permissions(settings: settings.store, access: access, microphoneStatus: { .authorized }, clock: clock)
        let names = ["com.apple.mail": "Mail", "com.tinyspeck.slackmacgap": "Slack"]
        panel = MenuPanel(
            session: session, meetings: meetings.session, meetingLibrary: meetingLibrary,
            workNews: WorkNews(meetings: meetingLibrary, files: fileJob),
            microphones: Microphones(settings: settings.store, source: self.microphones), library: library,
            permissions: permissions, settings: settings.mirror, pasteboard: pasteboard,
            appName: { names[$0] ?? $0 }, clock: clock, now: { [clock] in Rig.noon.addingTimeInterval(clock.seconds) }
        )
        session.frontmostAppChanged()
    }

    func dictated(_ text: String) async throws {
        let id = UUID()
        try await history.append(HistoryEntry(
            id: id, startedAt: Self.noon, app: "com.tinyspeck.slackmacgap", finalText: text,
            audioFile: HistoryEntry.audioFileName(for: id), outcome: .pasted
        ))
        await library.refresh()
    }

    // A meeting whose summary step is in the given state, read into the list as the window would.
    @discardableResult
    func meeting(_ title: String, summary: Meeting.Step) async throws -> Meeting {
        var meeting = Meeting(title: title, startedAt: Self.noon, app: "", source: .call, template: "general", state: .ready)
        for step in MeetingProcessing.Step.allCases { meeting.steps[step] = Meeting.Step(.done) }
        meeting.steps[.summary] = summary
        try await meetingStore.create(meeting, appName: "Calls")
        await meetingLibrary.refresh()
        return meeting
    }

    func finishSummary(of meeting: Meeting) async throws {
        try await meetingStore.update(meeting.id) { $0.steps[.summary] = Meeting.Step(.done) }
        await meetingLibrary.refresh()
    }

    func giveMailThreeModes() throws {
        try modes.edit { book in
            for (id, name) in [("email", "Email"), ("short", "Short reply"), ("spoken", "As spoken")] {
                try book.add(Mode(id: id, name: name))
            }
            try book.setModes(for: "com.apple.mail", ids: ["email", "short", "spoken"], defaultID: "email")
        }
    }
}

@MainActor
struct MenuPanelTests {
    @Test func opens_on_the_last_dictation_and_return_copies_it() async throws {
        let rig = Rig()
        try await rig.dictated("Thursday at ten works for me.")

        rig.panel.open()
        let outcome = rig.panel.activate(try #require(rig.panel.highlighted))

        #expect(rig.panel.lastDictation?.meta.hasSuffix(" in Slack, just now") == true)
        #expect(outcome == .closeShowingCopied)
        #expect(rig.panel.isCopied)
        #expect(rig.pasteboard.text == "Thursday at ten works for me.")
    }

    @Test func each_row_shows_its_shortcut_as_set_now() {
        let rig = Rig()
        let none = rig.panel.shortcut(for: .meeting)

        LiveShortcut.meeting.store(Shortcut(keyCode: kVK_F5, modifiers: controlKey | optionKey), in: rig.settings.store)
        LiveShortcut.openSettings.store(Shortcut(keyCode: kVK_F6, modifiers: cmdKey), in: rig.settings.store)
        rig.settings.store.set(61, for: DictationSettings.hotkeyKeyCode)

        #expect(none == nil)
        #expect(rig.panel.shortcut(for: .meeting) == "⌃⌥F5")
        #expect(rig.panel.shortcut(for: .settings) == "⌘F6")
        #expect(rig.panel.shortcut(for: .dictation) == "Right ⌥")
        #expect(rig.panel.hotkey == "Right ⌥")
        #expect(rig.panel.shortcut(for: .openMain) == nil)
        #expect(rig.panel.shortcut(for: .meetingPause) == nil)
    }

    @Test func age_stays_current_while_open_and_nothing_ticks_once_closed() async throws {
        let rig = Rig()
        try await rig.dictated("Hello.")
        rig.panel.open()
        await rig.clock.waitForSleepers(1)

        rig.clock.advance(by: .seconds(120))
        await until { rig.panel.lastDictation?.meta.hasSuffix("2 min ago") == true }
        rig.panel.close()

        #expect(rig.clock.pendingSleepers == 0)
        #expect(rig.panel.highlighted == nil)
    }

    @Test func missing_accessibility_opens_on_its_fix_and_start_dictation_says_why_it_is_off() {
        let rig = Rig(accessibility: false)

        rig.panel.open()

        #expect(rig.panel.status.fixTitle == "Open Accessibility Settings")
        #expect(rig.panel.highlighted == .fix)
        #expect(rig.panel.activate(.fix) == .close(then: .allowAccessibility))
        #expect(!rig.panel.dictation.isEnabled)
        #expect(rig.panel.dictation.reason == "Accessibility not allowed")
        #expect(!rig.panel.items.contains(.dictation))
    }

    @Test func arrows_walk_every_row_and_the_mode_list_opens_in_place() throws {
        let rig = Rig()
        try rig.giveMailThreeModes()
        rig.panel.open()
        #expect(rig.panel.modeTitle == "Mode for Mail")
        #expect(rig.panel.highlighted == .mode)

        #expect(rig.panel.activate(.mode) == .stayOpen)
        #expect(rig.panel.items.prefix(5) == [.mode, .modeOption("email"), .modeOption("short"), .modeOption("spoken"), .dictation])
        #expect(rig.panel.activate(.modeOption("short")) == .stayOpen)

        #expect(rig.session.modeChoice.current.id == "short")
        #expect(!rig.panel.isModeListOpen)
        rig.panel.moveHighlight(by: -1)
        #expect(rig.panel.highlighted == .quit)
        rig.panel.moveHighlight(by: 1)
        #expect(rig.panel.highlighted == .mode)
    }

    @Test func without_a_dictation_copy_does_nothing_and_start_dictation_is_first() {
        let rig = Rig()

        rig.panel.open()

        #expect(rig.panel.lastDictation == nil)
        #expect(rig.panel.highlighted == .dictation)
        #expect(rig.panel.copyLastDictation() == .stayOpen)
        #expect(rig.pasteboard.text == nil)
    }

    @Test func one_microphone_is_named_and_does_not_open() {
        let rig = Rig()

        rig.panel.open()

        #expect(rig.panel.microphoneValue == "MacBook Pro Microphone")
        #expect(!rig.panel.items.contains(.microphone))
        #expect(rig.panel.activate(.microphone) == .stayOpen)
        #expect(!rig.panel.isMicrophoneListOpen)
    }

    @Test func choosing_a_microphone_stores_it_and_moves_the_check_from_automatic() {
        let rig = Rig(microphones: [Rig.builtIn, Rig.airPods])
        rig.panel.open()
        #expect(rig.panel.microphoneValue == "Automatic")

        _ = rig.panel.activate(.microphone)
        #expect(rig.panel.items.contains(.microphoneOption(Rig.airPods.id)))
        #expect(rig.panel.microphoneOptions.filter(\.isChosen).map(\.title) == ["Automatic"])
        #expect(rig.panel.microphoneOptions.filter(\.isInUse).map(\.title) == ["MacBook Pro Microphone"])
        _ = rig.panel.activate(.microphoneOption(Rig.airPods.id))

        #expect(rig.settings.store.value(DictationSettings.microphoneUID) == Rig.airPods.id)
        #expect(rig.panel.microphoneValue == "AirPods Pro")
        #expect(rig.panel.microphoneOptions.filter(\.isChosen).map(\.title) == ["AirPods Pro"])
        #expect(rig.panel.microphoneOptions.allSatisfy { !$0.isInUse })
        #expect(rig.panel.highlighted == .microphone)
    }

    @Test func a_microphone_plugged_in_while_open_joins_the_list_and_a_missing_choice_says_so() {
        let rig = Rig()
        rig.settings.store.set("Gone-input", for: DictationSettings.microphoneUID)
        rig.panel.open()

        rig.microphones.plug(Rig.airPods)

        #expect(rig.panel.microphoneOptions.map(\.title) == ["Automatic", "MacBook Pro Microphone", "AirPods Pro", Microphones.missingTitle])
        #expect(rig.panel.microphoneValue == Microphones.missingTitle)
        #expect(rig.panel.microphoneOptions.filter(\.isInUse).map(\.title) == ["MacBook Pro Microphone"])
    }

    @Test func start_meeting_records_and_then_the_panel_offers_pause_or_resume_before_stop() async {
        let rig = Rig()
        rig.panel.open()
        #expect(rig.panel.meetingTitle == "Start meeting")
        #expect(rig.panel.activate(.meeting) == .close(then: .toggleMeeting))

        await rig.meetings.session.toggle()

        #expect(rig.panel.items.drop { $0 != .dictation }.prefix(3) == [.dictation, .meetingPause, .meeting])
        #expect(rig.panel.meetingTitle == "Stop meeting" && rig.panel.meetingPauseTitle == "Pause meeting")
        rig.meetings.session.pause()
        #expect(rig.panel.meetingPauseTitle == "Resume meeting")
        await rig.meetings.session.stop()
        #expect(rig.panel.meetingPauseTitle == nil)
    }

    @Test func a_meeting_shows_its_state_and_time_where_ready_would_be() async {
        let rig = Rig()
        rig.panel.open()
        let ready = rig.panel.status
        await rig.clock.waitForSleepers(1)

        await rig.meetings.session.start()
        rig.meetings.replay.play(seconds: 2)
        rig.clock.advance(by: .seconds(1))

        await until { rig.panel.status == .meeting(title: "Recording meeting", elapsed: "0:02") }
        rig.meetings.session.pause()
        #expect(rig.panel.status.title == "Meeting paused")
        await rig.meetings.session.stop()
        #expect(rig.panel.status == ready)
        #expect(rig.panel.activate(.importRecording) == .close(then: .importRecording))
    }

    @Test func a_failed_meeting_marks_the_icon_and_its_row_opens_the_meeting_until_it_is_fixed() async throws {
        let rig = Rig()
        let failed = try await rig.meeting("Weekly sync", summary: Meeting.Step(.failed, problem: "meeting.summary-failed"))

        rig.panel.open()

        #expect(rig.panel.attention == "The summary could not be written. Try again.")
        #expect(rig.panel.notes.map(\.title) == ["Weekly sync"])
        #expect(rig.panel.notes.first?.state.brief == "Failed")
        #expect(rig.panel.highlighted == .note(.meeting(failed.id)))
        #expect(rig.panel.activate(.note(.meeting(failed.id))) == .close(then: .open(.meeting(failed.id))))

        try await rig.finishSummary(of: failed)
        #expect(rig.panel.attention == nil)
    }

    @Test func a_summary_that_lands_while_closed_shows_once_and_opening_again_clears_it() async throws {
        let rig = Rig()
        let meeting = try await rig.meeting("Planning", summary: Meeting.Step(.running, since: Rig.noon))
        try await rig.finishSummary(of: meeting)
        await until { rig.panel.attention == nil && !rig.meetingLibrary.entries.isEmpty }

        rig.panel.open()
        let shown = rig.panel.notes
        rig.panel.close()
        rig.panel.open()

        #expect(shown.map(\.target) == [.meeting(meeting.id)] && shown.map(\.title) == ["Planning"] && shown.first?.state == .done)
        #expect(rig.panel.notes.isEmpty)
        #expect(rig.panel.attention == nil)
    }

    @Test func a_meeting_being_processed_reads_the_step_under_way_not_a_fixed_line() {
        let started = Rig.noon
        let status = { (work: WorkState) in
            MenuPanelStatus(
                .ready, meeting: .processing, meetingWork: work, hotkey: "Right ⌘", elapsed: 0, meetingElapsed: 0,
                now: started.addingTimeInterval(40)
            )
        }

        #expect(status(.working(.findingSpeakers, since: started)).title == "Finding speakers, 0:40")
        #expect(status(.working(.transcribing, progress: 0.42, since: started)).title == "Transcribing")
        #expect(status(.working(.transcribing, progress: 0.42, since: started)).percent == "42%")
        #expect(status(.waiting(.speechModel)).title == "Waits for the speech model")
    }

    @Test func a_file_that_failed_while_the_panel_was_closed_is_named_once_and_opens_the_dictations() async {
        let rig = Rig()
        rig.fileJob.offer([rig.folder.url.appending(path: "interview.m4a")])
        await until { !rig.fileJob.isWorking }

        rig.panel.open()
        let shown = rig.panel.notes
        rig.panel.close()
        rig.panel.open()

        #expect(shown.map(\.title) == ["interview.m4a"] && shown.first?.state.brief == "Failed")
        #expect(rig.panel.notes.isEmpty)
        #expect(rig.panel.attention == nil)
    }
}
