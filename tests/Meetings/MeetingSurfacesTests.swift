import Foundation
import NarrariKit
import Testing

@MainActor
struct MeetingSurfacesTests {
    private let meeting = MeetingRig()
    private let dictation = SessionRig()
    private let clock = TestClock()

    private var session: MeetingSession { meeting.session }

    private func surfaces(_ bar: MeetingBar = .pill) -> MeetingSurfaces {
        meeting.settings.store.set(bar, for: MeetingsSettings.bar)
        return MeetingSurfaces(session: session, dictation: dictation.session, settings: meeting.settings.store, clock: clock)
    }

    private func finishDictation() async {
        dictation.release()
        await dictation.session.shutdown()
        await dictation.clock.waitForSleepers(1)
        dictation.clock.advance(by: DictationSession.doneHold)
        await until { !dictation.session.showsPill }
    }

    @Test(arguments: [false, true])
    func a_detected_call_shows_the_notice_only_when_meetings_wait_for_start(startsByItself: Bool) async {
        meeting.settings.store.set(startsByItself, for: MeetingsSettings.startsByItself)
        let surfaces = surfaces()

        await session.handle(.started(app: MeetingRig.zoom))

        #expect(surfaces.offer?.app == (startsByItself ? nil : MeetingRig.zoom))
        #expect(surfaces.pill == (startsByItself ? .recording : nil))
        await session.stop()
    }

    @Test func start_pause_resume_and_a_call_ending_drive_the_bar_and_stop_takes_it_away() async {
        let surfaces = surfaces()
        await session.handle(.started(app: MeetingRig.zoom))
        await session.start()
        meeting.replay.play(seconds: 64)
        #expect(surfaces.pill == .recording && surfaces.pillTakesClicks && surfaces.offer == nil)
        #expect(MeetingSurfaces.elapsedText(seconds: session.recordedSeconds) == "1:04")

        session.pause()
        meeting.replay.play(seconds: 30)
        #expect(surfaces.pill == .paused)
        #expect(MeetingSurfaces.elapsedText(seconds: session.recordedSeconds) == "1:04")
        session.resume()
        #expect(surfaces.pill == .recording)

        await session.handle(.ended)
        #expect(surfaces.pill == .callEnded(secondsLeft: 10))
        #expect(MeetingSurfaces.countdownText(secondsLeft: 10) == "Call ended, stopping in 10 s")
        await meeting.clock.waitForSleeper(until: TestClock.Instant(offset: .seconds(1)))
        meeting.clock.advance(by: .seconds(1))
        await until { surfaces.pill == .callEnded(secondsLeft: 9) }
        session.keepRecording()
        #expect(surfaces.pill == .recording)

        await session.stop()
        #expect(surfaces.pill == nil && !surfaces.showsPill && !surfaces.marksRecording)
    }

    @Test func the_chip_opens_under_the_pointer_closes_a_second_after_it_leaves_and_opens_by_itself_for_the_countdown() async {
        let surfaces = surfaces(.chip)
        await session.handle(.started(app: MeetingRig.zoom))
        await session.start()
        #expect(surfaces.chip == .recording && surfaces.pill == nil && !surfaces.isChipOpen)

        surfaces.pointer(isInside: true)
        #expect(surfaces.isChipOpen)
        surfaces.pointer(isInside: false)
        #expect(surfaces.isChipOpen)
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(1))
        await until { !surfaces.isChipOpen }

