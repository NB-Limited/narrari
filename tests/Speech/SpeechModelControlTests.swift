import Foundation
import NarrariKit
import Synchronization
import Testing

@MainActor
struct SpeechModelControlTests {
    private let folder = TemporaryFolder()
    private let settings = ThrowawaySettings()
    private let clock = TestClock()
    private let transcriber = FakeTranscriber(text: "hello")

    private func control(_ preview: LivePreview) -> SpeechModelControl {
        let store = ModelStore(root: folder.url)
        return SpeechModelControl(
            local: ParakeetTranscriber(store: store, settings: settings.store, downloadsIfMissing: false),
            livePreview: preview, status: ModelStatus(), store: store, settings: settings.store,
            dictionary: DictionaryStore(root: folder.url)
        )
    }

    private func placeOnDisk(_ model: ParakeetModel) throws {
        let files = ModelStore(root: folder.url).directory(named: model.folder)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
    }

    @Test(.timeLimit(.minutes(1))) func a_model_chosen_elsewhere_becomes_the_one_in_use() async {
        let control = control(LivePreview(transcriber: transcriber))

        settings.store.set(ParakeetModel.v3, for: SpeechSettings.localModel)

        await until { control.chosen == .v3 }
    }

    @Test func a_fresh_install_gets_the_recommended_model() {
        let control = control(LivePreview(transcriber: transcriber))

        #expect(control.chosen == .recommended)
        #expect(settings.store.value(SpeechSettings.localModel) == ParakeetModel.recommended)
    }

    @Test func an_install_from_before_the_choice_keeps_v3_even_with_the_recommended_model_on_disk() throws {
        try placeOnDisk(.v3)
        try placeOnDisk(.ultra)

        let control = control(LivePreview(transcriber: transcriber))
        try FileManager.default.removeItem(at: ModelStore(root: folder.url).directory(named: ParakeetModel.v3.folder))
        let again = self.control(LivePreview(transcriber: transcriber))

        #expect(control.chosen == .v3)
        #expect(again.chosen == .v3)
        #expect(ParakeetTranscriber(store: ModelStore(root: folder.url), settings: settings.store).name == "Parakeet v3")
    }

    @Test func cancelling_a_download_removes_what_it_wrote() async throws {
        settings.store.set(ParakeetModel.ultra, for: SpeechSettings.localModel)
        let files = ModelStore(root: folder.url).directory(named: ParakeetModel.ultra.folder)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: files.appending(path: "Encoder.mlmodelc"))
        let control = control(LivePreview(transcriber: transcriber))

        await control.cancel().value

        #expect(!FileManager.default.fileExists(atPath: files.path))
    }

    private func startedPreview() async -> LivePreview {
        let preview = LivePreview(transcriber: transcriber, clock: clock)
        preview.start(reading: { _ in [] }, publish: { _ in })
        await clock.waitForSleepers(1)
        return preview
    }

    @Test func turning_live_text_off_unloads_its_instance_at_once() async {
        let preview = await startedPreview()
        let control = control(preview)

        settings.store.set(false, for: DictationSettings.showsLiveText)

        await transcriber.unloads.waitForArrivals(1)
        withExtendedLifetime(control) {}
        #expect(transcriber.loads.arrivals == 1)
    }

    @Test func deleting_the_model_unloads_the_live_text_instance_and_the_files() async throws {
        let preview = await startedPreview()
        let control = control(preview)
        let files = ModelStore(root: folder.url).directory(named: control.chosen.folder)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)

        try await control.delete(control.chosen)

        #expect(transcriber.unloads.arrivals == 1)
        #expect(!FileManager.default.fileExists(atPath: files.path))
    }

    @Test func deleting_the_model_in_use_takes_the_dictionary_model_with_it_and_another_model_does_not() async throws {
        let store = ModelStore(root: folder.url)
        for name in [ParakeetModel.v3.folder, ParakeetModel.ultra.folder, Vocabulary.modelName] {
            try FileManager.default.createDirectory(at: store.directory(named: name), withIntermediateDirectories: true)
        }
        settings.store.set(ParakeetModel.v3, for: SpeechSettings.localModel)
        let control = SpeechModelControl(
            local: ParakeetTranscriber(store: store, settings: settings.store), livePreview: LivePreview(transcriber: transcriber),
            status: ModelStatus(), store: store, settings: settings.store, vocabulary: Vocabulary(store: store, settings: settings.store),
            dictionary: DictionaryStore(root: folder.url)
        )

        try await control.delete(.ultra)
        #expect(store.isPresent(named: Vocabulary.modelName))
        #expect(transcriber.unloads.arrivals == 0)

        try await control.delete(.v3)
        #expect(!store.isPresent(named: Vocabulary.modelName))
        #expect(!store.isPresent(named: ParakeetModel.v3.folder))
    }

    @Test func dictionary_words_wait_for_the_speech_model() async {
        let states = ReportedStates()
        let vocabulary = Vocabulary(store: ModelStore(root: folder.url), settings: settings.store) { state in states.list.withLock { $0.append(state) } }

        await vocabulary.prepare(words: ["Baburov"])

        #expect(states.list.withLock { $0 } == [.missing])
    }
}

private final class ReportedStates: Sendable {
    let list = Mutex<[ModelState]>([])
}
