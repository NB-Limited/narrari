import Foundation
import NarrariKit
import Testing

@MainActor
struct HistoryLibraryTests {
    private let folder = TemporaryFolder()
    private let settings = ThrowawaySettings()
    private let clock = TestClock()
    private let heard = "hi anna thursday at ten works for me"
    private let shown = "Hi Anna, Thursday at ten works for me."

    private func library(
        store: HistoryStore, engine: FakeCleanupEngine? = nil, activeDictation: @escaping @MainActor () -> UUID? = { nil }
    ) -> HistoryLibrary {
        let pipeline = TextPipeline(
            cleanup: CleanupService(engine: engine, settings: settings.store, clock: clock),
            prompts: PromptStore(root: folder.url), dictionary: DictionaryStore(root: folder.url), settings: settings.store
        )
        let retranscription = Retranscription(
            history: store, pipeline: pipeline,
            transcription: FileTranscription(
                store: ModelStore(root: folder.url), settings: settings.store, dictionary: DictionaryStore(root: folder.url)
            ),
            modes: ModeStore(root: folder.url), settings: settings.store
        )
        return HistoryLibrary(store: store, retranscription: retranscription, apps: AppDirectory(), activeDictation: activeDictation)
    }

    // A dictation Tidy cleaned up, as a live one is saved.
    private func tidied(in store: HistoryStore) async throws -> HistoryEntry {
        let id = UUID()
        var entry = HistoryEntry(
            id: id, startedAt: Date(), rawText: heard, finalText: shown, audioFile: HistoryEntry.audioFileName(for: id), outcome: .pasted
        )
        entry.cleanup.status = CleanupResult.Status.cleaned.rawValue
        entry.prompt = Prompt.tidy.id
        try await store.append(entry)
        return entry
    }

    private func historyFile() throws -> String {
        try String(contentsOf: #require(folder.files(withExtension: "jsonl").first), encoding: .utf8)
    }

    @Test func entry_still_recording_is_never_deleted() async throws {
        let store = HistoryStore(root: folder.url)
        let id = UUID()
        let recording = HistoryEntry(id: id, startedAt: Date(), audioFile: HistoryEntry.audioFileName(for: id))
        try await store.append(recording)
        try Data("caff".utf8).write(to: store.audioURL(for: id))
        let library = library(store: store) { id }

        await library.delete(recording)

        #expect(!library.canDelete(recording))
        #expect(try await store.entries().entries.map(\.id) == [id])
        #expect(FileManager.default.fileExists(atPath: store.audioURL(for: id).path))
    }

    @Test func cleaning_up_again_replaces_the_text_from_what_was_heard_and_keeps_the_old_text_in_the_file() async throws {
        let store = HistoryStore(root: folder.url)
        let entry = try await tidied(in: store)
        let engine = FakeCleanupEngine { _ in "Hi Anna,\n\nThursday at ten works for me." }
        let library = library(store: store, engine: engine)
        let email = CleanupChoice(prompt: .email)

        #expect(await library.cleanUp(entry, with: email))

        let call = try #require(engine.calls.first)
        #expect(call.transcript == heard)
        #expect(call.instruction.contains(Prompt.email.instruction))
        let updated = try #require(library.entries.first)
        #expect(updated.finalText == "Hi Anna,\n\nThursday at ten works for me.")
        #expect(updated.rawText == heard)
        #expect(email.made(updated))
        #expect(!CleanupChoice(prompt: .tidy).made(updated))
        #expect(try historyFile().contains(shown))
    }

    @Test func as_spoken_shows_what_was_heard_without_the_model() async throws {
        let store = HistoryStore(root: folder.url)
        let entry = try await tidied(in: store)
        let engine = FakeCleanupEngine { _ in "never asked" }
        let library = library(store: store, engine: engine)

        #expect(await library.cleanUp(entry, with: .asSpoken))

        #expect(engine.calls.isEmpty)
        let updated = try #require(library.entries.first)
        #expect(updated.finalText == heard)
        #expect(CleanupChoice.asSpoken.made(updated))
    }

    @Test func clean_up_that_takes_too_long_leaves_the_text_and_says_why() async throws {
        let store = HistoryStore(root: folder.url)
        let entry = try await tidied(in: store)
        let stuck = Gate(honoursCancellation: false)
        let library = library(store: store, engine: FakeCleanupEngine(gate: stuck) { _ in "too late" })

        async let isSaved = library.cleanUp(entry, with: CleanupChoice(prompt: .email))
        await clock.waitForSleepers(1)
        clock.advance(by: CleanupService.localTimeLimit(characters: heard.count, isReloading: false))

        #expect(await isSaved == false)
        #expect(library.errors[entry.id] == "Clean-up took too long. The text is unchanged.")
        #expect(library.entries.first?.finalText == shown)
        stuck.open()
    }

    @Test func clean_up_switched_off_is_reported_and_left_off() async throws {
        settings.store.set(false, for: CleanupSettings.isEnabled)
        let store = HistoryStore(root: folder.url)
        let entry = try await tidied(in: store)
        let engine = FakeCleanupEngine { _ in "never asked" }
        let library = library(store: store, engine: engine)

        #expect(await library.cleanUp(entry, with: CleanupChoice(prompt: .email)) == false)

        #expect(engine.calls.isEmpty)
        #expect(library.errors[entry.id] == "Clean-up is off. The text is unchanged.")
        #expect(!settings.store.value(CleanupSettings.isEnabled))
    }

    @Test func a_second_run_while_one_is_going_is_refused() async throws {
        let store = HistoryStore(root: folder.url)
        let entry = try await tidied(in: store)
        let held = Gate()
        let engine = FakeCleanupEngine(gate: held) { _ in "Hi Anna, Thursday at ten works for me!" }
        let library = library(store: store, engine: engine)

        async let first = library.cleanUp(entry, with: CleanupChoice(prompt: .message))
        await held.waitForArrivals(1)

        #expect(await library.cleanUp(entry, with: CleanupChoice(prompt: .email)) == false)
        #expect(!library.canDelete(entry))
        held.open()
        #expect(await first)
        #expect(engine.calls.count == 1)
        #expect(library.entries.first?.prompt == Prompt.message.id)
    }
}
