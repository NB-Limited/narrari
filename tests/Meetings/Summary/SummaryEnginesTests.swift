import Foundation
import NarrariKit
import Testing

@MainActor
struct SummaryEnginesTests {
    private let folder = TemporaryFolder()
    private let settings = ThrowawaySettings()

    @Test func the_chat_service_is_there_for_summaries_once_set_up_while_clean_up_stays_on_this_mac() {
        let store = ModelStore(root: folder.url)
        let engines = CleanupSummaryEngines(
            slot: CleanupEngineSlot(settings: settings.store, keychain: FakeKeychain(), store: store), settings: settings.store,
            keychain: FakeKeychain(), store: store
        )
        settings.store.set("https://chat.example.com", for: CleanupSettings.chatAddress)
        let withoutModel = engines.outside()
        settings.store.set("small-chat-1", for: CleanupSettings.chatModel)

        #expect(withoutModel == nil)
        #expect(engines.outside()?.engine.name == "small-chat-1")
        #expect(settings.store.value(CleanupSettings.engine) == .local)
    }
}
