import Foundation
import NarrariKit
import Testing

@MainActor
private final class Busy {
    var isOn = false
}

@MainActor
struct SpeechPageModelTests {
    private let folder = TemporaryFolder()
    private let settings = ThrowawaySettings()

    private let preview = FakeTranscriber(text: "")

    private func page(isTranscribing: @escaping @MainActor () -> Bool = { false }) -> (SpeechPageModel, SpeechModelControl) {
        let store = ModelStore(root: folder.url)
        let control = SpeechModelControl(
            local: ParakeetTranscriber(store: store, settings: settings.store, downloadsIfMissing: false),
            livePreview: LivePreview(transcriber: preview), status: ModelStatus(), store: store, settings: settings.store,
            dictionary: DictionaryStore(root: folder.url)
        )
        let page = SpeechPageModel(
            models: control, microphones: Microphones(settings: settings.store, source: FakeMicrophones()), settings: settings.mirror, keychain: FakeKeychain(),
            isTranscribing: isTranscribing
        )
        return (page, control)
    }

    private func entry(_ model: ParakeetModel, on page: SpeechPageModel) throws -> CatalogueModel {
        try #require(page.catalogue.first { $0.id == model.folder })
    }

    @Test func choosing_another_model_while_idle_is_what_the_next_dictation_runs() async throws {
        settings.store.set(ParakeetModel.v3, for: SpeechSettings.localModel)
        let (page, control) = page()
        let next = ParakeetTranscriber(store: ModelStore(root: folder.url), settings: settings.store)

        page.choose(try entry(.ultra, on: page))

        await preview.unloads.waitForArrivals(1)
        #expect(control.chosen == .ultra)
        #expect(next.name == "Parakeet Ultra")
        #expect(page.changeError == nil)
    }

    @Test func the_model_is_not_switched_or_deleted_while_a_transcription_runs() async throws {
        settings.store.set(ParakeetModel.v3, for: SpeechSettings.localModel)
        let files = ModelStore(root: folder.url).directory(named: ParakeetModel.v3.folder)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: files.appending(path: "Encoder.mlmodelc"))
        let busy = Busy()
        let (page, control) = page { busy.isOn }
        control.refreshSize()
        page.requestDeletion(of: try entry(.v3, on: page))
        busy.isOn = true

        page.choose(try entry(.ultra, on: page))
        #expect(page.changeError == SpeechPageModel.busyReason)
        await page.confirmDeletion()

        #expect(control.chosen == .v3)
        #expect(settings.store.value(SpeechSettings.localModel) == ParakeetModel.v3)
        #expect(FileManager.default.fileExists(atPath: files.path))
        #expect(page.changeError == SpeechPageModel.busyReason)
        #expect(page.isChangeBlocked)
        #expect(preview.unloads.arrivals == 0)
    }

    @Test func cancel_puts_the_service_fields_back() {
        let (page, _) = page()
        page.remoteAddress = "https://transcribe.example.com/v1"
        page.remoteModel = "large-v3"
        page.beginServiceSetup()

        page.remoteAddress = "https://other.example.com/v1"
        page.remoteModel = "small"
        page.cancelServiceSetup()

        #expect(settings.store.value(SpeechSettings.remoteAddress) == "https://transcribe.example.com/v1")
        #expect(settings.store.value(SpeechSettings.remoteModel) == "large-v3")
        #expect(page.serviceRow.status == .notSetUp)
    }

    @Test func done_sets_the_service_up_only_once_it_can_be_used() {
        let (page, _) = page()
        page.beginServiceSetup()
        page.remoteAddress = "https://transcribe.example.com/v1"

        page.finishServiceSetup()
        #expect(page.isEditingService)
        #expect(page.modelError != nil)

        page.remoteModel = "large-v3"
        page.finishServiceSetup()

        #expect(!page.isEditingService)
        #expect(settings.store.value(SpeechSettings.usesRemote))
        #expect(page.serviceRow.status == .ready)
        #expect(page.serviceRow.summary == "transcribe.example.com, large-v3, audio leaves this Mac")
        #expect(page.serviceRow.mark == .unavailable)
    }
}
