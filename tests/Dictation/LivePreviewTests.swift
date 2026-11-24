import NarrariKit
import Observation
import Testing

@MainActor
@Observable
private final class Published {
    var texts: [String] = []
}

// Captured by the preview's closures; it goes away only when the preview's loop has ended.
private final class Sentinel: Sendable {
    let released: Gate
    init(_ released: Gate) { self.released = released }
    deinit { released.open() }
}

@MainActor
struct LivePreviewTests {
    private let clock = TestClock()
    private let published = Published()
    private let recording = speech(seconds: 20)
    private let released = Gate()

    private func start(_ preview: LivePreview) {
        let sentinel = Sentinel(released)
        let recording = recording
        let published = published
        preview.start(reading: { count in Array(recording.suffix(count)) }, publish: { text in
            _ = sentinel
            published.texts.append(text)
        })
    }

    @Test func publishes_the_recent_window_at_each_interval() async {
        let preview = LivePreview(transcriber: FakeTranscriber { samples in Transcript(text: "\(samples.count)", audioSeconds: 0) }, clock: clock)
        start(preview)

        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(500))
        await until { published.texts.count == 1 }
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(500))
        await until { published.texts.count == 2 }

        #expect(published.texts == ["224000", "224000"])
        preview.stop()
    }

    @Test func stop_ends_the_loop_without_publishing() async throws {
        let preview = LivePreview(transcriber: FakeTranscriber(text: "never"), clock: clock)
        start(preview)
        await clock.waitForSleepers(1)

        preview.stop()
        try await released.pass()

        #expect(clock.pendingSleepers == 1)
        #expect(published.texts.isEmpty)
    }

    @Test func result_arriving_after_stop_is_dropped() async throws {
        let late = Gate(honoursCancellation: false)
        let preview = LivePreview(transcriber: FakeTranscriber(text: "late words", gate: late), clock: clock)
        start(preview)
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(500))
        await late.waitForArrivals(1)

        preview.stop()
        late.open()
        try await released.pass()

        #expect(published.texts.isEmpty)
    }

    @Test func instance_loads_when_a_dictation_starts_and_not_before() async {
        let transcriber = FakeTranscriber(text: "hello")
        let preview = LivePreview(transcriber: transcriber, clock: clock)
        #expect(transcriber.loads.arrivals == 0)

        start(preview)
        await clock.waitForSleepers(1)

        #expect(transcriber.loads.arrivals == 1)
        preview.stop()
    }

    @Test func instance_unloads_once_idle_for_the_limit() async {
        let transcriber = FakeTranscriber(text: "hello")
        let preview = LivePreview(transcriber: transcriber, clock: clock)
        start(preview)
        await clock.waitForSleepers(1)

        preview.stop()
        await clock.waitForSleepers(1)
        clock.advance(by: LivePreview.idleLimit - .seconds(1))
        #expect(clock.pendingSleepers == 1)
        clock.advance(by: .seconds(1))

        await transcriber.unloads.waitForArrivals(1)
    }

    @Test func dictation_inside_the_idle_limit_keeps_the_instance() async {
        let transcriber = FakeTranscriber(text: "hello")
        let preview = LivePreview(transcriber: transcriber, clock: clock)
        start(preview)
        await clock.waitForSleepers(1)
        preview.stop()
        await clock.waitForSleepers(1)
        clock.advance(by: LivePreview.idleLimit - .seconds(1))

        start(preview)
        await transcriber.loads.waitForArrivals(2)
        await clock.waitForSleepers(1)
        clock.advance(by: LivePreview.idleLimit)

        #expect(transcriber.unloads.arrivals == 0)
        preview.stop()
    }

    @Test func release_unloads_after_the_pass_in_flight_and_loads_nothing_after() async throws {
        let pass = Gate(honoursCancellation: false)
        let transcriber = FakeTranscriber(text: "late words", gate: pass)
        let preview = LivePreview(transcriber: transcriber, clock: clock)
        start(preview)
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(500))
        await pass.waitForArrivals(1)

        let releasing = Task { await preview.release() }
        pass.open()
        await releasing.value
        clock.advance(by: LivePreview.idleLimit)

        #expect(transcriber.unloads.arrivals == 1)
        #expect(!transcriber.wasUnloadedDuringPass)
        #expect(transcriber.loads.arrivals == 1)
        #expect(clock.pendingSleepers == 0)
        #expect(published.texts.isEmpty)
    }
}
