import Foundation
import NarrariKit
import Testing

@MainActor
struct DictationSessionSilenceTests {
    // The press comes at 0 on the test clock.
    private let silenceDue = TestClock.Instant(offset: .seconds(2))

    @Test func two_seconds_of_nothing_names_the_microphone_until_sound_arrives() async {
        let rig = SessionRig()
        await rig.pressAndConfirm()
        await rig.clock.waitForSleeper(until: silenceDue)

        rig.clock.advance(by: .milliseconds(1700))
        #expect(rig.session.silentMicrophone == nil)
        rig.clock.advance(by: .milliseconds(100))
        await until { rig.session.silentMicrophone == "MacBook Pro Microphone" }
        #expect(PillState(rig.session)?.silentMicrophone == "MacBook Pro Microphone")

        rig.recorder.hearSound()
        #expect(rig.session.silentMicrophone == nil)
        rig.release()
        await rig.session.shutdown()
    }

    // The switch notice's expiry runs after any silence check due before it, so its end shows none was raised.
    @Test func sound_heard_once_makes_later_silence_and_switches_a_pause() async {
        let rig = SessionRig()
        rig.recorder.hearSound()
        await rig.pressAndConfirm()
        await rig.clock.waitForSleeper(until: silenceDue)
        rig.clock.advance(by: .milliseconds(1900))

        let expiry = rig.clock.now.advanced(by: .milliseconds(2500))
        rig.recorder.switchMicrophone(to: "AirPods Pro")
        await rig.clock.waitForSleeper(until: expiry)
        rig.clock.advance(by: .seconds(5))
        await until { rig.session.notice == nil }

        #expect(rig.session.silentMicrophone == nil)
        rig.release()
        await rig.session.shutdown()
    }

    @Test func a_switch_restarts_the_count_for_the_new_microphone() async {
        let rig = SessionRig()
        await rig.pressAndConfirm()
        await rig.clock.waitForSleeper(until: silenceDue)
        rig.clock.advance(by: .milliseconds(1300))

        let restarted = rig.clock.now.advanced(by: .seconds(2))
        rig.recorder.switchMicrophone(to: "AirPods Pro")
        await rig.clock.waitForSleeper(until: restarted)
        rig.clock.advance(by: .milliseconds(1900))
        #expect(rig.session.silentMicrophone == nil)
        rig.clock.advance(by: .milliseconds(100))

        await until { rig.session.silentMicrophone == "AirPods Pro" }
        rig.release()
        await rig.session.shutdown()
    }
}
