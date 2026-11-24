import Foundation
import NarrariKit
import Testing

struct EchoRemovalTests {
    private let folder = TemporaryFolder()
    private let store: MeetingStore
    private let cancelled = Notes<[String]>()
    private static let rate = 16_000.0
    private static let seconds = 13.0
    private static let owner = [0.5...3.0, 7.0...9.5]
    private static let far = [3.5...6.5, 10.0...12.5]

    init() {
        store = MeetingStore(root: folder.url, trash: { _ in })
    }

    // Speech found by loudness, so the test needs no model; the fake canceller writes a file and notes what it was given.
    private var removal: EchoRemoval {
        EchoRemoval(findSpeech: { track in
            let reader = try TrackReader(track)
            var blocks: [Bool] = []
            while let block = try reader.next(Int(SpeechDetector.blockSeconds * Self.rate)) {
                blocks.append(block.map { $0 * $0 }.reduce(0, +) / Float(block.count) > 1e-4)
            }
            return blocks
        }, cancel: { [cancelled] microphone, reference, output in
            cancelled.add([microphone, reference, output].map(\.lastPathComponent))
            try Data("clean".utf8).write(to: output)
        })
    }

    // Noise that rises and falls three times a second, like syllables, in the given spans.
    private static func voice(_ spans: [ClosedRange<Double>], seed: UInt64) -> [Float] {
        var state = seed
        var samples = [Float](repeating: 0, count: Int(seconds * rate))
        for span in spans {
            for index in Int(span.lowerBound * rate)..<Int(span.upperBound * rate) {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let noise = Float(state >> 40) / Float(1 << 24) * 2 - 1
                let syllable = Float(sin(Double.pi * 3 * Double(index) / rate))
                samples[index] = 0.3 * noise * syllable * syllable
            }
        }
        return samples
    }

    private func newMeeting(echoLevel: Float?) async throws -> UUID {
        let meeting = Meeting(title: "Weekly", startedAt: .now, app: "", source: .call, template: "general", state: .ready)
        try await store.create(meeting, appName: "")
        var microphone = Self.voice(Self.owner, seed: 1)
        let system = Self.voice(Self.far, seed: 2)
        if let echoLevel {
            let delay = Int(0.1 * Self.rate)
            for index in delay..<microphone.count { microphone[index] += echoLevel * system[index - delay] }
        }
        try write(microphone, to: try await store.audio(.microphone, of: meeting.id))
        try write(system, to: try await store.audio(.system, of: meeting.id))
        return meeting.id
    }

    private func write(_ samples: [Float], to url: URL) throws {
        let writer = try TrackWriter(writingTo: url, sourceRate: Self.rate)
        samples.withUnsafeBufferPointer { writer.append($0, at: 0) }
        writer.finish(at: Self.seconds)
    }

    @Test func the_far_side_heard_by_the_microphone_is_removed_into_a_cleaned_track_and_mic_caf_stays_as_recorded() async throws {
        let id = try await newMeeting(echoLevel: 0.25)
        let microphone = try await store.audio(.microphone, of: id)
        let recorded = try Data(contentsOf: microphone)

        try await removal.run(id, in: store)

        #expect(cancelled.all == [["mic.caf", "system.caf", "mic.clean.caf"]])
        #expect(FileManager.default.fileExists(atPath: try await store.audio(.cleanedMicrophone, of: id).path))
        #expect(try Data(contentsOf: microphone) == recorded)
    }

    @Test func with_headphones_removal_is_skipped_and_an_older_cleaned_track_goes() async throws {
        let id = try await newMeeting(echoLevel: nil)
        let cleaned = try await store.audio(.cleanedMicrophone, of: id)
        try Data("old".utf8).write(to: cleaned)

        try await removal.run(id, in: store)

        #expect(cancelled.all.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: cleaned.path))
    }

    @Test func a_meeting_without_system_sound_needs_no_model_and_a_missing_model_makes_the_step_wait() async throws {
        let id = try await newMeeting(echoLevel: 0.25)
        let missing = EchoRemoval(findSpeech: { _ in throw AudioModelError.notDownloaded }, cancel: { _, _, _ in })

        await #expect(throws: MeetingStepWaiting("Waiting for the echo removal models to be downloaded.")) {
            try await missing.run(id, in: store)
        }
        try FileManager.default.removeItem(at: try await store.audio(.system, of: id))
        try await missing.run(id, in: store)
    }
}
