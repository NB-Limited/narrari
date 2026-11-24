import NarrariKit
import Testing

@MainActor
struct TimedFlagTests {
    @Test func a_label_shows_only_after_the_delay_and_a_quick_leave_never_shows_it() async {
        let clock = TestClock()
        let label = TimedFlag(clock: clock)

        label.turnOn(after: .milliseconds(400))
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(399))
        #expect(!label.isOn)
        label.turnOff()
        clock.advance(by: .seconds(1))
        #expect(!label.isOn)
        #expect(clock.pendingSleepers == 0)

        label.turnOn(after: .milliseconds(400))
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(400))
        await until { label.isOn }
    }

    @Test func copied_holds_then_goes_and_a_second_copy_restarts_the_hold() async {
        let clock = TestClock()
        let copied = TimedFlag(clock: clock)

        copied.turnOn(for: .milliseconds(1500))
        #expect(copied.isOn)
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(1000))

        copied.turnOn(for: .milliseconds(1500))
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(1000))
        #expect(copied.isOn)

        clock.advance(by: .milliseconds(500))
        await until { !copied.isOn }
    }
}
