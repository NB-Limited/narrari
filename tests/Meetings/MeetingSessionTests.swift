import AppKit
import NarrariKit
import Synchronization
import Testing

private final class FakeProcessor: MeetingProcessor {
    let gate = Gate()
    let meetings = Mutex<[UUID]>([])
    let prepared = Gate.counter()

    func prepare() async {
        try? await prepared.pass()
    }

    func process(_ meeting: UUID) async {
        meetings.withLock { $0.append(meeting) }
        try? await gate.pass()
    }
}

// No events; while held, every look waits at the gate, as a slow calendar would.
private final class HeldCalendar: CalendarSource {
    let gate = Gate()
    let holds = Mutex(false)

    func events(from start: Date, to end: Date) async -> [CalendarEvent] {
        if holds.withLock({ $0 }) { try? await gate.pass() }
        return []
    }
}

// Serialized: the sleep tests post to the shared workspace centre, which every following session hears.
@MainActor
@Suite(.serialized)
struct MeetingSessionTests {
    private static let zoom = "us.zoom.xos"

    private let folder = TemporaryFolder()
    private let settings = ThrowawaySettings()
    private let clock = TestClock()
    private let callClock = TestClock()
    private let screenClock = TestClock()
    private let watcher = FakeScreenWatcher()
    private let namesClock = TestClock()
    private let windows = FakeCallWindows()
    private let processor = FakeProcessor()
    private let processes = FakeProcesses()
    private let replay = Replay(microphone: speech(seconds: 1), system: [0])
    private let store: MeetingStore
    private let permissions: Permissions
    private let session: MeetingSession

    init() {
        store = MeetingStore(root: folder.url, trash: { try FileManager.default.removeItem(at: $0) })
        permissions = Permissions.fixed(settings: settings.store)
        let now = Date.now
        let event = CalendarEvent(
            title: "Weekly sync", start: now.addingTimeInterval(-600), end: now.addingTimeInterval(1_800), attendees: ["Ana Petrova"]
        )
        session = MeetingSession(
            store: store,
            recorder: MeetingRecorder(
                settings: settings.store, permissions: permissions, inputs: replay, system: replay,
                freeSpace: { _ in 10_000_000_000 }, hostNow: { [replay] in replay.clock.hostTime }, clock: TestClock()
            ),
            calls: CallDetector(processes: processes, settings: settings.store, clock: callClock),
            calendar: CalendarLink(source: FakeCalendar(events: [event]), ownerName: "Mila Novak", settings: settings.store),
            screen: ScreenWatch(watcher: watcher, clock: screenClock),
            names: CallWindowNames(source: windows, settings: settings.store, clock: namesClock, ownerName: "Mila Novak"),
            permissions: permissions, processor: processor, liveText: nil, settings: settings.store, clock: clock,
            appName: { _ in "zoom.us" }
        )
    }

    private func recordCall() async {
        await session.handle(.started(app: Self.zoom))
        await session.start()
        replay.play(seconds: 2)
    }

    @Test func a_detected_call_is_offered_and_the_offer_goes_when_the_call_ends() async throws {
        await session.handle(.started(app: Self.zoom))
        #expect(session.state == .offered(app: Self.zoom))
        #expect(session.shownOffer == Self.zoom)

        await session.handle(.ended)

        #expect(session.state == .idle)
        #expect(try await store.meetings().meetings.isEmpty)
    }

    @Test func with_starts_by_itself_on_a_call_records_at_once_under_its_app_and_calendar_event_and_gets_its_models_ready() async throws {
        settings.store.set(true, for: MeetingsSettings.startsByItself)

        await session.handle(.started(app: Self.zoom))

        #expect(session.state == .recording)
        let meeting = try #require(try await store.meetings().meetings.first)
        #expect(meeting.app == Self.zoom && meeting.source == .call)
        #expect(meeting.title == "Weekly sync" && meeting.attendees == [.init(name: "Ana Petrova", source: .calendar)])
        #expect(FileManager.default.fileExists(atPath: folder.url.appending(path: "zoom.us").path))
        await processor.prepared.waitForArrivals(1)
    }

    // Its live lines stay with it after the stop, until its transcript is written.
    @Test func a_call_that_ends_stops_its_recording_10_seconds_later_and_hands_it_to_processing() async throws {
        await recordCall()

        await session.handle(.ended)
        #expect(session.stopCountdown == 10)
        for _ in 0..<10 {
            await clock.waitForSleepers(1)
            clock.advance(by: .seconds(1))
        }
        await until { session.state == .processing }

        let meeting = try #require(try await store.meetings().meetings.first)
        #expect(meeting.state == .ready && meeting.durationMs == 2_000)
        #expect(permissions.systemAudio == .silent)
        processor.gate.open()
        await until { session.state == .idle }
        #expect(processor.meetings.withLock { $0 } == [meeting.id])
        #expect(session.liveTextMeetingID == meeting.id)
    }

