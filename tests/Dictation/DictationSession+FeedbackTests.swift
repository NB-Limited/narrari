import Foundation
import NarrariKit
import Testing

@MainActor
struct DictationSessionFeedbackTests {
    @Test func a_pasted_dictation_shows_done_briefly_then_lets_the_pill_go() async throws {
        let rig = SessionRig()

        await rig.dictate()
        #expect(rig.session.isDone)
        #expect(rig.session.showsPill)

        await rig.clock.waitForSleepers(1)
        rig.clock.advance(by: .milliseconds(700))
        await until { !rig.session.isDone }
        #expect(!rig.session.showsPill)
    }

    enum End: CaseIterable {
        case release
        case escape
        case keyWhileHeld
        case microphoneUnplugged
        case quit
    }

    @Test(arguments: End.allCases)
    func muted_output_is_restored_however_the_dictation_ends(end: End) async throws {
        let rig = SessionRig()
        await rig.pressAndConfirm()

        switch end {
        case .release: rig.release()
        case .escape: rig.hotkeys.send(.escape, at: rig.clock.seconds)
        case .keyWhileHeld: rig.hotkeys.send(.otherKey, at: rig.clock.seconds)
        case .microphoneUnplugged: rig.recorder.unplug()
        case .quit: break
        }
        await rig.session.shutdown()

        #expect(rig.media.mutes == 1)
        #expect(rig.media.restores == 1)
    }

    @Test func a_notice_fades_after_two_and_a_half_seconds_and_an_error_stays_until_the_next_dictation() async throws {
        let rig = SessionRig()
        rig.recorder.startError = RecorderError.startFailed
        rig.hotkeys.send(.hotkeyDown, at: rig.clock.seconds)
        #expect(rig.session.notice == .microphoneUnavailable)

        rig.recorder.startError = nil
        await rig.pressAndConfirm()
        #expect(rig.session.notice == nil)

        let noticeEnd = rig.clock.now.advanced(by: .milliseconds(2500))
        rig.hotkeys.send(.cleanupToggle, at: rig.clock.seconds)
        await rig.clock.waitForSleeper(until: noticeEnd)
        rig.clock.advance(by: .milliseconds(2500))
        await until { rig.session.notice == nil }
        rig.release()
        await rig.session.shutdown()
    }

    @Test func another_microphone_taking_over_says_its_name_in_the_slot_and_recording_goes_on() async throws {
        let rig = SessionRig()
        await rig.pressAndConfirm()

        let noticeEnd = rig.clock.now.advanced(by: .milliseconds(2500))
        rig.recorder.switchMicrophone(to: "MacBook Pro Microphone")
        let slot = PillLabel(symbol: "mic.fill", text: "Switched to MacBook Pro Microphone")
        #expect(PillState(rig.session)?.capsule == .recording(slot: slot))

        await rig.clock.waitForSleeper(until: noticeEnd)
        rig.clock.advance(by: .milliseconds(2500))
        await until { rig.session.notice == nil }
        #expect(rig.session.phase == .recording)
        rig.release()
        await rig.session.shutdown()
    }
}
