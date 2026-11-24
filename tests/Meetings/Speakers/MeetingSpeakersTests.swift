import Foundation
import NarrariKit
import Synchronization
import Testing

struct MeetingSpeakersTests {
    private let folder = TemporaryFolder()
    private let settings = ThrowawaySettings()
    private let store: MeetingStore
    private let memory: VoiceMemory

    init() {
        store = MeetingStore(root: folder.url.appending(path: "Meetings"), trash: { _ in })
        memory = VoiceMemory(folder: folder.url)
    }

    private var step: MeetingSpeakers {
        let pipeline = TextPipeline(
            cleanup: CleanupService(engine: nil, settings: settings.store, clock: TestClock()),
            prompts: PromptStore(root: folder.url), dictionary: DictionaryStore(root: folder.url), settings: settings.store
        )
        return MeetingSpeakers(
            split: { [splits] in splits.result(for: $0.lastPathComponent, speakers: $1) }, memory: memory, pipeline: pipeline,
            settings: settings.store, ownerName: "Ana Petrova"
        )
    }

    private let splits = Splits()

    // What the fake split gives for each track of the meeting run next, and how many speakers each was asked for.
    private final class Splits: Sendable {
        private let byTrack = Mutex<[String: SpeakerSplit]>([:])
        let asked = Mutex<[String: Int?]>([:])

        func set(_ splits: [String: SpeakerSplit]) {
            byTrack.withLock { $0 = splits }
        }

        func result(for track: String, speakers: Int?) -> SpeakerSplit {
            asked.withLock { $0[track] = speakers }
            return byTrack.withLock { $0[track] } ?? SpeakerSplit(turns: [], prints: [:])
        }
    }

    private func meeting(mic: [Transcript.Word], system: [Transcript.Word] = [], attendees: [String] = []) async throws -> UUID {
        var meeting = Meeting(title: "Weekly", startedAt: .now, app: "", source: .call, template: "general", state: .ready)
        meeting.attendees = attendees.map { Meeting.Attendee(name: $0, source: .calendar) }
        try await store.create(meeting, appName: "Zoom")
        try Data("caff".utf8).write(to: try await store.audio(.microphone, of: meeting.id))
        if !system.isEmpty { try Data("caff".utf8).write(to: try await store.audio(.system, of: meeting.id)) }
        try await store.write(MeetingTranscript.Words(mic: mic, system: system), of: meeting.id)
        return meeting.id
    }

    private func word(_ text: String, _ start: Double) -> Transcript.Word {
        Transcript.Word(text: text, start: start, end: start + 0.4)
    }

    private func turn(_ speaker: String, _ start: Double, _ end: Double) -> SpeakerSplit.Turn {
        SpeakerSplit.Turn(speaker: speaker, start: start, end: end)
    }

    private func names(_ id: UUID) async throws -> [String] {
        try await store.meeting(id).speakers.map(\.name)
    }

