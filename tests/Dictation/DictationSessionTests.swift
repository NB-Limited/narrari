import Foundation
import NarrariKit
import Synchronization
import Testing

@MainActor
struct DictationSessionTests {
    @Test func moves_through_recording_transcribing_cleaning_and_pasting_back_to_idle() async throws {
        let heard = Gate()
        let cleaned = Gate()
        let rig = SessionRig(
            transcriber: FakeTranscriber(text: "hello from the test", gate: heard),
            engine: FakeCleanupEngine(gate: cleaned) { _ in "Hello from the test." }
        )
        #expect(rig.session.phase == .idle)

        await rig.pressAndConfirm()
        #expect(rig.session.phase == .recording)

        rig.release()
        await heard.waitForArrivals(1)
        #expect(rig.session.phase == .transcribing)

        heard.open()
        await cleaned.waitForArrivals(1)
        #expect(rig.session.phase == .cleaning)

        cleaned.open()
        await rig.session.shutdown()
        #expect(rig.pastes.map(\.phase) == [.pasting])
        #expect(rig.session.phase == .idle)
    }

    @Test func the_final_pass_replaces_the_live_words_while_clean_up_runs() async throws {
        let passes = Mutex(0)
        let transcriber = FakeTranscriber { _ in
            let pass = passes.withLock { count in
                count += 1
                return count
            }
            return Transcript(text: pass == 1 ? "hello from" : "hello from the test", audioSeconds: 1)
        }
        let cleaned = Gate()
        let rig = SessionRig(transcriber: transcriber, engine: FakeCleanupEngine(gate: cleaned) { _ in "Hello from the test." })
        rig.modelStatus.report(.ready)
        await until { rig.session.modelState == .ready }

        await rig.pressAndConfirm()
        await rig.clock.waitForSleepers(2)
        rig.clock.advance(by: .milliseconds(500))
        await until { rig.session.liveText == "hello from" }

        rig.release()
        await cleaned.waitForArrivals(1)
        #expect(rig.session.liveText == "hello from the test")
        cleaned.open()
        await rig.session.shutdown()
        #expect(rig.session.liveText.isEmpty)
    }

    @Test func press_while_busy_is_ignored_with_the_ignored_sound() async throws {
        let heard = Gate()
        let rig = SessionRig(transcriber: FakeTranscriber(text: "hello from the test", gate: heard))
        await rig.pressAndConfirm()
        rig.release()
        await heard.waitForArrivals(1)

        rig.hotkeys.send(.hotkeyDown, at: rig.clock.seconds)
        await until { rig.sounds.played.contains(.ignored) }

        #expect(rig.session.phase == .transcribing)
        heard.open()
        await rig.session.shutdown()
        #expect(try await rig.entries().count == 1)
    }

    @Test func microphone_that_cannot_start_leaves_the_session_idle_with_a_notice() async throws {
        let rig = SessionRig()
        rig.recorder.startError = RecorderError.startFailed

        rig.hotkeys.send(.hotkeyDown, at: 0)
        await rig.session.shutdown()

        #expect(rig.session.phase == .idle)
        #expect(rig.session.notice == .microphone(.startFailed))
        #expect(try await rig.entries().isEmpty)
        #expect(rig.media.mutes == 0)
    }

    @Test(arguments: zip(
        [TranscriberError.notDownloaded, .transcriptionFailed],
        [Notice.speech(.notDownloaded), .speech(.transcriptionFailed)]
    ))
    func failed_transcription_ends_idle_and_keeps_the_audio(error: TranscriberError, notice: Notice) async throws {
        let rig = SessionRig(transcriber: FakeTranscriber { _ in throw error })

        await rig.dictate()

        #expect(rig.session.phase == .idle)
        #expect(rig.session.notice == notice)
        let entry = try await rig.onlyEntry()
        #expect(entry.outcome == .failed)
        #expect(rig.hasAudio(entry))
        #expect(rig.pastes.isEmpty)
    }

    @Test func key_in_the_shortcut_window_leaves_no_trace() async throws {
        let rig = SessionRig()

        rig.hotkeys.send(.hotkeyDown, at: 0)
        rig.hotkeys.send(.otherKey, at: 0.1)
        await rig.session.shutdown()

        #expect(rig.session.phase == .idle)
        #expect(try await rig.entries().isEmpty)
        #expect(rig.audioFiles.isEmpty)
        #expect(rig.sounds.played.isEmpty)
        #expect(rig.media.mutes == 0)
    }

