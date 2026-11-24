import Foundation
import NarrariKit
import Testing

struct MeetingTranscriptTests {
    private let folder = TemporaryFolder()
    private let settings = ThrowawaySettings()
    private let store: MeetingStore
    private let heard = Notes<String>()

    init() {
        store = MeetingStore(root: folder.url.appending(path: "Meetings"), trash: { _ in })
    }

    private func step(_ transcribe: @escaping MeetingTranscript.Transcribe) throws -> MeetingTranscript {
        let dictionary = DictionaryStore(root: folder.url)
        try dictionary.edit { $0 = WordList(replacements: [Replacement(phrase: "nb limited", text: "NB Limited")]) }
        let pipeline = TextPipeline(
            cleanup: CleanupService(engine: nil, settings: settings.store, clock: TestClock()),
            prompts: PromptStore(root: folder.url), dictionary: dictionary, settings: settings.store
        )
        return MeetingTranscript(transcribe: transcribe, pipeline: pipeline, ownerName: "Ana Petrova", modelName: { "Parakeet v3" })
    }

    private func step(_ words: [String: [Transcript.Word]]) throws -> MeetingTranscript {
        try step { [heard] url, _ in
            heard.add(url.lastPathComponent)
            return Transcript(text: "", audioSeconds: 0, words: words[url.lastPathComponent] ?? [])
        }
    }

    private func newMeeting(with tracks: [MeetingStore.Audio]) async throws -> UUID {
        let meeting = Meeting(title: "Weekly", startedAt: .now, app: "", source: .call, template: "general", state: .ready)
        try await store.create(meeting, appName: "Zoom")
        for track in tracks { try Data("caff".utf8).write(to: try await store.audio(track, of: meeting.id)) }
        return meeting.id
    }

    private func word(_ text: String, _ start: Double, _ end: Double) -> Transcript.Word {
        Transcript.Word(text: text, start: start, end: end)
    }

    @Test func words_split_at_a_one_second_pause_both_tracks_in_time_order_with_owner_and_placeholder_speaker() async throws {
        let id = try await newMeeting(with: [.microphone, .system])
        let words = MeetingTranscript.Words(
            mic: [word("We", 0, 0.3), word("chose", 0.4, 0.8), word("nb", 1.7, 1.9), word("limited.", 2.0, 2.5), word("Bye.", 3.5, 3.8)],
            system: [word("Sounds", 1.0, 1.4), word("good.", 1.5, 1.9)]
        )
        let step = try step(["mic.caf": words.mic, "system.caf": words.system])

        try await step.run(id, in: store)

        let segments = try await store.transcript(of: id)
        #expect(segments == [
            TranscriptSegment(start: 0, end: 2.5, speaker: MeetingTranscript.ownerID, text: "We chose NB Limited.", track: .mic),
            TranscriptSegment(start: 1.0, end: 1.9, speaker: MeetingTranscript.othersID, text: "Sounds good.", track: .system),
            TranscriptSegment(start: 3.5, end: 3.8, speaker: MeetingTranscript.ownerID, text: "Bye.", track: .mic)
        ])
        #expect(try await store.meeting(id).speakers == [
            Meeting.Speaker(id: MeetingTranscript.ownerID, name: "Ana Petrova"),
            Meeting.Speaker(id: MeetingTranscript.othersID, name: "Speaker 2")
        ])
        #expect(try await store.words(of: id) == words)
        #expect(try await store.meeting(id).speechModel == "Parakeet v3")
    }

    @Test func the_cleaned_microphone_track_is_heard_instead_and_a_missing_system_track_or_silence_is_no_error() async throws {
        let id = try await newMeeting(with: [.microphone, .cleanedMicrophone])

        try await step([:]).run(id, in: store)

        #expect(heard.all == ["mic.clean.caf"])
        #expect(try await store.transcript(of: id).isEmpty)
        #expect(try await store.meeting(id).speakers.isEmpty)
    }

    @Test func a_speech_model_not_on_this_mac_makes_the_step_wait() async throws {
        let id = try await newMeeting(with: [.microphone])
        let step = try step { _, _ in throw TranscriberError.notDownloaded }

        await #expect(throws: MeetingStepWaiting("Waiting for the speech model to be downloaded.")) { try await step.run(id, in: store) }
    }
}