    @Test func a_transcript_without_word_timings_fails_saying_to_transcribe_again() async throws {
        let meeting = Meeting(title: "Weekly", startedAt: .now, app: "", source: .call, template: "general", state: .ready)
        try await store.create(meeting, appName: "Zoom")

        await #expect(throws: MeetingSpeakers.Failure.noWordTimings) { try await step.run(meeting.id, in: store) }
        #expect(MeetingProcessing.Step.speakers.problem("speakers.no-word-timings").message
            == "The transcript has no word timings. Transcribe the meeting again.")
    }

    // The owner's voice is learned from a two-track meeting, as the first meeting of each test that needs it.
    private func learnOwner() async throws {
        splits.set(["mic.caf": SpeakerSplit(turns: [turn("S1", 0, 20)], prints: ["S1": voicePrint(0)])])
        try await step.run(try await meeting(mic: [word("Hello", 0)], system: [word("Hi", 1)]), in: store)
    }

    @Test func two_tracks_split_system_sound_cut_at_each_change_fold_a_short_speaker_and_learn_only_the_owner() async throws {
        let id = try await meeting(
            mic: [word("Hello", 0), word("there.", 0.5)],
            system: [word("Budget", 11.2), word("fine.", 11.7), word("Agreed", 12.2), word("then.", 12.7), word("Yes.", 24.4)]
        )
        splits.set([
            "mic.caf": SpeakerSplit(turns: [turn("S1", 0, 1)], prints: ["S1": voicePrint(0)]),
            "system.caf": SpeakerSplit(
                turns: [turn("S1", 1, 12), turn("S2", 12.3, 24), turn("S3", 24.2, 25)],
                prints: ["S1": voicePrint(1), "S2": voicePrint(2), "S3": voicePrint(3)]
            )
        ])

        try await step.run(id, in: store)

        let transcript = try await store.transcript(of: id).map { "\($0.speaker): \($0.text)" }
        #expect(transcript == ["owner: Hello there.", "speaker-2: Budget fine.", "speaker-3: Agreed then.", "speaker-3: Yes."])
        let people = try await memory.people()
        #expect(people.map(\.name) == ["Ana Petrova"])
        #expect(people.first?.prints.map(\.values) == [voicePrint(0)])
        #expect(try await store.meeting(id).speakers == [
            Meeting.Speaker(id: "owner", name: "Ana Petrova", personId: people.first?.id),
            Meeting.Speaker(id: "speaker-2", name: "Speaker 2"),
            Meeting.Speaker(id: "speaker-3", name: "Speaker 3")
        ])
        #expect(try await store.voices(of: id).keys.sorted() == ["owner", "speaker-2", "speaker-3"])
    }

    // The voice taking turns with the owner is numbered after the far side; the speakers' echo is dropped, and a voice
    // near the owner's or too short to tell stays the owner.
    @Test func in_a_call_a_second_voice_on_the_microphone_is_its_own_speaker_but_echo_and_the_owner_split_in_two_are_not() async throws {
        let mic = [word("Hello", 0), word("Morning", 12), word("Budget", 41), word("Right", 56), word("Yes", 71)]
        let id = try await meeting(mic: mic, system: [word("Budget", 40), word("Fine", 45)])
        splits.set([
            "mic.caf": SpeakerSplit(
                turns: [
                    turn("S1", 0, 10), turn("S2", 11, 17), turn("S1", 18, 24), turn("S2", 25, 32), turn("S3", 40, 52), turn("S4", 55, 67),
                    turn("S5", 70, 72)
                ],
                prints: ["S1": voicePrint(0), "S2": voicePrint(5), "S3": voicePrint(6), "S4": voicePrint(0, distance: 0.2), "S5": voicePrint(7)]
            ),
            "system.caf": SpeakerSplit(turns: [turn("S1", 38, 53)], prints: ["S1": voicePrint(1)])
        ])

        try await step.run(id, in: store)

        #expect(try await names(id) == ["Ana Petrova", "Speaker 2", "Speaker 3"])
        let mine = try await store.transcript(of: id).filter { $0.track == .mic }.map { "\($0.speaker): \($0.text)" }
        #expect(mine == ["owner: Hello", "speaker-3: Morning", "owner: Right", "owner: Yes"])
        #expect(try await store.voices(of: id)["speaker-3"] == voicePrint(5))
    }

    @Test func people_on_your_side_chosen_split_the_microphone_into_that_many_however_close_or_short() async throws {
        let id = try await meeting(mic: [word("Hello", 0), word("Morning", 22)], system: [word("Budget", 40)])
        try await store.update(id) { $0.ownSideCount = 2 }
        splits.set(["mic.caf": SpeakerSplit(
            turns: [turn("S1", 0, 20), turn("S2", 21, 24)], prints: ["S1": voicePrint(0), "S2": voicePrint(0, distance: 0.1)]
        )])

        try await step.run(id, in: store)

        #expect(splits.asked.withLock { $0["mic.caf"] } == 2)
        #expect(try await store.transcript(of: id).filter { $0.track == .mic }.map(\.speaker) == ["owner", "speaker-3"])
    }

    @Test func on_one_track_the_voice_nearest_the_owners_print_is_the_owner_and_nothing_is_learned_without_asking() async throws {
        try await learnOwner()
        try await memory.rename(try #require(try await memory.people().first).id, to: "Ana P.")
        let id = try await meeting(mic: [word("Welcome", 0), word("Thanks", 12), word("Right", 25)])
        splits.set([
            "mic.caf": SpeakerSplit(
                turns: [turn("S1", 11, 22), turn("S2", 0, 10.5), turn("S3", 24, 36)],
                prints: ["S1": voicePrint(4), "S2": voicePrint(0, distance: 0.1)]
            )
        ])

        try await step.run(id, in: store)

        #expect(try await names(id) == ["Ana P.", "Speaker 2", "Speaker 3"])
        #expect(try await store.transcript(of: id).map(\.speaker) == ["speaker-1", "speaker-2", "speaker-3"])
        #expect(try await memory.people().first?.prints.count == 1)
    }

    @Test func the_one_person_invited_names_the_one_other_voice_as_a_guess_but_never_a_voice_too_short_to_print() async throws {
        let system = [word("Hi", 1)]
        let guessed = try await meeting(mic: [word("Hello", 0)], system: system, attendees: ["Boris Ivanov"])
        splits.set(["system.caf": SpeakerSplit(turns: [turn("S1", 0, 30)], prints: ["S1": voicePrint(1)])])
        try await step.run(guessed, in: store)
        let unprinted = try await meeting(mic: [word("Hello", 0)], system: system, attendees: ["Boris Ivanov"])
        splits.set(["system.caf": SpeakerSplit(turns: [turn("S1", 0, 30)], prints: [:])])
        try await step.run(unprinted, in: store)

        #expect(try await store.meeting(guessed).speakers.last == Meeting.Speaker(id: "speaker-2", name: "Boris Ivanov", isGuess: true))
        #expect(try await names(unprinted) == ["Ana Petrova", "Speaker 2"])
    }

    @Test func names_merges_and_not_this_person_the_user_chose_all_survive_finding_speakers_again() async throws {
        let renaming = SpeakerRenaming(store: store, memory: memory, settings: settings.store)
        var earlier = Meeting(title: "Earlier", startedAt: .now, app: "", source: .call, template: "general", state: .ready)
        earlier.speakers = [Meeting.Speaker(id: "speaker-2", name: "Speaker 2")]
        try await store.create(earlier, appName: "Zoom")
        try await store.write(voices: ["speaker-2": voicePrint(3)], of: earlier.id)
        try await renaming.rename("speaker-2", in: earlier.id, to: "Maria Petrova")
        let id = try await meeting(mic: [word("Hello", 0)], system: [word("Budget", 1), word("Fine", 12.5), word("Yes", 25), word("No", 37)])
        splits.set(["system.caf": SpeakerSplit(
            turns: [turn("S1", 0, 12), turn("S2", 12.2, 24), turn("S3", 24.2, 36), turn("S4", 36.2, 48)],
            prints: ["S1": voicePrint(1), "S2": voicePrint(2), "S3": voicePrint(3), "S4": voicePrint(4)]
        )])
        try await step.run(id, in: store)
        #expect(try await names(id).dropFirst() == ["Speaker 2", "Speaker 3", "Maria Petrova", "Speaker 5"])
        try await renaming.rename("speaker-2", in: id, to: "Boris Ivanov")
        settings.store.set(false, for: MeetingsSettings.usesVoiceMemory)
        try await renaming.rename("speaker-3", in: id, to: "Lena Fischer")
        settings.store.set(true, for: MeetingsSettings.usesVoiceMemory)
        try await renaming.notThisPerson("speaker-4", in: id)
        try await renaming.merge("speaker-5", into: "speaker-2", in: id)

        try await step.run(id, in: store)

        let boris = try #require(try await memory.people().first { $0.name == "Boris Ivanov" })
        #expect(boris.prints.map(\.values) == [voicePrint(1)])
        #expect(try await store.meeting(id).speakers.dropFirst() == [
            Meeting.Speaker(id: "speaker-2", name: "Boris Ivanov", personId: boris.id, isNamedByUser: true),
            Meeting.Speaker(id: "speaker-3", name: "Lena Fischer", isNamedByUser: true),
            Meeting.Speaker(id: "speaker-4", name: "Speaker 4")
        ])
        #expect(try await store.transcript(of: id).map(\.speaker) == ["owner", "speaker-2", "speaker-3", "speaker-4", "speaker-2"])
    }

    @Test func a_name_given_before_speakers_are_found_goes_to_the_one_heard_most_and_is_remembered() async throws {
        let renaming = SpeakerRenaming(store: store, memory: memory, settings: settings.store)
        let id = try await meeting(mic: [word("Hello", 0)], system: [word("Hi", 1), word("Budget", 12.5), word("is", 13), word("fine", 14)])
        try await store.update(id) { $0.speakers = [Meeting.Speaker(id: "owner", name: "Ana Petrova"), Meeting.Speaker(id: "others", name: "Speaker 2")] }
        try await renaming.rename("others", in: id, to: "Boris Ivanov")
        splits.set(["system.caf": SpeakerSplit(
            turns: [turn("S1", 0, 12), turn("S2", 12.2, 24)], prints: ["S1": voicePrint(1), "S2": voicePrint(2)]
        )])

        try await step.run(id, in: store)

        let boris = try #require(try await memory.people().first { $0.name == "Boris Ivanov" })
        #expect(boris.prints.map(\.values) == [voicePrint(2)])
        #expect(try await names(id).dropFirst() == ["Speaker 2", "Boris Ivanov"])
    }

    @Test func a_number_of_people_chosen_is_asked_of_the_other_side_only_and_keeps_someone_who_said_little() async throws {
        let id = try await meeting(mic: [word("Hello", 0)], system: [word("Budget", 1), word("Fine", 12.5), word("Yes", 25.2)])
        try await store.update(id) { $0.speakerCount = 3 }
        splits.set([
            "mic.caf": SpeakerSplit(turns: [turn("S1", 0, 20)], prints: ["S1": voicePrint(0)]),
            "system.caf": SpeakerSplit(turns: [turn("S1", 0, 12), turn("S2", 12.2, 24), turn("S3", 25, 26)], prints: [:])
        ])

        try await step.run(id, in: store)

        let asked: [String: Int?] = ["mic.caf": nil, "system.caf": 3]
        #expect(splits.asked.withLock { $0 } == asked)
        #expect(try await names(id) == ["Ana Petrova", "Speaker 2", "Speaker 3", "Speaker 4"])
    }

    @Test func with_voice_memory_off_nothing_is_stored_or_matched() async throws {
        try await learnOwner()
        settings.store.set(false, for: MeetingsSettings.usesVoiceMemory)
        let twoTracks = try await meeting(mic: [word("Hello", 0)], system: [word("Hi", 1)])
        splits.set(["mic.caf": SpeakerSplit(turns: [turn("S1", 0, 20)], prints: ["S1": voicePrint(0, distance: 0.05)])])
        try await step.run(twoTracks, in: store)
        let oneTrack = try await meeting(mic: [word("Welcome", 0)])
        splits.set(["mic.caf": SpeakerSplit(turns: [turn("S1", 0, 20)], prints: ["S1": voicePrint(0)])])
        try await step.run(oneTrack, in: store)

        #expect(try await memory.people().first?.prints.count == 1)
        #expect(try await store.voices(of: twoTracks).isEmpty)
        #expect(try await names(oneTrack) == ["Speaker 1"])
    }
}
