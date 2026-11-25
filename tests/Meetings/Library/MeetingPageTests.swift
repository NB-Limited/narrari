import Foundation
import NarrariKit
import Testing

@MainActor
struct MeetingPageTests {
    private let folder = TemporaryFolder()
    private let settings = ThrowawaySettings()
    private let store: MeetingStore
    private let memory: VoiceMemory
    private let processing: MeetingProcessing
    private let speakersAskedFor = Notes<Int?>()
    private let heardTracks: Notes<String>

    init() {
        let heardTracks = Notes<String>()
        self.heardTracks = heardTracks
        store = MeetingStore(root: folder.url.appending(path: "Meetings"), trash: { _ in })
        memory = VoiceMemory(folder: folder.url)
        let pipeline = TextPipeline(
            cleanup: CleanupService(engine: nil, settings: settings.store, clock: TestClock()),
            prompts: PromptStore(root: folder.url), dictionary: DictionaryStore(root: folder.url), settings: settings.store
        )
        processing = MeetingProcessing(
            store: store, echo: NoEcho(),
            transcript: MeetingTranscript(
                transcribe: { url, _ in
                    heardTracks.add(url.lastPathComponent)
                    return Self.heard[url.lastPathComponent] ?? Transcript(text: "", audioSeconds: 0)
                },
                pipeline: pipeline,
                ownerName: "Mila Novak", modelName: { "Parakeet v3" }
            ),
            speakers: MeetingSpeakers(
                split: { [speakersAskedFor] track, speakers in
                    if track.lastPathComponent == MeetingStore.Audio.system.rawValue { speakersAskedFor.add(speakers) }
                    return SpeakerSplit(turns: [.init(speaker: "S1", start: 0, end: 30)], prints: ["S1": voicePrint(1)])
                },
                memory: memory, pipeline: pipeline, settings: settings.store, ownerName: "Mila Novak"
            )
        )
    }

    private nonisolated static let heard = [
        "mic.caf": transcript([("Then", 0), ("we", 0.3), ("plan", 0.6), ("for", 0.9), ("the", 1.2), ("fourteenth.", 1.5)]),
        "system.caf": transcript([("The", 3), ("Roterdam", 3.3), ("hub", 3.6), ("is", 3.9), ("ready.", 4.2), ("Rotterdam", 8), ("agreed.", 8.3)])
    ]

    private nonisolated static func transcript(_ words: [(String, Double)]) -> Transcript {
        Transcript(
            text: words.map(\.0).joined(separator: " "), audioSeconds: 10,
            words: words.map { Transcript.Word(text: $0.0, start: $0.1, end: $0.1 + 0.25) }
        )
    }

    private func processed() async throws -> Meeting {
        let meeting = Meeting(title: "Delivery plan", startedAt: .now, app: "", source: .call, template: "general", state: .ready)
        try await store.create(meeting, appName: "Zoom")
        for track in [MeetingStore.Audio.microphone, .system] {
            try Data("caff".utf8).write(to: try await store.audio(track, of: meeting.id))
        }
        await processing.process(meeting.id)
        return try await store.meeting(meeting.id)
    }

    private func page(_ meeting: Meeting, query: String = "") async -> MeetingPage {
        let page = MeetingPage(
            meeting: meeting, store: store, processing: processing,
            models: MeetingModels(store: ModelStore(root: folder.url), fetch: FakeModelFetch(store: ModelStore(root: folder.url)).fetch),
            progress: MeetingTranscript.Progress(), renaming: SpeakerRenaming(store: store, memory: memory, settings: settings.store), memory: memory,
            settings: settings.store, query: query
        )
        await page.load()
        return page
    }

    @Test func an_edited_line_survives_finding_speakers_again_and_is_marked_until_transcribing_again_replaces_it() async throws {
        let page = await page(try await processed())
        let line = try #require(page.segments.firstIndex { $0.text.hasPrefix("The Roterdam") })

        await page.edit(line: line, to: "The Rotterdam hub is ready.")
        await page.redo(.speakers)
        let afterSpeakers = page.segments.map(\.text)
        let wasMarked = page.meeting.linesEdited
        await page.redo(.transcript)

        #expect(afterSpeakers.contains("The Rotterdam hub is ready.") && wasMarked)
        #expect(page.segments.map(\.text).contains("The Roterdam hub is ready."))
        #expect(!page.meeting.linesEdited)
        #expect(page.meeting.steps.speakers.status == .done)
    }