        await session.handle(.ended)
        #expect(surfaces.chip == .callEnded(secondsLeft: 10) && surfaces.isChipOpen)
        await session.stop()
    }

    @Test func a_dictation_during_a_meeting_takes_the_pill_and_the_meeting_comes_back_when_it_lands() async {
        let surfaces = surfaces()
        await session.start()
        #expect(!surfaces.isFolded)

        await dictation.pressAndConfirm()
        #expect(surfaces.isFolded && surfaces.showsDictation && !surfaces.pillTakesClicks)
        await finishDictation()

        #expect(!surfaces.isFolded && surfaces.pill == .recording && surfaces.pillTakesClicks)
        await session.stop()
    }

    @Test func a_hidden_bar_draws_nothing_while_a_meeting_records_or_pauses_and_the_menu_bar_still_marks_it() async {
        let surfaces = surfaces(.hidden)
        await session.start()
        #expect(surfaces.pill == nil && surfaces.chip == nil && !surfaces.showsPill && surfaces.marksRecording)

        session.pause()
        #expect(surfaces.pill == nil && surfaces.chip == nil && surfaces.marksRecording)
        await session.stop()
    }

    @Test(arguments: [MeetingBar.pill, .chip])
    func a_click_on_the_bar_opens_the_meeting_it_records_except_beside_a_dictation(bar: MeetingBar) async throws {
        let surfaces = surfaces(bar)
        let opened = Notes<UUID>()
        surfaces.onOpenMeeting = { opened.add($0) }
        await session.start()
        let recording = try #require(session.recordingID)

        surfaces.barClicked()
        await dictation.pressAndConfirm()
        surfaces.barClicked()
        await finishDictation()
        await session.stop()
        surfaces.barClicked()

        #expect(opened.all == (bar == .pill ? [recording] : [recording, recording]))
    }

    @Test(arguments: MeetingBar.allCases)
    func while_the_screen_is_watched_no_meeting_surface_nor_dictation_is_drawn_and_all_come_back_when_it_clears(bar: MeetingBar) async {
        let surfaces = surfaces(bar)
        meeting.watcher.answer.withLock { $0 = true }
        await session.start()
        await dictation.pressAndConfirm()

        #expect(surfaces.isHidden && surfaces.bar == nil && surfaces.pill == nil && surfaces.chip == nil)
        #expect(!surfaces.showsPill && !surfaces.showsDictation && !surfaces.marksRecording)

        await meeting.screen(isWatched: false)
        await until { !surfaces.isHidden }
        #expect(surfaces.showsDictation && surfaces.marksRecording)
        switch bar {
        case .pill: #expect(surfaces.isFolded)
        case .chip: #expect(surfaces.chip == .recording)
        case .hidden: #expect(surfaces.pill == nil && surfaces.chip == nil)
        }
        await finishDictation()
        await session.stop()
    }

    @Test(arguments: [false, true])
    func an_offer_made_while_watched_shows_once_the_watching_stops_unless_the_call_ended(callEnds: Bool) async {
        let surfaces = surfaces()
        meeting.watcher.answer.withLock { $0 = true }
        await session.handle(.started(app: MeetingRig.zoom))
        #expect(surfaces.offer == nil)

        if callEnds { await session.handle(.ended) }
        if !callEnds { await meeting.screen(isWatched: false) }

        await until { surfaces.offer?.app == (callEnds ? nil : MeetingRig.zoom) }
        #expect(session.state == (callEnds ? .idle : .offered(app: MeetingRig.zoom)))
    }

    @Test(arguments: MeetingBar.allCases)
    func a_track_that_stops_recording_is_told_on_the_bar_until_its_sound_comes_back_and_the_meeting_keeps_what_was_lost(
        bar: MeetingBar
    ) async throws {
        let replay = Replay(microphone: speech(seconds: 1), system: [0])
        let output = FaultyOutput(audio: speech(seconds: 1), clock: replay.clock)
        let rig = MeetingRig(replay: replay, system: output)
        rig.settings.store.set(bar, for: MeetingsSettings.bar)
        let surfaces = MeetingSurfaces(session: rig.session, dictation: dictation.session, settings: rig.settings.store, clock: clock)
        await rig.session.start()
        await record(5, replay, output, checkedBy: rig.recorderClock)

        output.freeze(all: true)
        await record(8, replay, output, checkedBy: rig.recorderClock)
        let stopped = MeetingSurfaces.Bar.trouble(RecordingTrouble(track: .system, kind: .stopped))
        #expect((bar == .chip ? surfaces.chip : surfaces.pill) == stopped)
        #expect(bar == .chip ? surfaces.isChipOpen : surfaces.pillTakesClicks)
        #expect(stopped.announcement == "Other people's sound stopped recording")

        output.thaw()
        await record(7, replay, output, checkedBy: rig.recorderClock)
        #expect(surfaces.bar == .recording)
        let id = try #require(rig.session.recordingID)
        await rig.session.stop()

        let meeting = try await MeetingStore(root: rig.folder.url, trash: { _ in }).meeting(id)
        #expect(meeting.soundNotes == ["About 40% of other people's sound was not recorded."])
    }

    @Test func a_refused_start_shows_on_the_bar_as_long_as_a_notice_then_the_bar_goes() async {
        let full = MeetingRig(freeBytes: 0)
        full.settings.store.set(MeetingBar.pill, for: MeetingsSettings.bar)
        let surfaces = MeetingSurfaces(session: full.session, dictation: dictation.session, settings: full.settings.store, clock: clock)

        await full.session.start()

        await until { surfaces.pill == .notice(.failed(MeetingRecorderError.lowDisk.problem)) }
        #expect(!surfaces.pillTakesClicks)
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(2_500))
        await until { surfaces.pill == nil }
    }

    @Test func a_meeting_stopped_for_a_full_disk_says_so_on_the_bar_as_long_as_a_notice_then_the_bar_goes() async {
        let surfaces = surfaces()
        await session.start()
        meeting.replay.play(seconds: 6)

        meeting.disk.free.store(150_000_000, ordering: .relaxed)
        meeting.replay.play(seconds: 6)

        await until { surfaces.pill == .notice(.failed(MeetingSession.stoppedForLowDisk)) }
        #expect(MeetingSession.stoppedForLowDisk.message == "Recording stopped: the disk is nearly full. Free some space.")
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(2_500))
        await until { surfaces.pill == nil }
    }
}