    // macOS never says whether other apps' sound may be recorded, so silence blames permission only until sound came once.
    @Test(arguments: [Meeting.Source.call, .manual])
    func a_silent_or_missing_system_track_is_kept_with_the_reason_that_is_true(source: Meeting.Source) async throws {
        let replay = Replay(microphone: speech(seconds: 1), system: [0])
        let output = FaultyOutput(audio: speech(seconds: 1), clock: replay.clock)
        let rig = MeetingRig(replay: replay, system: output)
        let store = MeetingStore(root: rig.folder.url, trash: { _ in })
        var kept: [Meeting] = []
        for change in [{ output.silence(true) }, { output.silence(false) }, { output.silence(true) }, output.failToBuild] {
            change()
            if source == .call { await rig.session.handle(.started(app: MeetingRig.zoom)) }
            await rig.session.start()
            let id = try #require(rig.session.recordingID)
            await record(2, replay, output, checkedBy: rig.recorderClock)
            await rig.session.stop()
            kept.append(try await store.meeting(id))
        }

        #expect(kept.map(\.systemSound) == [.unheard, .heard, .nothingPlayed, .notCaptured])
        #expect(kept.map(\.soundNotes.first) == [
            "Other people's sound was not recorded.", nil,
            source == .call ? "Nothing played on this Mac, so only your microphone was recorded." : nil,
            "This Mac's sound could not be recorded."
        ])
    }

    @Test func keep_recording_cancels_the_countdown() async {
        await recordCall()
        await session.handle(.ended)
        for _ in 0..<3 {
            await clock.waitForSleepers(1)
            clock.advance(by: .seconds(1))
        }
        await until { session.stopCountdown == 7 }

        session.keepRecording()

        #expect(session.stopCountdown == nil)
        #expect(clock.pendingSleepers == 0)
        #expect(session.state == .recording)
    }

    // The display sleeping and another user taking the screen go before the Mac sleeps, and stop nothing.
    @Test func a_meeting_started_by_hand_ignores_calls_and_stops_when_the_mac_sleeps_saying_so() async throws {
        session.follow()
        await session.start()
        await session.handle(.ended)

        #expect(session.stopCountdown == nil)
        #expect(clock.pendingSleepers == 0)
        #expect(session.state == .recording)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)

        await until { session.state == .processing }
        #expect(try await store.meetings().meetings.map(\.stop) == [.sleep])
    }

    @Test(arguments: [false, true])
    func a_call_recorded_when_the_mac_sleeps_is_offered_or_recorded_again_on_wake_while_it_goes_on(startsByItself: Bool) async throws {
        settings.store.set(startsByItself, for: MeetingsSettings.startsByItself)
        session.follow()
        await processes.set([FakeProcesses.app(Self.zoom, input: true, output: true)])
        await callClock.waitForSleeper(until: callClock.now.advanced(by: .seconds(3)))
        callClock.advance(by: .seconds(3))
        await until { session.state != .idle }
        await session.start()
        await until { session.recordingID != nil }
        replay.play(seconds: 1)

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        await until { session.recordingID == nil }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await callClock.waitForSleeper(until: callClock.now.advanced(by: .seconds(3)))
        callClock.advance(by: .seconds(3))

        await until { startsByItself ? session.recordingID != nil : session.state == .offered(app: Self.zoom) }
        let meetings = try await store.meetings().meetings
        #expect(meetings.contains { $0.stop == .sleep && $0.app == Self.zoom })
        #expect(meetings.count == (startsByItself ? 2 : 1))
    }

    @Test func the_shortcut_takes_up_the_offered_call_and_stops_it_paused_or_not() async throws {
        await session.handle(.started(app: Self.zoom))

        await session.toggle()
        session.pause()
        #expect(session.state == .paused)
        session.resume()
        session.pause()
        await session.toggle()

        #expect(session.state == .processing)
        #expect(try await store.meetings().meetings.map(\.source) == [.call])
    }

    @Test func a_dismissed_offer_records_nothing_and_stops_watching_the_screen() async throws {
        await session.handle(.started(app: Self.zoom))
        await screenClock.waitForSleepers(1)

        session.dismissOffer()

        #expect(session.state == .idle)
        #expect(screenClock.pendingSleepers == 0)
        #expect(try await store.meetings().meetings.isEmpty)
    }

    @Test func an_offer_made_while_the_screen_is_watched_waits_until_the_watching_stops() async {
        watcher.answer.withLock { $0 = true }

        await session.handle(.started(app: Self.zoom))
        #expect(session.state == .offered(app: Self.zoom))
        #expect(session.shownOffer == nil)

        watcher.answer.withLock { $0 = false }
        await screenClock.waitForSleepers(1)
        screenClock.advance(by: .seconds(1))

        await until { session.shownOffer == Self.zoom }
    }

    @Test func names_read_from_the_call_window_join_the_calendar_attendees_once_each() async throws {
        settings.store.set(true, for: MeetingsSettings.readsCallWindowNames)
        settings.store.set(true, for: MeetingsSettings.startsByItself)
        windows.state.withLock { $0.windows[Self.zoom] = FakeCallWindows.zoom(["Ana Petrova", "Boris Ivanov (Guest)"]) }

        await session.handle(.started(app: Self.zoom))
        await namesClock.waitForSleepers(1)
        windows.state.withLock { $0.windows[Self.zoom] = FakeCallWindows.zoom(["boris ivanov", "Vera Kostova"]) }
        namesClock.advance(by: .seconds(30))
        await namesClock.waitForSleepers(1)

        let expected: [Meeting.Attendee] = [
            .init(name: "Ana Petrova", source: .calendar), .init(name: "Boris Ivanov", source: .callWindow),
            .init(name: "Vera Kostova", source: .callWindow)
        ]
        #expect(try #require(try await store.meetings().meetings.first).attendees == expected)
        replay.play(seconds: 1)
        await session.stop()
        #expect(try #require(try await store.meetings().meetings.first).attendees == expected)
    }

    @Test func a_call_that_ends_while_its_recording_begins_still_counts_down_to_stop() async {
        let calendar = HeldCalendar()
        let rig = MeetingRig(calendar: calendar)
        await rig.session.handle(.started(app: Self.zoom))
        calendar.holds.withLock { $0 = true }

        async let started: Void = rig.session.start()
        await calendar.gate.waitForArrivals(1)
        async let ended: Void = rig.session.handle(.ended)
        calendar.gate.open()
        _ = await (started, ended)

        #expect(rig.session.stopCountdown == 10)
    }

    @Test func a_stop_pressed_while_the_recording_begins_stops_it() async throws {
        let calendar = HeldCalendar()
        calendar.holds.withLock { $0 = true }
        let rig = MeetingRig(calendar: calendar)

        async let started: Void = rig.session.start()
        await calendar.gate.waitForArrivals(1)
        async let stopped: Void = rig.session.toggle()
        calendar.gate.open()
        _ = await (started, stopped)

        #expect(rig.session.state == .idle)
        let store = MeetingStore(root: rig.folder.url, trash: { try FileManager.default.removeItem(at: $0) })
        #expect(try await store.meetings().meetings.map(\.state) == [.ready])
    }

    // The page and the narrari command change the meeting through the store while it records.
    @Test func a_change_made_to_the_meeting_while_it_records_is_kept_at_the_stop() async throws {
        await recordCall()
        let id = try #require(session.recordingID)
        try await store.update(id) { $0.title = "Release planning" }

        await session.stop()

        let meeting = try await store.meeting(id)
        #expect(meeting.title == "Release planning" && meeting.state == .ready && meeting.durationMs == 2_000)
        processor.gate.open()
    }

    @Test func a_stop_that_cannot_be_saved_shows_why_on_its_row_and_is_not_processed() async throws {
        await recordCall()
        let id = try #require(session.recordingID)
        let meetingFolder = try await store.folder(of: id)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: meetingFolder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: meetingFolder.path) }

        await session.stop()

        let models = ModelStore(root: folder.url.appending(path: "Models"))
        let library = MeetingLibrary(
            store: store, processor: processor, models: MeetingModels(store: models, fetch: FakeModelFetch(store: models).fetch),
            progress: MeetingTranscript.Progress(), settings: settings.store, recording: { [session] in session.recordingID }
        )
        let meeting = try await store.meeting(id)
        #expect(session.state == .idle)
        #expect(library.state(of: meeting) == .work(.failed(MeetingSession.couldNotSave)))
        #expect(processor.meetings.withLock { $0 }.isEmpty)
    }

    @Test func quitting_while_a_meeting_records_saves_it() async throws {
        await session.start()
        replay.play(seconds: 2)

        await session.shutdown()

        #expect(session.state == .processing)
        #expect(try await store.meetings().meetings.map(\.state) == [.ready])
        processor.gate.open()
    }
}
