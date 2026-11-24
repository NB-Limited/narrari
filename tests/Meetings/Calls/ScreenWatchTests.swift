import NarrariKit
import Testing

@MainActor
struct ScreenWatchTests {
    @Test func reports_each_state_within_a_second_of_the_change_and_asks_only_while_needed() async {
        let watcher = FakeScreenWatcher()
        let clock = TestClock()
        let watch = ScreenWatch(watcher: watcher, clock: clock)

        watch.ask(true)
        #expect(watch.state == .clear)

        watcher.answer.withLock { $0 = true }
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(1))
        await until { watch.state == .watched }

        watcher.answer.withLock { $0 = nil }
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(1))
        await until { watch.state == .unknown }

        watch.ask(false)
        #expect(clock.pendingSleepers == 0)
    }
}
