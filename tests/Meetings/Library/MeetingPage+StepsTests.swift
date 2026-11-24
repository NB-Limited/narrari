import Foundation
import NarrariKit
import Testing

@MainActor
struct MeetingPageStepsTests {
    private let folder = TemporaryFolder()
    private let settings = ThrowawaySettings()
    private let store: MeetingStore
    private let models: ModelStore

    init() {
        store = MeetingStore(root: folder.url.appending(path: "Meetings"), trash: { _ in })
        models = ModelStore(root: folder.url.appending(path: "Models"))
    }

    private func page(
        _ steps: (inout Meeting.Steps) -> Void, fetch: FakeModelFetch, speech: SharedModel? = nil, progress: MeetingTranscript.Progress? = nil
    ) async throws -> (MeetingPage, MeetingModels) {
        var meeting = Meeting(title: "Weekly", startedAt: .now, app: "", source: .manual, template: "general", state: .ready)
        steps(&meeting.steps)
        try await store.create(meeting, appName: "")
        let memory = VoiceMemory(folder: folder.url)
        let library = MeetingModels(store: models, fetch: fetch.fetch, speech: speech)
        let page = MeetingPage(
            meeting: meeting, store: store, processing: MeetingProcessing(store: store, echo: Idle(), transcript: Idle()), models: library,
            progress: progress ?? MeetingTranscript.Progress(), renaming: SpeakerRenaming(store: store, memory: memory, settings: settings.store),
            memory: memory, settings: settings.store
        )
        await page.load()
        return (page, library)
    }

    @Test func the_step_at_work_reads_its_verb_and_time_and_each_tab_says_what_it_comes_after() async throws {
        let started = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let (page, _) = try await page({ $0.echo = Meeting.Step(.done); $0.transcript = Meeting.Step(.running, since: started) },
                                       fetch: FakeModelFetch(store: models))

        let transcript = try #require(page.steps?.first { $0.id == .transcript })

        #expect(transcript.text(at: started.addingTimeInterval(84)) == "Writing the transcript, 1:24" && transcript.look == .working)
        #expect(page.emptyLine(for: .summary) == "Comes after the transcript.")
        #expect(page.emptyLine(for: .transcript) == "The transcript is being written.")
        #expect(page.emptyLine(for: .speakers) == "Comes after the transcript.")
        #expect(!page.canRedoSummary)
    }

    @Test func a_transcript_being_written_shows_its_share_over_both_tracks() async throws {
        let progress = MeetingTranscript.Progress()
        let (page, _) = try await page({ $0.echo = Meeting.Step(.done); $0.transcript = Meeting.Step(.running, since: .now) },
                                       fetch: FakeModelFetch(store: models), progress: progress)
        try Data().write(to: try await store.audio(.system, of: page.meeting.id))
        let held = Gate()
        let transcript = MeetingTranscript(transcribe: { url, report in
            report(0.5)
            if url.lastPathComponent == MeetingStore.Audio.microphone.rawValue { try await held.pass() }
            return Transcript(text: "", audioSeconds: 0)
        }, pipeline: TextPipeline(
            cleanup: CleanupService(engine: nil, settings: settings.store, clock: TestClock()), prompts: PromptStore(root: folder.url),
            dictionary: DictionaryStore(root: folder.url), settings: settings.store
        ), ownerName: "Ana Petrova", modelName: { "Parakeet v3" }, progress: progress)
        let row = { page.steps?.first { $0.id == .transcript } }

        let run = Task { [store, id = page.meeting.id] in try await transcript.run(id, in: store) }
        await until { row()?.progress == 0.25 }
        let halfway = row()
        held.open()
        try await run.value
        await until { row()?.progress == nil }

        #expect(halfway?.text(at: .now) == "Writing the transcript, 25%")
    }

    @Test func a_tab_with_nothing_to_show_says_why() async throws {
        let unreadable = Meeting.Step(.failed, problem: AudioFileError.unreadable.problem.code)
        let (failed, _) = try await page({ $0.echo = Meeting.Step(.done); $0.transcript = unreadable }, fetch: FakeModelFetch(store: models))
        let allDone: (inout Meeting.Steps) -> Void = { steps in
            (steps.echo, steps.transcript, steps.speakers, steps.summary) = (.init(.done), .init(.done), .init(.done), .init(.done))
        }
        let (silent, _) = try await page(allDone, fetch: FakeModelFetch(store: models))
        let (short, _) = try await page(allDone, fetch: FakeModelFetch(store: models))
        try await store.write([TranscriptSegment(start: 0, end: 2, speaker: "owner", text: "Okay, thanks.", track: .mic)], of: short.meeting.id)
        await short.load()

        let failedRow = try #require(failed.steps?.first { $0.id == .transcript })

        #expect(failed.emptyLine(for: .transcript) == "The transcript could not be written.")
        #expect(failedRow.text(at: .now) == AudioFileError.unreadable.problem.message && failedRow.action == nil)
        #expect(silent.emptyLine(for: .transcript) == "No speech was heard." && silent.emptyLine(for: .summary) == "No speech was heard.")
        #expect(short.emptyLine(for: .summary) == "Too short to summarise. The transcript holds every word.")
    }

    @Test func a_step_waiting_for_its_model_shows_the_download_and_a_failed_one_offers_try_again() async throws {
        let fetch = FakeModelFetch(store: models, isHeld: true)
        let (page, library) = try await page({ steps in
            steps.echo = Meeting.Step(.done)
            steps.transcript = Meeting.Step(.done)
            steps.speakers = Meeting.Step(.waiting, for: .speakerModel)
        }, fetch: fetch)

        library.begin([.speakerSplit])
        await until { library.status(of: .speakerSplit) == .downloading(0.5) }
        let downloading = try #require(page.steps?.first { $0.id == .speakers })
        fetch.isFailing.withLock { $0 = true }
        fetch.gate.open()
        await until { if case .failed = library.status(of: .speakerSplit) { true } else { false } }
        let failed = try #require(page.steps?.first { $0.id == .speakers })

        #expect(downloading.text(at: .now) == "Downloading, 50%" && downloading.progress == 0.5 && downloading.action == nil)
        #expect(failed.look == .failed && failed.action == .download)
        #expect(failed.text(at: .now) == "The download failed. Check the connection and try again.")
    }
}

private struct Idle: MeetingStep {
    func run(_ id: UUID, in store: MeetingStore) async throws {}
}
