import Foundation
import NarrariKit
import Observation
import Testing

@MainActor
@Observable
private final class Heard {
    var events: [CallEvent] = []
}

@MainActor
struct CallDetectorTests {
    private let processes = FakeProcesses()
    private let clock = TestClock()
    private let settings = ThrowawaySettings()
    private let heard = Heard()

    private func detector() async -> (CallDetector, Task<Void, Never>) {
        let detector = CallDetector(processes: processes, settings: settings.store, clock: clock)
        await detector.start()
        let listening = Task { [heard] in
            for await event in detector.events { heard.events.append(event) }
        }
        return (detector, listening)
    }

    // The 2-second recheck sleeps on the same clock, so only the hold's deadline proves the hold is asleep.
    private func held() async {
        await clock.waitForSleeper(until: clock.now.advanced(by: .seconds(3)))
    }

    private func zoom(input: Bool, output: Bool) -> AudioProcess {
        FakeProcesses.app("us.zoom.xos", input: input, output: output)
    }

    @Test func another_app_holding_the_microphone_for_3_seconds_raises_one_call_and_a_second_app_none() async {
        let (detector, listening) = await detector()

        await processes.set([zoom(input: true, output: true)])
        await held()
        clock.advance(by: .seconds(3))
        await until { heard.events == [.started(app: "us.zoom.xos")] }

        await processes.set([zoom(input: true, output: true), FakeProcesses.app("com.microsoft.teams2", input: true, output: false)])
        clock.advance(by: .seconds(10))
        await detector.stop()
        await listening.value

        #expect(heard.events == [.started(app: "us.zoom.xos")])
    }

    @Test func narraris_own_microphone_and_a_use_under_3_seconds_raise_no_call() async {
        let ownDictation = FakeProcesses.app("com.nb-limited.narrari", input: true, output: true, pid: getpid())
        _ = await detector()

        await processes.set([ownDictation, zoom(input: true, output: false)])
        await held()
        clock.advance(by: .seconds(2))
        await processes.set([ownDictation, zoom(input: false, output: false)])
        await processes.set([ownDictation, FakeProcesses.app("com.microsoft.teams2", input: true, output: true)])
        await clock.waitForSleeper(until: .init(offset: .seconds(5)))
        clock.advance(by: .seconds(3))

        await until { heard.events == [.started(app: "com.microsoft.teams2")] }
    }

    // Some apps let go of the microphone on mute, so the sound they still play keeps the call going.
    @Test(arguments: [true, false])
    func the_call_ends_only_once_its_app_has_released_the_microphone_and_stopped_playing(isStillPlaying: Bool) async {
        let (detector, listening) = await detector()
        await processes.set([zoom(input: true, output: true)])
        await held()
        clock.advance(by: .seconds(3))
        await until { heard.events == [.started(app: "us.zoom.xos")] }

        await processes.set([zoom(input: false, output: isStillPlaying)])
        await detector.stop()
        await listening.value

        #expect(heard.events == (isStillPlaying ? [.started(app: "us.zoom.xos")] : [.started(app: "us.zoom.xos"), .ended]))
    }

    // A browser call holds the microphone in a helper process; its notice and its folder must name the browser.
    @Test(arguments: [
        ("com.google.Chrome.helper", "com.google.Chrome"), ("com.microsoft.edgemac.helper.renderer", "com.microsoft.edgemac"),
        ("com.apple.WebKit.GPU", "com.apple.Safari"), ("us.zoom.xos", "us.zoom.xos")
    ])
    func a_call_from_a_helper_process_is_reported_under_the_app_that_owns_it(helper: String, app: String) async {
        let (detector, listening) = await detector()

        await processes.set([FakeProcesses.app(helper, input: true, output: true)])
        await held()
        clock.advance(by: .seconds(3))
        await until { heard.events == [.started(app: app)] }
        await processes.set([FakeProcesses.app(helper, input: false, output: false)])
        await detector.stop()
        await listening.value

        #expect(heard.events == [.started(app: app), .ended])
    }

    // Core Audio tells nothing when an app already playing takes the microphone, nor of every release.
    @Test func a_microphone_taken_or_let_go_with_no_notice_is_found_within_2_seconds() async {
        let (detector, listening) = await detector()

        await processes.set([zoom(input: false, output: true)], isTold: false)
        await processes.set([zoom(input: true, output: true)], isTold: false)
        await clock.waitForSleeper(until: .init(offset: .seconds(2)))
        clock.advance(by: .seconds(2))
        await held()
        clock.advance(by: .seconds(3))
        await until { heard.events == [.started(app: "us.zoom.xos")] }

        await processes.set([zoom(input: false, output: false)], isTold: false)
        await clock.waitForSleeper(until: .init(offset: .seconds(7)))
        clock.advance(by: .seconds(2))
        await until { heard.events == [.started(app: "us.zoom.xos"), .ended] }
        await detector.stop()
        await listening.value
    }

    // As at a call's start, when the headset switches to its call mode.
    @Test func a_microphone_taken_let_go_and_taken_again_unannounced_still_raises_the_call() async {
        _ = await detector()

        await processes.set([zoom(input: true, output: true)])
        await held()
        clock.advance(by: .milliseconds(500))
        await processes.set([zoom(input: false, output: true)])
        await processes.set([zoom(input: true, output: true)], isTold: false)
        await clock.waitForSleeper(until: .init(offset: .seconds(2)))
        clock.advance(by: .milliseconds(1_500))
        await held()
        clock.advance(by: .seconds(3))

        await until { heard.events == [.started(app: "us.zoom.xos")] }
    }
}
