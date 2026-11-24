import Foundation
import NarrariKit
import Testing

struct SummaryModelsTests {
    private let folder = TemporaryFolder()
    private let settings = ThrowawaySettings()

    @Test func the_choices_are_the_clean_up_models_on_this_mac_then_the_chat_service_once_it_is_set_up() throws {
        let store = ModelStore(root: folder.url)
        let hub = store.directory(named: "huggingface")
        try FileManager.default.createDirectory(at: hub.appending(path: "models--mlx-community--Qwen3.5-4B-MLX-4bit"), withIntermediateDirectories: true)
        let models = SummaryModels(settings: settings.store, store: store)
        let before = models.choices().map(\.name)
        settings.store.set("https://chat.example.com", for: CleanupSettings.chatAddress)
        settings.store.set("small-chat-1", for: CleanupSettings.chatModel)

        #expect(before == ["Qwen3.5 2B", "Qwen3.5 4B"])
        #expect(models.choices().map(\.name) == ["Qwen3.5 2B", "Qwen3.5 4B", "Chat service"])
    }
}
