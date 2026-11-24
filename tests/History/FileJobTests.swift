import Foundation
import NarrariKit
import Testing

@MainActor
struct FileJobTests {
    private let folder = TemporaryFolder()
    private let settings = ThrowawaySettings()

    private var history: HistoryStore { HistoryStore(root: folder.url.appending(path: "History")) }

    // No speech model on disk, so a started file fails at the model, as it would on a Mac without one.
    private func job(store: HistoryStore) -> (FileJob, HistoryLibrary) {
        let pipeline = TextPipeline(
            cleanup: CleanupService(engine: nil, settings: settings.store, clock: TestClock()),
            prompts: PromptStore(root: folder.url), dictionary: DictionaryStore(root: folder.url), settings: settings.store
        )
        let retranscription = Retranscription(
            history: store, pipeline: pipeline,
            transcription: FileTranscription(store: ModelStore(root: folder.url), settings: settings.store, dictionary: DictionaryStore(root: folder.url)),
            modes: ModeStore(root: folder.url), settings: settings.store
        )
        let library = HistoryLibrary(store: store, retranscription: retranscription, apps: AppDirectory())
        return (FileJob(library: library, retranscription: retranscription) { true }, library)
    }

    @Test(arguments: [
        ("https://example.com/talk.m4a", false),
        ("file:///Users/anna/Desktop/talk.m4a", true),
        ("file:///Users/anna/Desktop/meeting.mov", true),
        ("file:///Users/anna/Desktop/notes.txt", false)
    ])
    func only_files_on_this_mac_of_a_supported_type_are_accepted(link: String, isAccepted: Bool) throws {
        let url = try #require(URL(string: link))

        #expect(FileJob.isSupported(url) == isAccepted)
    }

    @Test func started_file_is_listed_first_and_selected_and_a_second_is_refused() async throws {
        let store = history
        let id = UUID()
        try await store.append(HistoryEntry(id: id, startedAt: Date(), finalText: "Earlier", audioFile: HistoryEntry.audioFileName(for: id), outcome: .pasted))
        let (job, library) = job(store: store)
        await library.refresh()

        job.offer([folder.url.appending(path: "interview.m4a")])
        job.offer([folder.url.appending(path: "standup.mp3")])

        #expect(library.results.map(\.file) == ["interview.m4a", nil])
        #expect(library.selected?.file == "interview.m4a")
        #expect(job.notice == .busy)
        job.cancel()
        #expect(library.results.map(\.id) == [id])
    }

    @Test func failed_file_leaves_no_entry_and_no_audio_and_says_why() async throws {
        let store = history
        let (job, library) = job(store: store)

        job.offer([folder.url.appending(path: "interview.m4a")])
        await until { !job.isWorking }

        #expect(job.notice == .failed(fileName: "interview.m4a", message: "No speech model yet. Download one in Settings, Speech."))
        #expect(library.results.isEmpty)
        #expect(try await store.entries().entries.isEmpty)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: store.root.path)) ?? []).isEmpty)
    }

    @Test func dropped_document_starts_nothing_and_says_why() {
        let (job, library) = job(store: history)

        job.offer([folder.url.appending(path: "notes.txt")])

        #expect(job.notice == .failed(fileName: "notes.txt", message: AudioFileError.unreadable.problem.message))
        #expect(!job.isWorking)
        #expect(library.results.isEmpty)
    }
}
