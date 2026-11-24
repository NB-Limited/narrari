import Foundation

// What a summary can be written with: the clean-up models on this Mac, named as the Clean-up page names them, then the chat
// service once it is set up there.
public struct SummaryModels: Sendable {
    public struct Choice: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
    }

    public static let outside = "outside"
    static let serviceName = "Chat service"

    private let settings: SettingsStore
    private let store: ModelStore
    private let catalogue: [CatalogueModel]

    public init(settings: SettingsStore, store: ModelStore, catalogue: [CatalogueModel] = ModelCatalogue.cleanup) {
        self.settings = settings
        self.store = store
        self.catalogue = catalogue
    }

    public var isOutsideSetUp: Bool { ChatClient.isSetUp(settings: settings) }

    public var cleanupModel: String { settings.value(CleanupSettings.localModel) }

    // The clean-up model is always listed, because a summary waits for it to download.
    public func choices() -> [Choice] {
        let onThisMac = Set(ModelHub(store: store).cachedModelIDs())
        let cleanup = ModelReference(cleanupModel).id
        let local = catalogue.filter { onThisMac.contains(ModelReference($0.id).id) || ModelReference($0.id).id == cleanup }
        return local.map { Choice(id: $0.id, name: $0.name) } + (isOutsideSetUp ? [Choice(id: Self.outside, name: Self.serviceName)] : [])
    }

    // A meeting's choice, else the setting's, else the clean-up model.
    public static func resolved(_ choice: String, settings: SettingsStore) -> String {
        let chosen = choice.isEmpty ? settings.value(MeetingsSettings.summaryModel) : choice
        return chosen.isEmpty ? settings.value(CleanupSettings.localModel) : chosen
    }

    public func resolved(_ choice: String) -> String {
        Self.resolved(choice, settings: settings)
    }
}