    @Test func narrari_shortcut_after_the_dictation_counted_ends_it_with_no_notice_sound_or_paste() async throws {
        let rig = SessionRig()
        await rig.pressAndConfirm()

        rig.hotkeys.send(.shortcut, at: rig.clock.seconds)
        rig.release()
        await rig.session.shutdown()

        #expect(rig.session.phase == .idle)
        #expect(rig.session.notice == nil)
        #expect(rig.sounds.played == [.start])
        #expect(rig.pastes.isEmpty)
    }

    @Test(arguments: [ModelState.ready, .preparing(fraction: 0.4)])
    func escape_while_transcribing_stops_the_pass_keeps_the_audio_and_pastes_nothing(model: ModelState) async throws {
        let hold = Gate()
        let rig = SessionRig(transcriber: FakeTranscriber(text: "late words", gate: hold))
        rig.settings.store.set(false, for: DictationSettings.showsLiveText)
        rig.modelStatus.report(model)
        await until { rig.session.modelState == model }
        await rig.pressAndConfirm()
        rig.release()
        await hold.waitForArrivals(1)

        rig.hotkeys.send(.escape, at: rig.clock.seconds)
        await hold.waitForStops(1)
        await rig.session.shutdown()

        #expect(!rig.session.showsPill)
        #expect(rig.pastes.isEmpty)
        let entry = try await rig.onlyEntry()
        #expect(entry.needsTranscription)
        #expect(rig.hasAudio(entry))
    }

    @Test func escape_while_cleaning_stops_the_rewrite_and_pastes_the_words_as_spoken_once() async throws {
        let hold = Gate()
        let rig = SessionRig(engine: FakeCleanupEngine(gate: hold) { _ in "Late clean-up." })
        await rig.pressAndConfirm()
        rig.release()
        await hold.waitForArrivals(1)

        rig.hotkeys.send(.escape, at: rig.clock.seconds)
        await hold.waitForStops(1)
        await rig.session.shutdown()

        #expect(rig.pastes.map(\.text) == ["hello from the test"])
        let entry = try await rig.onlyEntry()
        #expect(entry.outcome == .pasted)
        #expect(entry.cleanup.reason == CleanupResult.Reason.hotkey.rawValue)
    }

    @Test(arguments: [DictationSession.Phase.transcribing, .cleaning])
    func a_result_that_lands_after_escape_changes_nothing(step: DictationSession.Phase) async throws {
        let hold = Gate(honoursCancellation: false)
        let rig = step == .transcribing
            ? SessionRig(transcriber: FakeTranscriber(text: "late words", gate: hold))
            : SessionRig(engine: FakeCleanupEngine(gate: hold) { _ in "Late clean-up." })
        await rig.pressAndConfirm()
        rig.release()
        await hold.waitForArrivals(1)
        rig.hotkeys.send(.escape, at: rig.clock.seconds)
        await rig.session.shutdown()
        let before = try await rig.entries()
        let pasted = rig.pastes.map(\.text)

        hold.open()
        await hold.waitForPasses(1)
        await rig.session.shutdown()

        #expect(rig.pastes.map(\.text) == pasted)
        #expect(try await rig.entries() == before)
        #expect(before.count == 1)
    }

    @Test func live_text_model_loads_when_a_dictation_is_confirmed() async throws {
        let transcriber = FakeTranscriber(text: "hello from the test")
        let rig = SessionRig(transcriber: transcriber)
        rig.modelStatus.report(.ready)
        await until { rig.session.modelState == .ready }
        #expect(transcriber.loads.arrivals == 0)

        await rig.pressAndConfirm()

        await transcriber.loads.waitForArrivals(1)
        rig.release()
        await rig.session.shutdown()
        #expect(try await rig.onlyEntry().finalText == "Hello from the test.")
    }

    @Test func live_text_model_is_never_loaded_while_the_speech_model_is_missing() async throws {
        let transcriber = FakeTranscriber(text: "hello from the test")
        let rig = SessionRig(transcriber: transcriber)

        await rig.dictate()

        #expect(transcriber.loads.arrivals == 0)
    }

    @Test func timing_changed_during_a_dictation_waits_for_the_next_one() async throws {
        let rig = SessionRig()
        await rig.pressAndConfirm()
        rig.hotkeys.send(.hotkeyUp, at: rig.clock.seconds)

        rig.timing.minimumRecording = 5
        rig.clock.advance(by: .milliseconds(400))
        rig.hotkeys.send(.hotkeyDown, at: rig.clock.seconds)
        await rig.session.shutdown()
        #expect(try await rig.onlyEntry().outcome == .pasted)
        await rig.dictate()

        #expect(rig.session.notice == .discarded)
        #expect(try await rig.entries().map(\.outcome) == [.discarded, .pasted])
    }
}
