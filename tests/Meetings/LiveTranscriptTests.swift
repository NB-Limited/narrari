import AVFoundation
import NarrariKit
import Synchronization
import Testing

@MainActor
struct LiveTranscriptTests {
    private let folder = TemporaryFolder()
    private let settings = ThrowawaySettings()
    private let recognisers = FakeLiveSpeech()
    private let replay = Replay(microphone: speech(seconds: 1), system: speech(seconds: 1))
    private let recorder: MeetingRecorder
    private let live: LiveTranscript

    init() {
        let replay = replay
        recorder = MeetingRecorder(
            settings: settings.store,
            permissions: Permissions(settings: settings.store, access: .fixed(), microphoneStatus: { .authorized }),
            inputs: replay, system: replay, freeSpace: { _ in nil }, hostNow: { replay.clock.hostTime }, clock: TestClock()
        )
        live = LiveTranscript(recorder: recorder, speech: recognisers, settings: settings.store)
    }

    @Test func final_words_become_you_and_others_lines_in_spoken_order_waiting_words_are_replaced_and_the_lines_outlast_the_meeting() async {
        live.start()
        await until { live.isListening }

        recognisers.send(LiveEdit(retained: 0, stable: 0, tokens: [word(" Hello", at: 1), word(" there", at: 1.4)]), on: .mic)
        await until { live.pending[.mic] == "Hello there" }
        recognisers.send(LiveEdit(retained: 1, stable: 2, tokens: [word(" there,", at: 1.4)]), on: .mic)
        await until { live.lines.count == 1 }
        recognisers.send(LiveEdit(retained: 0, stable: 1, tokens: [word(" Hi", at: 2), word(" you", at: 2.4)]), on: .system)
        await until { live.lines.count == 2 }
        recognisers.send(LiveEdit(retained: 2, stable: 3, tokens: [word(" Bye", at: 2.6)]), on: .mic)
        await until { live.lines.count == 3 }

        #expect(live.lines.map { "\($0.speaker): \($0.text)" } == ["You: Hello there,", "Others: Hi", "You: Bye"])
        #expect(live.pending[.mic] == nil)
        #expect(live.pending[.system] == "you")
        await live.stop()
        #expect(live.lines.count == 3)
        #expect(live.pending.isEmpty)
    }

    @Test func a_failed_recogniser_stops_live_text_with_one_notice_and_the_recording_carries_on() async throws {
        try recorder.start(in: folder.url)
        live.start()
        await until { live.isListening }
        replay.play(seconds: 5)

        recognisers.fail(.system)
        await until { live.notice == .failed }
        await recognisers.unloads.waitForPasses(1)
        replay.play(seconds: 5)
        _ = recorder.stop()

        #expect(!live.isListening)
        #expect(heard(.mic, about: 5))
        #expect(try length(of: "mic.caf") == 10 * 16_000)
        #expect(try length(of: "system.caf") == 10 * 16_000)
        await live.stop()
    }

    @Test func live_text_off_loads_no_model_and_switching_it_mid_meeting_hears_only_that_span_and_keeps_the_files_whole() async throws {
        settings.store.set(false, for: MeetingsSettings.showsLiveText)
        try recorder.start(in: folder.url)
        live.start()
        replay.play(seconds: 4)
        #expect(recognisers.loads.arrivals == 0)

        settings.store.set(true, for: MeetingsSettings.showsLiveText)
        await until { live.isListening }
        replay.play(seconds: 6)
        settings.store.set(false, for: MeetingsSettings.showsLiveText)
        await until { !live.isListening }
        await recognisers.unloads.waitForPasses(1)
        replay.play(seconds: 5)
        _ = recorder.stop()

        #expect(heard(.mic, about: 6))
        #expect(heard(.system, about: 6))
        #expect(try length(of: "mic.caf") == 15 * 16_000)
        #expect(try length(of: "system.caf") == 15 * 16_000)
        await live.stop()
    }

    @Test func a_paused_meeting_gives_the_recognisers_nothing_to_hear() async throws {
        try recorder.start(in: folder.url)
        live.start()
        await until { live.isListening }

        replay.play(seconds: 10)
        recorder.pause()
        replay.play(seconds: 7)
        recorder.resume()
        replay.play(seconds: 10)
        _ = recorder.stop()

        #expect(heard(.mic, about: 20))
        #expect(heard(.system, about: 20))
        await live.stop()
    }

    @Test func only_the_newest_lines_are_kept() async {
        live.start()
        await until { live.isListening }

        let words = (0...LiveTranscript.maximumLines).map { word(" w\($0)", at: Double($0) * 2) }
        recognisers.send(LiveEdit(retained: 0, stable: words.count, tokens: words), on: .mic)
        await until { live.lines.last?.text == "w\(LiveTranscript.maximumLines)" }

        #expect(live.lines.count == LiveTranscript.maximumLines)
        #expect(live.lines.first?.text == "w1")
        await live.stop()
    }

    private func word(_ text: String, at start: Double) -> LiveEdit.Token {
        LiveEdit.Token(text: text, start: start, end: start + 0.3)
    }

    // Within one 100 ms buffer: the recorder drops a buffer that straddles a resume and pads the file in its place.
    private func heard(_ track: TranscriptSegment.Track, about seconds: Double) -> Bool {
        abs(Double(recognisers.heard(track)) / 16_000 - seconds) <= 0.1
    }

    private func length(of name: String) throws -> Int {
        Int(try AVAudioFile(forReading: folder.url.appending(path: name)).length)
    }
}

// Both tracks' recognisers, run by the test: it sends their edits or makes one fail, and counts what they heard.
private final class FakeLiveSpeech: LiveSpeech {
    private struct State {
        var outputs: [TranscriptSegment.Track: AsyncThrowingStream<LiveEdit, any Error>.Continuation] = [:]
        var heard: [TranscriptSegment.Track: Int] = [:]
    }

    private struct Broken: Error {}

    let loads = Gate.counter()
    let unloads = Gate.counter()
    private let state = Mutex(State())

    func load() async throws {
        try await loads.pass()
    }

    func edits(for track: TranscriptSegment.Track) -> AsyncThrowingStream<LiveEdit, any Error> {
        let (edits, output) = AsyncThrowingStream<LiveEdit, any Error>.makeStream()
        state.withLock { $0.outputs[track] = output }
        return edits
    }

    func hear(_ samples: UnsafeBufferPointer<Float>, at position: Double, on track: TranscriptSegment.Track) {
        state.withLock { $0.heard[track, default: 0] += samples.count }
    }

    func unload() async {
        let outputs = state.withLock { state in
            defer { state.outputs = [:] }
            return state.outputs.values
        }
        outputs.forEach { $0.finish() }
        try? await unloads.pass()
    }

    func send(_ edit: LiveEdit, on track: TranscriptSegment.Track) {
        _ = state.withLock { $0.outputs[track] }?.yield(edit)
    }

    func fail(_ track: TranscriptSegment.Track) {
        state.withLock { $0.outputs[track] }?.finish(throwing: Broken())
    }

    func heard(_ track: TranscriptSegment.Track) -> Int {
        state.withLock { $0.heard[track] ?? 0 }
    }
}