    @Test func the_number_of_people_chosen_is_kept_for_every_later_run_until_detect_is_chosen() async throws {
        let page = await page(try await processed())

        await page.findSpeakersAgain(count: 2)
        await page.redo(.speakers)
        await page.findSpeakersAgain(count: 0)
        await page.findSpeakersAgain(ownSide: 2)

        #expect(speakersAskedFor.all == [nil, 2, 2, nil, nil])
        #expect(page.meeting.speakerCount == 0 && page.meeting.ownSideCount == 2 && page.meeting.steps.speakers.status == .done)
        #expect(page.speakerCountTitle == "People on the other side" && page.hasCallTrack)
    }

    @Test func notes_that_cannot_be_saved_say_so_and_stay_in_the_field_until_a_save_works() async throws {
        let meeting = Meeting(title: "Delivery plan", startedAt: .now, app: "", source: .call, template: "general", state: .ready)
        let meetingFolder = try await store.create(meeting, appName: "Zoom")
        let page = await page(meeting)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: meetingFolder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: meetingFolder.path) }

        page.setNotes("Send the plan by Friday.")
        await page.notesSaved()
        let problem = page.notesProblem
        await page.load()
        let shown = page.notes
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: meetingFolder.path)
        page.setNotes("Send the plan by Friday. Book the room.")
        await page.notesSaved()

        #expect(problem?.message == "Your notes could not be saved. They stay here; type again to try once more.")
        #expect(shown == "Send the plan by Friday.")
        #expect(page.notesProblem == nil)
        #expect(try await store.text(.notes, of: meeting.id) == "Send the plan by Friday. Book the room.")
    }

    @Test func the_language_reads_as_detected_until_one_is_chosen_which_keeps_the_transcript() async throws {
        let page = await page(try await processed())
        let detected = page.languageLine
        let transcribed = heardTracks.all.count

        await page.summarise(in: "bg")

        #expect(detected == "English, detected")
        #expect(page.languageLine == "Bulgarian")
        #expect(heardTracks.all.count == transcribed)
    }

    @Test func a_search_opens_the_transcript_at_its_first_hit_and_copy_takes_the_tab_shown() async throws {
        let meeting = try await processed()
        let plain = await page(meeting)
        let searched = await page(meeting, query: "rotterdam")

        #expect(plain.tab == .summary)
        #expect(searched.tab == .transcript)
        #expect(searched.matchCount == "1 of 1")
        #expect(searched.matchLine == searched.segments.firstIndex { $0.text.contains("Rotterdam") })
        #expect(searched.turns.map(\.speaker.name) == ["Mila Novak", "Speaker 2"])
        #expect(plain.copyText.isEmpty)
        #expect(searched.copyText.hasPrefix("You: Then we plan for the fourteenth.\n\nSpeaker 2: The Roterdam hub"))
    }

    @Test func the_line_under_the_playback_position_plays_and_none_while_paused() async throws {
        let page = await page(try await processed())
        let first = try #require(page.segments.first)

        #expect(page.playingLines(at: first.start, isPlaying: true).contains(0))
        #expect(!page.playingLines(at: first.end, isPlaying: true).contains(0))
        #expect(page.playingLines(at: first.start, isPlaying: false).isEmpty)
    }

    @Test func playing_a_speaker_hears_their_lines_in_order_and_jumps_over_everyone_else() {
        let segments = [
            TranscriptSegment(start: 0, end: 2, speaker: "speaker-2", text: "One.", track: .system),
            TranscriptSegment(start: 2.4, end: 4, speaker: "speaker-2", text: "Two.", track: .system),
            TranscriptSegment(start: 4, end: 9, speaker: "owner", text: "Three.", track: .mic),
            TranscriptSegment(start: 9.5, end: 10.1, speaker: "speaker-2", text: "Four.", track: .system),
            TranscriptSegment(start: 11, end: 20, speaker: "owner", text: "Five.", track: .mic)
        ]
        let part = MeetingPage.part(of: "speaker-2", in: segments)

        #expect(part.stretches == [0..<4, 9.5..<10.1])
        #expect(part.stretch(at: 1) == 0..<4)
        #expect(part.stretch(at: 4) == 9.5..<10.1)
        #expect(part.stretch(at: 6) == 9.5..<10.1)
        #expect(part.stretch(at: 10.1) == nil)
    }

    @Test func notes_are_saved_as_they_are_typed() async throws {
        let page = await page(try await processed())

        for text in ["P", "Pe", "Permits are the risk."] { page.setNotes(text) }
        await page.notesSaved()

        #expect(try await store.text(.notes, of: page.meeting.id) == "Permits are the risk.")
    }
}

private struct NoEcho: MeetingStep {
    func run(_ id: UUID, in store: MeetingStore) async throws {}
}
