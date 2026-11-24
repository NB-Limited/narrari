import Foundation
import NarrariKit
import Testing

@MainActor
struct CleanupPageModelTests {
    private let folder = TemporaryFolder()
    private let settings = ThrowawaySettings()

    private func page() -> CleanupPageModel {
        let engines = CleanupEngineSlot(settings: settings.store, keychain: FakeKeychain(), store: ModelStore(root: folder.url))
        return CleanupPageModel(engines: engines, settings: settings.mirror, keychain: FakeKeychain())
    }

    private func downloaded(_ folderName: String) throws -> URL {
        let model = folder.url.appending(path: "huggingface/\(folderName)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: model.appending(path: "model.safetensors"))
        return model
    }

    @Test func address_is_saved_only_once_it_can_be_used() {
        let page = page()
        page.beginServiceSetup()

        page.chatAddress = "https://api.example.com/v1"
        page.chatAddress = "http://api.example.com/v1"

        #expect(page.addressError == ServiceAddressError.notHTTPS.problem.message)
        #expect(settings.store.value(CleanupSettings.chatAddress) == "https://api.example.com/v1")
    }

    @Test func typed_service_fields_stay_while_the_settings_change_elsewhere_and_done_keeps_them() {
        let page = page()
        page.beginServiceSetup()
        page.chatAddress = "https://api.example.com/v1"
        page.chatModel = "mine"

        settings.store.set("theirs", for: CleanupSettings.chatModel)

        #expect(page.chatModel == "mine")
        page.finishServiceSetup()
        #expect(settings.store.value(CleanupSettings.chatModel) == "mine")
        settings.store.set("theirs", for: CleanupSettings.chatModel)
        #expect(page.chatModel == "theirs")
    }

    // The detected code must be one the list offers, or a chosen language would never match a dictation.
    @Test func skipped_language_is_saved_and_offered_again_once_removed() throws {
        let page = page()
        let detected = SpokenLanguage.detect("Send the invoice to Maria by Friday, please.")
        let language = try #require(page.languagesToSkip.first { $0.id == detected })

        page.skip(language.id)

        #expect(settings.store.value(CleanupSettings.skippedLanguages) == [language.id])
        #expect(!page.languagesToSkip.contains(language))

        page.stopSkipping(language.id)

        #expect(settings.store.value(CleanupSettings.skippedLanguages).isEmpty)
        #expect(page.languagesToSkip.contains(language))
    }

    @Test func emptied_address_clears_the_saved_one() {
        let page = page()
        page.chatAddress = "https://api.example.com/v1"

        page.chatAddress = ""

        #expect(settings.store.value(CleanupSettings.chatAddress).isEmpty)
    }

    @Test func models_on_disk_list_every_one_but_the_model_in_use() throws {
        let inUse = try downloaded("models--mlx-community--Qwen3.5-2B-MLX-8bit")
        let earlier = try downloaded("models--mlx-community--Qwen3.5-0.8B-4bit")
        _ = try downloaded("not-a-model")
        let page = page()

        page.refreshSize()

        #expect(page.otherModels.map(\.id) == ["mlx-community/Qwen3.5-0.8B-4bit"])
        #expect(page.otherModels.first?.bytesOnDisk ?? 0 >= 4096)
        #expect(FileManager.default.fileExists(atPath: inUse.path) && FileManager.default.fileExists(atPath: earlier.path))
    }

    @Test func deleting_an_earlier_model_removes_only_its_folder() async throws {
        let inUse = try downloaded("models--mlx-community--Qwen3.5-2B-MLX-8bit")
        let earlier = try downloaded("models--mlx-community--Qwen3.5-0.8B-4bit")
        let page = page()
        page.refreshSize()

        page.requestDeletion(of: try #require(page.models.last))
        await page.confirmDeletion()

        #expect(!FileManager.default.fileExists(atPath: earlier.path))
        #expect(FileManager.default.fileExists(atPath: inUse.path))
        #expect(page.otherModels.isEmpty)
    }

    @Test func earlier_models_are_listed_apart_for_deletion_only() throws {
        _ = try downloaded("models--mlx-community--Qwen3.5-0.8B-4bit")
        let page = page()
        page.refreshSize()

        let earlier = try #require(page.models.last)
        let row = page.row(for: earlier)

        #expect(page.groups.map(\.group) == [.toDownload, .noLongerUsed])
        #expect(page.groups.last?.models.map(\.name) == ["Qwen3.5 0.8B 4bit"])
        #expect(page.readings[earlier.id] == nil)
        #expect(row.action == nil)
        #expect(row.canDelete)
    }

    @Test func choosing_another_downloaded_model_keeps_both_on_this_mac() throws {
        _ = try downloaded("models--mlx-community--Qwen3.5-2B-MLX-8bit")
        _ = try downloaded("models--mlx-community--Qwen3.5-4B-MLX-4bit")
        let page = page()
        page.refreshSize()
        let inUse = ModelCatalogue.cleanup[0]
        let next = ModelCatalogue.cleanup[1]

        page.choose(next)

        #expect(page.groups.first?.group == .onThisMac)
        #expect(page.groups.first?.models == [inUse, next])
        #expect(page.row(for: next).mark == .chosen)
        #expect(page.row(for: inUse).status == .downloaded)
    }

    @Test func the_service_can_be_chosen_only_once_it_is_set_up() {
        let page = page()
        #expect(page.serviceRow.offersSetUp)
        #expect(page.serviceRow.mark == .unavailable)
        #expect(page.serviceRow.summary == "Text leaves this Mac")

        page.beginServiceSetup()
        page.chatAddress = "https://chat.example.com/v1"
        page.chatModel = "small-chat-1"
        page.finishServiceSetup()
        #expect(page.serviceRow.mark == .available)
        #expect(page.serviceRow.showsEditButton)

        page.chooseService()

        #expect(page.serviceRow.mark == .chosen)
        #expect(page.serviceRow.summary == "chat.example.com, small-chat-1, text leaves this Mac")
        #expect(settings.store.value(CleanupSettings.engine) == .chat)
    }

    @Test func the_page_opens_on_the_side_that_holds_the_model_in_use() {
        settings.store.set("https://chat.example.com/v1", for: CleanupSettings.chatAddress)
        settings.store.set("small-chat-1", for: CleanupSettings.chatModel)
        settings.store.set(.chat, for: CleanupSettings.engine)
        let page = page()

        page.appear()
        #expect(page.side == .outside)

        page.usesOutsideService = false
        page.side = .outside
        page.appear()

        #expect(page.side == .thisMac)
    }
}
