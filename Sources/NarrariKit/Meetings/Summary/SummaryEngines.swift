import Foundation

public struct SummaryEngine: Sendable {
    public let engine: any CleanupEngine
    let release: @Sendable () async -> Void

    public init(_ engine: any CleanupEngine, release: @escaping @Sendable () async -> Void = {}) {
        self.engine = engine
        self.release = release
    }
}

public protocol SummaryEngines: Sendable {
    func outside() -> SummaryEngine?
    // A nil model means the clean-up model; nil back means it is not on this Mac.
    func local(_ model: String?) async -> SummaryEngine?
}

// Shares the clean-up model and holds it against its idle unload, so a Mac never loads two copies; another model is the summary's alone.
public struct CleanupSummaryEngines: SummaryEngines {
    private let slot: CleanupEngineSlot
    private let settings: SettingsStore
    private let keychain: any KeyStoring
    private let store: ModelStore

    public init(slot: CleanupEngineSlot, settings: SettingsStore, keychain: any KeyStoring, store: ModelStore) {
        self.slot = slot
        self.settings = settings
        self.keychain = keychain
        self.store = store
    }

    public func outside() -> SummaryEngine? {
        guard ChatClient.isSetUp(settings: settings), let client = ChatClient(settings: settings, keychain: keychain) else {
            return nil
        }
        return SummaryEngine(client)
    }

    public func local(_ model: String?) async -> SummaryEngine? {
        let reference = ModelReference(model ?? settings.value(CleanupSettings.localModel))
        guard ModelHub(store: store).cachedModelIDs().contains(reference.id) else { return nil }
        if let shared = slot.current as? LocalModelEngine, shared.name == reference.id {
            await slot.hold()
            return SummaryEngine(shared) { [slot] in await slot.release() }
        }
        let own = LocalModelEngine(model: reference, store: store)
        return SummaryEngine(own) { await own.unload() }
    }
}
